-- Daewoon SafeDrive NEW v1.0.3
-- One-shot pgcrypto/login repair for Supabase
-- Run the ENTIRE file once in Supabase SQL Editor.

create schema if not exists extensions;

-- Ensure pgcrypto exists. If it was installed in another schema, move it to extensions.
do $$
declare
  v_schema text;
begin
  select n.nspname into v_schema
  from pg_extension e
  join pg_namespace n on n.oid=e.extnamespace
  where e.extname='pgcrypto';

  if v_schema is null then
    execute 'create extension pgcrypto with schema extensions';
  elsif v_schema <> 'extensions' then
    execute 'alter extension pgcrypto set schema extensions';
  end if;
end $$;

-- Hard check: fail here with a clear message if pgcrypto is still unavailable.
do $$
begin
  if to_regprocedure('extensions.crypt(text,text)') is null
     or to_regprocedure('extensions.gen_salt(text,integer)') is null then
    raise exception 'pgcrypto crypt/gen_salt functions are not available in extensions schema';
  end if;
end $$;

-- Make sure an initial admin exists, without overwriting an existing password.
insert into public.app_users(login_id,display_name,role,password_hash,must_change_password,active)
values ('관리자','관리자','admin',extensions.crypt('1111',extensions.gen_salt('bf',10)),true,true)
on conflict(login_id) do nothing;

create or replace function public.app_login(p_login_id text,p_password text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,extensions
as $$
declare
  v_u public.app_users;
  v_token uuid;
begin
  select * into v_u
  from public.app_users
  where login_id=trim(p_login_id) and active=true;

  if v_u.id is null
     or extensions.crypt(p_password,v_u.password_hash)<>v_u.password_hash then
    raise exception '아이디 또는 비밀번호가 올바르지 않습니다.';
  end if;

  delete from public.app_sessions where expires_at<=now();
  insert into public.app_sessions(user_id) values(v_u.id) returning token into v_token;
  update public.app_users set last_login_at=now() where id=v_u.id;
  perform public._audit(v_u.id,'LOGIN','app_user',v_u.id::text,
    jsonb_build_object('login_id',v_u.login_id));

  return jsonb_build_object(
    'token',v_token::text,
    'user_id',v_u.id,
    'login_id',v_u.login_id,
    'display_name',v_u.display_name,
    'role',v_u.role,
    'must_change_password',v_u.must_change_password,
    'expires_at',now()+interval '7 days'
  );
end $$;

create or replace function public.app_change_password(p_token text,p_old_password text,p_new_password text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,extensions
as $$
declare
  v_uid uuid;
  v_hash text;
begin
  v_uid:=public._session_user_id(p_token);
  if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  if length(p_new_password)<6 or p_new_password='1111' then
    raise exception '새 비밀번호는 6자 이상이며 1111과 달라야 합니다.';
  end if;

  select password_hash into v_hash from public.app_users where id=v_uid;
  if extensions.crypt(p_old_password,v_hash)<>v_hash then
    raise exception '현재 비밀번호가 올바르지 않습니다.';
  end if;

  update public.app_users
  set password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf',10)),
      must_change_password=false,
      updated_at=now()
  where id=v_uid;

  perform public._audit(v_uid,'PASSWORD_CHANGE','app_user',v_uid::text);
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.admin_import_dispatch(p_token text,p_rows jsonb,p_source_file text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,extensions
as $$
declare
  v_admin uuid; r jsonb; v_driver uuid; v_count int:=0;
  v_date date; v_start timestamptz; v_end timestamptz;
begin
  v_admin:=public._require_admin(p_token);
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    if coalesce(r->>'driver_name','')='' or coalesce(r->>'vehicle_no','')='' then continue; end if;

    insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
    values(trim(r->>'driver_name'),trim(r->>'driver_name'),'driver',
      extensions.crypt('1111',extensions.gen_salt('bf',10)),true)
    on conflict(login_id) do nothing;

    select id into v_driver from public.app_users where login_id=trim(r->>'driver_name');
    v_date=(r->>'service_date')::date;
    v_start=case when coalesce(r->>'shift_start','')='' then null else (r->>'shift_start')::timestamptz end;
    v_end=case when coalesce(r->>'shift_end','')='' then null else (r->>'shift_end')::timestamptz end;

    insert into public.dispatch_assignments(
      service_date,vehicle_no,driver_name,driver_user_id,shift_type,shift_start,shift_end,
      route_no,run_order,support_route_no,support_run_order,source_file,source_format)
    values(
      v_date,trim(r->>'vehicle_no'),trim(r->>'driver_name'),v_driver,
      coalesce(r->>'shift_type','UNKNOWN'),v_start,v_end,
      coalesce(trim(r->>'route_no'),''),coalesce(nullif(r->>'run_order','')::int,-1),
      nullif(trim(coalesce(r->>'support_route_no','')),''),nullif(r->>'support_run_order','')::int,
      p_source_file,coalesce(r->>'source_format','unknown'))
    on conflict(service_date,vehicle_no,driver_name,shift_type) do update set
      driver_user_id=excluded.driver_user_id,
      shift_start=coalesce(excluded.shift_start,public.dispatch_assignments.shift_start),
      shift_end=coalesce(excluded.shift_end,public.dispatch_assignments.shift_end),
      route_no=case when excluded.route_no<>'' then excluded.route_no else public.dispatch_assignments.route_no end,
      run_order=case when excluded.run_order>0 then excluded.run_order else public.dispatch_assignments.run_order end,
      support_route_no=coalesce(excluded.support_route_no,public.dispatch_assignments.support_route_no),
      support_run_order=coalesce(excluded.support_run_order,public.dispatch_assignments.support_run_order),
      source_file=excluded.source_file,
      source_format=case when public.dispatch_assignments.source_format<>excluded.source_format then 'MERGED' else excluded.source_format end,
      imported_at=now();
    v_count:=v_count+1;
  end loop;

  perform public._audit(v_admin,'IMPORT_DISPATCH','dispatch',p_source_file,jsonb_build_object('rows',v_count));
  return jsonb_build_object('ok',true,'rows',v_count);
end $$;

create or replace function public.admin_import_etas(p_token text,p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,extensions
as $$
declare
  v_admin uuid; v_driver uuid; v_report_id bigint; v_pub_id bigint; b jsonb; v_month date;
begin
  v_admin:=public._require_admin(p_token);
  if coalesce(p_report->>'driver_name','')='' then raise exception '운전자 이름이 없습니다.'; end if;

  insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
  values(trim(p_report->>'driver_name'),trim(p_report->>'driver_name'),'driver',
    extensions.crypt('1111',extensions.gen_salt('bf',10)),true)
  on conflict(login_id) do nothing;

  select id into v_driver from public.app_users where login_id=trim(p_report->>'driver_name');
  v_month=(p_report->>'analysis_month')::date;

  insert into public.etas_reports(
    driver_name,driver_user_id,analysis_month,safety_level,total_score,summary_text,
    weekday_text,time_text,trend_text,recommendations,source_file,raw)
  values(
    trim(p_report->>'driver_name'),v_driver,v_month,p_report->>'safety_level',
    nullif(p_report->>'total_score','')::numeric,p_report->>'summary_text',
    p_report->>'weekday_text',p_report->>'time_text',p_report->>'trend_text',
    coalesce(p_report->'recommendations','[]'::jsonb),p_report->>'source_file',p_report)
  on conflict(driver_name,analysis_month) do update set
    safety_level=excluded.safety_level,total_score=excluded.total_score,
    summary_text=excluded.summary_text,weekday_text=excluded.weekday_text,
    time_text=excluded.time_text,trend_text=excluded.trend_text,
    recommendations=excluded.recommendations,source_file=excluded.source_file,
    raw=excluded.raw,imported_at=now(),driver_user_id=excluded.driver_user_id
  returning id into v_report_id;

  delete from public.etas_behavior_scores where report_id=v_report_id;
  for b in select * from jsonb_array_elements(coalesce(p_report->'behaviors','[]'::jsonb)) loop
    insert into public.etas_behavior_scores(report_id,behavior,current_score,previous_score,change_score,grade)
    values(v_report_id,b->>'behavior',nullif(b->>'current_score','')::numeric,
      nullif(b->>'previous_score','')::numeric,nullif(b->>'change_score','')::numeric,b->>'grade');
  end loop;

  insert into public.driver_publications(
    driver_user_id,driver_name,period_start,period_end,title,source,summary,published_at)
  values(
    v_driver,trim(p_report->>'driver_name'),v_month,(v_month+interval '1 month - 1 day')::date,
    to_char(v_month,'YYYY-MM')||' 안전운전 분석','eTAS',
    jsonb_build_object('report_id',v_report_id,'safety_level',p_report->>'safety_level',
      'total_score',p_report->>'total_score','summary_text',p_report->>'summary_text',
      'weekday_text',p_report->>'weekday_text','time_text',p_report->>'time_text',
      'trend_text',p_report->>'trend_text'),now())
  on conflict(driver_user_id,period_start,period_end,source) do update set
    summary=excluded.summary,published_at=now(),title=excluded.title
  returning id into v_pub_id;

  delete from public.driver_acknowledgements where publication_id=v_pub_id;
  perform public._audit(v_admin,'IMPORT_ETAS','etas_report',v_report_id::text,
    jsonb_build_object('driver',p_report->>'driver_name','month',v_month));
  return jsonb_build_object('ok',true,'report_id',v_report_id,'driver_user_id',v_driver);
end $$;

create or replace function public.admin_reset_password(p_token text,p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,extensions
as $$
declare v_admin uuid;
begin
  v_admin:=public._require_admin(p_token);
  update public.app_users
  set password_hash=extensions.crypt('1111',extensions.gen_salt('bf',10)),
      must_change_password=true,
      updated_at=now()
  where id=p_user_id;
  delete from public.app_sessions where user_id=p_user_id;
  perform public._audit(v_admin,'RESET_PASSWORD','app_user',p_user_id::text);
  return jsonb_build_object('ok',true);
end $$;

-- Re-grant RPCs used from browser/collector.
revoke execute on function public.app_login(text,text) from public;
revoke execute on function public.app_change_password(text,text,text) from public;
revoke execute on function public.admin_import_dispatch(text,jsonb,text) from public;
revoke execute on function public.admin_import_etas(text,jsonb) from public;
revoke execute on function public.admin_reset_password(text,uuid) from public;

grant execute on function public.app_login(text,text) to anon, authenticated;
grant execute on function public.app_change_password(text,text,text) to anon, authenticated;
grant execute on function public.admin_import_dispatch(text,jsonb,text) to anon, authenticated;
grant execute on function public.admin_import_etas(text,jsonb) to anon, authenticated;
grant execute on function public.admin_reset_password(text,uuid) to anon, authenticated;

-- Self-test: these must all be non-null/true.
select
  n.nspname as pgcrypto_schema,
  to_regprocedure('extensions.crypt(text,text)') as crypt_function,
  to_regprocedure('extensions.gen_salt(text,integer)') as gen_salt_function
from pg_extension e
join pg_namespace n on n.oid=e.extnamespace
where e.extname='pgcrypto';

-- Direct password hash test. Should return true.
select extensions.crypt('1111', extensions.gen_salt('bf',10)) is not null as pgcrypto_test_ok;

-- Show admin status only; password hash is intentionally not displayed.
select login_id,display_name,role,must_change_password,active
from public.app_users where login_id='관리자';
