-- 대운교통 SafeDrive NEW v1.0
-- Supabase SQL Editor에서 전체 실행
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Supabase project may already have pgcrypto enabled in another schema.
-- pgcrypto is relocatable, so normalize it to extensions for stable RPC calls.
do $$
declare v_pgcrypto_schema text;
begin
  select n.nspname into v_pgcrypto_schema
  from pg_extension e join pg_namespace n on n.oid=e.extnamespace
  where e.extname='pgcrypto';
  if v_pgcrypto_schema is not null and v_pgcrypto_schema <> 'extensions' then
    execute 'alter extension pgcrypto set schema extensions';
  end if;
end $$;

create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  login_id text not null unique,
  display_name text not null,
  role text not null default 'driver' check (role in ('admin','driver')),
  password_hash text not null,
  must_change_password boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz
);

create table if not exists public.app_sessions (
  token uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days')
);
create index if not exists ix_app_sessions_user on public.app_sessions(user_id);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  user_id uuid references public.app_users(id),
  action text not null,
  entity_type text,
  entity_id text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ix_audit_created on public.audit_logs(created_at desc);

create table if not exists public.dispatch_assignments (
  id bigint generated always as identity primary key,
  service_date date not null,
  vehicle_no text not null,
  driver_name text not null,
  driver_user_id uuid references public.app_users(id),
  shift_type text not null default 'UNKNOWN',
  shift_start timestamptz,
  shift_end timestamptz,
  route_no text not null default '',
  run_order integer not null default -1,
  support_route_no text,
  support_run_order integer,
  source_file text,
  source_format text,
  imported_at timestamptz not null default now(),
  unique(service_date, vehicle_no, driver_name, shift_type)
);
create index if not exists ix_dispatch_date_vehicle on public.dispatch_assignments(service_date,vehicle_no);
create index if not exists ix_dispatch_driver_date on public.dispatch_assignments(driver_name,service_date);
create index if not exists ix_dispatch_route_date on public.dispatch_assignments(route_no,service_date);

create table if not exists public.vehicle_change_events (
  id bigint generated always as identity primary key,
  change_key text not null unique,
  service_date date not null,
  route_no text not null default '',
  run_order integer not null default -1,
  driver_name text,
  driver_user_id uuid references public.app_users(id),
  old_vehicle text not null,
  new_vehicle text not null,
  detected_at timestamptz not null,
  node_order integer,
  latitude double precision,
  longitude double precision,
  confidence text not null default 'medium',
  source text not null default 'TAGO',
  raw jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ix_vehicle_change_date on public.vehicle_change_events(service_date,detected_at);
create index if not exists ix_vehicle_change_driver on public.vehicle_change_events(driver_name,service_date);

create table if not exists public.taco_imports (
  id bigint generated always as identity primary key,
  source_file text not null,
  source_path text,
  sha256 text not null unique,
  service_date date,
  vehicle_no text,
  first_record_at timestamptz,
  last_record_at timestamptz,
  record_count integer not null default 0,
  parser_version text,
  imported_at timestamptz not null default now()
);

create table if not exists public.taco_events (
  id bigint generated always as identity primary key,
  import_id bigint not null references public.taco_imports(id) on delete cascade,
  event_key text not null unique,
  service_date date,
  vehicle_no text,
  driver_name text,
  driver_user_id uuid references public.app_users(id),
  route_no text not null default '',
  run_order integer not null default -1,
  recorded_at timestamptz not null,
  event_type text not null,
  severity text not null default 'candidate',
  speed_before numeric,
  speed_after numeric,
  brake_on boolean,
  latitude double precision,
  longitude double precision,
  evidence jsonb not null default '{}'::jsonb,
  criteria_version text not null default 'LOCAL-CANDIDATE-v1',
  created_at timestamptz not null default now()
);
create index if not exists ix_taco_events_driver on public.taco_events(driver_name,service_date,recorded_at);
create index if not exists ix_taco_events_vehicle on public.taco_events(vehicle_no,recorded_at);

create table if not exists public.taco_driver_daily (
  id bigint generated always as identity primary key,
  service_date date not null,
  driver_name text not null,
  driver_user_id uuid references public.app_users(id),
  vehicle_no text not null default '',
  route_no text not null default '',
  distance_km numeric not null default 0,
  max_speed numeric not null default 0,
  rapid_start integer not null default 0,
  rapid_accel integer not null default 0,
  rapid_decel integer not null default 0,
  rapid_stop integer not null default 0,
  speed_watch integer not null default 0,
  valid_pair_count integer not null default 0,
  gap_seconds integer not null default 0,
  data_quality text not null default 'unknown',
  updated_at timestamptz not null default now(),
  unique(service_date,driver_name,vehicle_no,route_no)
);
create index if not exists ix_taco_daily_driver on public.taco_driver_daily(driver_name,service_date desc);

create table if not exists public.etas_reports (
  id bigint generated always as identity primary key,
  driver_name text not null,
  driver_user_id uuid references public.app_users(id),
  analysis_month date not null,
  safety_level text,
  total_score numeric,
  summary_text text,
  weekday_text text,
  time_text text,
  trend_text text,
  recommendations jsonb not null default '[]'::jsonb,
  source_file text,
  raw jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  unique(driver_name,analysis_month)
);
create index if not exists ix_etas_driver_month on public.etas_reports(driver_name,analysis_month desc);

create table if not exists public.etas_behavior_scores (
  id bigint generated always as identity primary key,
  report_id bigint not null references public.etas_reports(id) on delete cascade,
  behavior text not null,
  current_score numeric,
  previous_score numeric,
  change_score numeric,
  grade text,
  unique(report_id,behavior)
);

create table if not exists public.driver_publications (
  id bigint generated always as identity primary key,
  driver_user_id uuid not null references public.app_users(id) on delete cascade,
  driver_name text not null,
  period_start date not null,
  period_end date not null,
  title text not null,
  source text not null,
  summary jsonb not null default '{}'::jsonb,
  published_at timestamptz not null default now(),
  unique(driver_user_id,period_start,period_end,source)
);
create index if not exists ix_publications_driver on public.driver_publications(driver_user_id,published_at desc);

create table if not exists public.driver_acknowledgements (
  publication_id bigint not null references public.driver_publications(id) on delete cascade,
  user_id uuid not null references public.app_users(id) on delete cascade,
  acknowledged_at timestamptz not null default now(),
  comment text,
  primary key(publication_id,user_id)
);

create table if not exists public.risk_rules (
  id bigint generated always as identity primary key,
  rule_key text not null unique,
  label text not null,
  threshold jsonb not null,
  enabled boolean not null default true,
  note text,
  updated_at timestamptz not null default now()
);

insert into public.risk_rules(rule_key,label,threshold,note) values
 ('rapid_start','급출발 후보','{"prev_max":5,"delta_min":8}'::jsonb,'CDT 1초 속도차분 기반 후보값. 공단 공식 판정과 구분'),
 ('rapid_accel','급가속 후보','{"prev_min":6,"delta_min":6}'::jsonb,'CDT 1초 속도차분 기반 후보값'),
 ('rapid_decel','급감속 후보','{"current_min":6,"delta_max":-9}'::jsonb,'CDT 1초 속도차분 기반 후보값'),
 ('rapid_stop','급정지 후보','{"current_max":5,"delta_max":-9}'::jsonb,'CDT 1초 속도차분 기반 후보값'),
 ('speed_watch','관리속도 초과 후보','{"speed_min":80}'::jsonb,'도로 제한속도 연계 전 회사 관리용 후보값')
on conflict(rule_key) do nothing;

-- 직접 테이블 접근은 차단하고 SECURITY DEFINER RPC만 사용
alter table public.app_users enable row level security;
alter table public.app_sessions enable row level security;
alter table public.audit_logs enable row level security;
alter table public.dispatch_assignments enable row level security;
alter table public.vehicle_change_events enable row level security;
alter table public.taco_imports enable row level security;
alter table public.taco_events enable row level security;
alter table public.taco_driver_daily enable row level security;
alter table public.etas_reports enable row level security;
alter table public.etas_behavior_scores enable row level security;
alter table public.driver_publications enable row level security;
alter table public.driver_acknowledgements enable row level security;
alter table public.risk_rules enable row level security;

-- 초기 관리자: 로그인 ID '관리자' / 초기 비밀번호 '1111' / 첫 로그인 후 변경 필수
insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
values ('관리자','관리자','admin',extensions.crypt('1111',extensions.gen_salt('bf',10)),true)
on conflict(login_id) do nothing;

create or replace function public._session_user_id(p_token text)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid;
begin
  select s.user_id into v_uid
  from public.app_sessions s join public.app_users u on u.id=s.user_id
  where s.token::text=p_token and s.expires_at>now() and u.active=true;
  return v_uid;
end $$;

create or replace function public._require_admin(p_token text)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid;
begin
  v_uid:=public._session_user_id(p_token);
  if v_uid is null or not exists(select 1 from public.app_users where id=v_uid and role='admin') then
    raise exception '관리자 권한이 필요합니다.';
  end if;
  return v_uid;
end $$;

create or replace function public._audit(p_uid uuid,p_action text,p_entity text default null,p_entity_id text default null,p_detail jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  insert into public.audit_logs(user_id,action,entity_type,entity_id,detail)
  values(p_uid,p_action,p_entity,p_entity_id,coalesce(p_detail,'{}'::jsonb));
end $$;

create or replace function public.app_login(p_login_id text,p_password text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_u public.app_users; v_token uuid;
begin
  select * into v_u from public.app_users where login_id=trim(p_login_id) and active=true;
  if v_u.id is null or extensions.crypt(p_password,v_u.password_hash)<>v_u.password_hash then
    raise exception '아이디 또는 비밀번호가 올바르지 않습니다.';
  end if;
  delete from public.app_sessions where expires_at<=now();
  insert into public.app_sessions(user_id) values(v_u.id) returning token into v_token;
  update public.app_users set last_login_at=now() where id=v_u.id;
  perform public._audit(v_u.id,'LOGIN','app_user',v_u.id::text,jsonb_build_object('login_id',v_u.login_id));
  return jsonb_build_object('token',v_token::text,'user_id',v_u.id,'login_id',v_u.login_id,'display_name',v_u.display_name,'role',v_u.role,'must_change_password',v_u.must_change_password,'expires_at',now()+interval '7 days');
end $$;

create or replace function public.app_me(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid; v_u public.app_users;
begin
  v_uid:=public._session_user_id(p_token); if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  select * into v_u from public.app_users where id=v_uid;
  return jsonb_build_object('user_id',v_u.id,'login_id',v_u.login_id,'display_name',v_u.display_name,'role',v_u.role,'must_change_password',v_u.must_change_password);
end $$;

create or replace function public.app_change_password(p_token text,p_old_password text,p_new_password text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid; v_hash text;
begin
  v_uid:=public._session_user_id(p_token); if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  if length(p_new_password)<6 or p_new_password='1111' then raise exception '새 비밀번호는 6자 이상이며 1111과 달라야 합니다.'; end if;
  select password_hash into v_hash from public.app_users where id=v_uid;
  if extensions.crypt(p_old_password,v_hash)<>v_hash then raise exception '현재 비밀번호가 올바르지 않습니다.'; end if;
  update public.app_users set password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf',10)),must_change_password=false,updated_at=now() where id=v_uid;
  perform public._audit(v_uid,'PASSWORD_CHANGE','app_user',v_uid::text);
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.app_logout(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid;
begin
  v_uid:=public._session_user_id(p_token);
  delete from public.app_sessions where token::text=p_token;
  if v_uid is not null then perform public._audit(v_uid,'LOGOUT','app_user',v_uid::text); end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.admin_import_dispatch(p_token text,p_rows jsonb,p_source_file text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_admin uuid;
  v_count int:=0;
  v_driver_count int:=0;
  v_input_count int:=0;
  v_default_hash text;
begin
  v_admin:=public._require_admin(p_token);
  v_input_count:=jsonb_array_length(coalesce(p_rows,'[]'::jsonb));
  if v_input_count=0 then
    return jsonb_build_object('ok',true,'rows',0,'input_rows',0,'new_drivers',0);
  end if;

  -- Create the common initial-password hash only once per import.
  -- The first login forces each driver to change password from 1111.
  v_default_hash:=extensions.crypt('1111',extensions.gen_salt('bf',10));

  with src as (
    select distinct trim(e.value->>'driver_name') as driver_name
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) as e(value)
    where coalesce(trim(e.value->>'driver_name'),'')<>''
  )
  insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
  select driver_name,driver_name,'driver',v_default_hash,true
  from src
  on conflict(login_id) do nothing;
  get diagnostics v_driver_count = row_count;

  with parsed as (
    select
      nullif(trim(e.value->>'service_date'),'')::date as service_date,
      trim(e.value->>'vehicle_no') as vehicle_no,
      trim(e.value->>'driver_name') as driver_name,
      coalesce(nullif(trim(e.value->>'shift_type'),''),'UNKNOWN') as shift_type,
      case when coalesce(trim(e.value->>'shift_start'),'')='' then null else (e.value->>'shift_start')::timestamptz end as shift_start,
      case when coalesce(trim(e.value->>'shift_end'),'')='' then null else (e.value->>'shift_end')::timestamptz end as shift_end,
      coalesce(trim(e.value->>'route_no'),'') as route_no,
      coalesce(nullif(trim(e.value->>'run_order'),'')::int,-1) as run_order,
      nullif(trim(coalesce(e.value->>'support_route_no','')),'') as support_route_no,
      nullif(trim(e.value->>'support_run_order'),'')::int as support_run_order,
      coalesce(nullif(trim(e.value->>'source_format'),''),'unknown') as source_format
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) as e(value)
    where coalesce(trim(e.value->>'driver_name'),'')<>''
      and coalesce(trim(e.value->>'vehicle_no'),'')<>''
      and coalesce(trim(e.value->>'service_date'),'')<>''
  ),
  merged as (
    select
      service_date,
      vehicle_no,
      driver_name,
      shift_type,
      max(shift_start) as shift_start,
      max(shift_end) as shift_end,
      coalesce(max(nullif(route_no,'')),'') as route_no,
      max(run_order) as run_order,
      max(support_route_no) as support_route_no,
      max(support_run_order) as support_run_order,
      case when count(distinct source_format)>1 then 'MERGED' else max(source_format) end as source_format
    from parsed
    group by service_date,vehicle_no,driver_name,shift_type
  )
  insert into public.dispatch_assignments(
    service_date,vehicle_no,driver_name,driver_user_id,shift_type,
    shift_start,shift_end,route_no,run_order,support_route_no,support_run_order,
    source_file,source_format
  )
  select
    m.service_date,m.vehicle_no,m.driver_name,u.id,m.shift_type,
    m.shift_start,m.shift_end,m.route_no,m.run_order,m.support_route_no,m.support_run_order,
    p_source_file,m.source_format
  from merged m
  join public.app_users u on u.login_id=m.driver_name
  on conflict(service_date,vehicle_no,driver_name,shift_type) do update set
    driver_user_id=excluded.driver_user_id,
    shift_start=coalesce(excluded.shift_start,public.dispatch_assignments.shift_start),
    shift_end=coalesce(excluded.shift_end,public.dispatch_assignments.shift_end),
    route_no=case when excluded.route_no<>'' then excluded.route_no else public.dispatch_assignments.route_no end,
    run_order=case when excluded.run_order>0 then excluded.run_order else public.dispatch_assignments.run_order end,
    support_route_no=coalesce(excluded.support_route_no,public.dispatch_assignments.support_route_no),
    support_run_order=coalesce(excluded.support_run_order,public.dispatch_assignments.support_run_order),
    source_file=excluded.source_file,
    source_format=case
      when public.dispatch_assignments.source_format<>excluded.source_format then 'MERGED'
      else excluded.source_format
    end,
    imported_at=now();
  get diagnostics v_count = row_count;

  perform public._audit(
    v_admin,'IMPORT_DISPATCH','dispatch',p_source_file,
    jsonb_build_object('input_rows',v_input_count,'saved_rows',v_count,'new_drivers',v_driver_count)
  );
  return jsonb_build_object(
    'ok',true,'rows',v_count,'input_rows',v_input_count,'new_drivers',v_driver_count
  );
end $$;

create or replace function public.admin_import_etas(p_token text,p_report jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_driver uuid; v_report_id bigint; v_pub_id bigint; b jsonb; v_month date;
begin
  v_admin:=public._require_admin(p_token);
  if coalesce(p_report->>'driver_name','')='' then raise exception '운전자 이름이 없습니다.'; end if;
  insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
  values(trim(p_report->>'driver_name'),trim(p_report->>'driver_name'),'driver',extensions.crypt('1111',extensions.gen_salt('bf',10)),true)
  on conflict(login_id) do nothing;
  select id into v_driver from public.app_users where login_id=trim(p_report->>'driver_name');
  v_month=(p_report->>'analysis_month')::date;
  insert into public.etas_reports(driver_name,driver_user_id,analysis_month,safety_level,total_score,summary_text,weekday_text,time_text,trend_text,recommendations,source_file,raw)
  values(trim(p_report->>'driver_name'),v_driver,v_month,p_report->>'safety_level',nullif(p_report->>'total_score','')::numeric,p_report->>'summary_text',p_report->>'weekday_text',p_report->>'time_text',p_report->>'trend_text',coalesce(p_report->'recommendations','[]'::jsonb),p_report->>'source_file',p_report)
  on conflict(driver_name,analysis_month) do update set safety_level=excluded.safety_level,total_score=excluded.total_score,summary_text=excluded.summary_text,weekday_text=excluded.weekday_text,time_text=excluded.time_text,trend_text=excluded.trend_text,recommendations=excluded.recommendations,source_file=excluded.source_file,raw=excluded.raw,imported_at=now(),driver_user_id=excluded.driver_user_id
  returning id into v_report_id;
  delete from public.etas_behavior_scores where report_id=v_report_id;
  for b in select * from jsonb_array_elements(coalesce(p_report->'behaviors','[]'::jsonb)) loop
    insert into public.etas_behavior_scores(report_id,behavior,current_score,previous_score,change_score,grade)
    values(v_report_id,b->>'behavior',nullif(b->>'current_score','')::numeric,nullif(b->>'previous_score','')::numeric,nullif(b->>'change_score','')::numeric,b->>'grade');
  end loop;
  insert into public.driver_publications(driver_user_id,driver_name,period_start,period_end,title,source,summary,published_at)
  values(v_driver,trim(p_report->>'driver_name'),v_month,(v_month+interval '1 month - 1 day')::date,to_char(v_month,'YYYY-MM')||' 안전운전 분석','eTAS',jsonb_build_object('report_id',v_report_id,'safety_level',p_report->>'safety_level','total_score',p_report->>'total_score','summary_text',p_report->>'summary_text','weekday_text',p_report->>'weekday_text','time_text',p_report->>'time_text','trend_text',p_report->>'trend_text'),now())
  on conflict(driver_user_id,period_start,period_end,source) do update set summary=excluded.summary,published_at=now(),title=excluded.title
  returning id into v_pub_id;
  delete from public.driver_acknowledgements where publication_id=v_pub_id;
  perform public._audit(v_admin,'IMPORT_ETAS','etas_report',v_report_id::text,jsonb_build_object('driver',p_report->>'driver_name','month',v_month));
  return jsonb_build_object('ok',true,'report_id',v_report_id,'driver_user_id',v_driver);
end $$;

create or replace function public.collector_get_dispatch(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.route_no,d.run_order,d.shift_type) from public.dispatch_assignments d where d.service_date=p_service_date),'[]'::jsonb);
end $$;

create or replace function public.collector_get_vehicle_changes(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(to_jsonb(v) order by v.detected_at) from public.vehicle_change_events v where v.service_date=p_service_date),'[]'::jsonb);
end $$;

create or replace function public.collector_ingest_vehicle_changes(p_token text,p_changes jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; r jsonb; v_driver uuid; v_count int:=0;
begin
  v_admin:=public._require_admin(p_token);
  for r in select * from jsonb_array_elements(coalesce(p_changes,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(r->>'driver_name',''));
    insert into public.vehicle_change_events(change_key,service_date,route_no,run_order,driver_name,driver_user_id,old_vehicle,new_vehicle,detected_at,node_order,latitude,longitude,confidence,source,raw)
    values(r->>'change_key',(r->>'service_date')::date,coalesce(r->>'route_no',''),coalesce(nullif(r->>'run_order','')::int,-1),r->>'driver_name',v_driver,r->>'old_vehicle',r->>'new_vehicle',(r->>'detected_at')::timestamptz,nullif(r->>'node_order','')::int,nullif(r->>'latitude','')::double precision,nullif(r->>'longitude','')::double precision,coalesce(r->>'confidence','medium'),coalesce(r->>'source','TAGO'),r)
    on conflict(change_key) do nothing;
    if found then v_count:=v_count+1; end if;
  end loop;
  if v_count>0 then perform public._audit(v_admin,'INGEST_BIS_CHANGE','vehicle_change',null,jsonb_build_object('rows',v_count)); end if;
  return jsonb_build_object('ok',true,'inserted',v_count);
end $$;

create or replace function public.collector_ingest_taco(p_token text,p_import jsonb,p_events jsonb,p_summaries jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_import_id bigint; r jsonb; s jsonb; v_driver uuid; v_pub_id bigint; v_pub_summary jsonb; v_event_count int:=0; v_sum_count int:=0;
begin
  v_admin:=public._require_admin(p_token);
  insert into public.taco_imports(source_file,source_path,sha256,service_date,vehicle_no,first_record_at,last_record_at,record_count,parser_version)
  values(p_import->>'source_file',p_import->>'source_path',p_import->>'sha256',nullif(p_import->>'service_date','')::date,p_import->>'vehicle_no',nullif(p_import->>'first_record_at','')::timestamptz,nullif(p_import->>'last_record_at','')::timestamptz,coalesce(nullif(p_import->>'record_count','')::int,0),p_import->>'parser_version')
  on conflict(sha256) do update set source_file=excluded.source_file returning id into v_import_id;
  for r in select * from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(r->>'driver_name',''));
    insert into public.taco_events(import_id,event_key,service_date,vehicle_no,driver_name,driver_user_id,route_no,run_order,recorded_at,event_type,severity,speed_before,speed_after,brake_on,latitude,longitude,evidence,criteria_version)
    values(v_import_id,r->>'event_key',nullif(r->>'service_date','')::date,r->>'vehicle_no',r->>'driver_name',v_driver,coalesce(r->>'route_no',''),coalesce(nullif(r->>'run_order','')::int,-1),(r->>'recorded_at')::timestamptz,r->>'event_type',coalesce(r->>'severity','candidate'),nullif(r->>'speed_before','')::numeric,nullif(r->>'speed_after','')::numeric,nullif(r->>'brake_on','')::boolean,nullif(r->>'latitude','')::double precision,nullif(r->>'longitude','')::double precision,coalesce(r->'evidence','{}'::jsonb),coalesce(r->>'criteria_version','LOCAL-CANDIDATE-v1'))
    on conflict(event_key) do nothing;
    if found then v_event_count:=v_event_count+1; end if;
  end loop;
  for s in select * from jsonb_array_elements(coalesce(p_summaries,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(s->>'driver_name',''));
    if v_driver is null or coalesce(s->>'driver_name','')='' then continue; end if;
    insert into public.taco_driver_daily(service_date,driver_name,driver_user_id,vehicle_no,route_no,distance_km,max_speed,rapid_start,rapid_accel,rapid_decel,rapid_stop,speed_watch,valid_pair_count,gap_seconds,data_quality)
    values((s->>'service_date')::date,s->>'driver_name',v_driver,coalesce(s->>'vehicle_no',''),coalesce(s->>'route_no',''),coalesce(nullif(s->>'distance_km','')::numeric,0),coalesce(nullif(s->>'max_speed','')::numeric,0),coalesce(nullif(s->>'rapid_start','')::int,0),coalesce(nullif(s->>'rapid_accel','')::int,0),coalesce(nullif(s->>'rapid_decel','')::int,0),coalesce(nullif(s->>'rapid_stop','')::int,0),coalesce(nullif(s->>'speed_watch','')::int,0),coalesce(nullif(s->>'valid_pair_count','')::int,0),coalesce(nullif(s->>'gap_seconds','')::int,0),coalesce(s->>'data_quality','unknown'))
    on conflict(service_date,driver_name,vehicle_no,route_no) do update set distance_km=excluded.distance_km,max_speed=excluded.max_speed,rapid_start=excluded.rapid_start,rapid_accel=excluded.rapid_accel,rapid_decel=excluded.rapid_decel,rapid_stop=excluded.rapid_stop,speed_watch=excluded.speed_watch,valid_pair_count=excluded.valid_pair_count,gap_seconds=excluded.gap_seconds,data_quality=excluded.data_quality,updated_at=now(),driver_user_id=excluded.driver_user_id;
    v_sum_count:=v_sum_count+1;
    select jsonb_build_object(
      'service_date',(s->>'service_date')::date,
      'driver_name',s->>'driver_name',
      'distance_km',round(coalesce(sum(distance_km),0)::numeric,3),
      'max_speed',coalesce(max(max_speed),0),
      'rapid_start',coalesce(sum(rapid_start),0),
      'rapid_accel',coalesce(sum(rapid_accel),0),
      'rapid_decel',coalesce(sum(rapid_decel),0),
      'rapid_stop',coalesce(sum(rapid_stop),0),
      'speed_watch',coalesce(sum(speed_watch),0),
      'valid_pair_count',coalesce(sum(valid_pair_count),0),
      'gap_seconds',coalesce(sum(gap_seconds),0),
      'vehicles',to_jsonb(array_remove(array_agg(distinct nullif(vehicle_no,'')),null)),
      'routes',to_jsonb(array_remove(array_agg(distinct nullif(route_no,'')),null)),
      'data_quality',case when bool_or(data_quality='limited') then 'limited' when bool_or(data_quality='review') then 'review' else 'good' end
    ) into v_pub_summary
    from public.taco_driver_daily
    where service_date=(s->>'service_date')::date and driver_name=s->>'driver_name';

    insert into public.driver_publications(driver_user_id,driver_name,period_start,period_end,title,source,summary,published_at)
    values(v_driver,s->>'driver_name',(s->>'service_date')::date,(s->>'service_date')::date,(s->>'service_date')||' CDT 운행분석','CDT',v_pub_summary,now())
    on conflict(driver_user_id,period_start,period_end,source) do update set summary=excluded.summary,published_at=now(),title=excluded.title
    returning id into v_pub_id;
    delete from public.driver_acknowledgements where publication_id=v_pub_id;
  end loop;
  perform public._audit(v_admin,'INGEST_TACO','taco_import',v_import_id::text,jsonb_build_object('events',v_event_count,'summaries',v_sum_count,'file',p_import->>'source_file'));
  return jsonb_build_object('ok',true,'import_id',v_import_id,'events',v_event_count,'summaries',v_sum_count);
end $$;

create or replace function public.driver_dashboard(p_token text,p_limit int default 20)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid; v_name text;
begin
  v_uid:=public._session_user_id(p_token); if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  select display_name into v_name from public.app_users where id=v_uid;
  return jsonb_build_object(
    'user',(select jsonb_build_object('display_name',display_name,'login_id',login_id,'must_change_password',must_change_password) from public.app_users where id=v_uid),
    'publications',coalesce((select jsonb_agg(x) from (select p.id,p.period_start,p.period_end,p.title,p.source,p.summary,p.published_at,(a.acknowledged_at is not null) acknowledged,a.acknowledged_at from public.driver_publications p left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=v_uid where p.driver_user_id=v_uid order by p.published_at desc limit p_limit) x),'[]'::jsonb),
    'etas',coalesce((select jsonb_agg(x) from (select e.*,coalesce((select jsonb_agg(b order by b.id) from public.etas_behavior_scores b where b.report_id=e.id),'[]'::jsonb) behaviors from public.etas_reports e where e.driver_user_id=v_uid order by e.analysis_month desc limit 12) x),'[]'::jsonb),
    'taco_daily',coalesce((select jsonb_agg(x) from (select * from public.taco_driver_daily where driver_user_id=v_uid order by service_date desc limit 31) x),'[]'::jsonb),
    'dispatch',coalesce((select jsonb_agg(x) from (select service_date,vehicle_no,shift_type,shift_start,shift_end,route_no,run_order from public.dispatch_assignments where driver_user_id=v_uid order by service_date desc,shift_start desc limit 31) x),'[]'::jsonb),
    'vehicle_changes',coalesce((select jsonb_agg(x) from (select service_date,route_no,run_order,old_vehicle,new_vehicle,detected_at,confidence from public.vehicle_change_events where driver_user_id=v_uid or driver_name=v_name order by detected_at desc limit 30) x),'[]'::jsonb)
  );
end $$;

create or replace function public.driver_acknowledge(p_token text,p_publication_id bigint,p_comment text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid;
begin
  v_uid:=public._session_user_id(p_token); if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  if not exists(select 1 from public.driver_publications where id=p_publication_id and driver_user_id=v_uid) then raise exception '본인의 분석자료만 확인할 수 있습니다.'; end if;
  insert into public.driver_acknowledgements(publication_id,user_id,comment) values(p_publication_id,v_uid,p_comment)
  on conflict(publication_id,user_id) do update set acknowledged_at=now(),comment=excluded.comment;
  perform public._audit(v_uid,'ACK_ANALYSIS','driver_publication',p_publication_id::text);
  return jsonb_build_object('ok',true,'acknowledged_at',now());
end $$;

create or replace function public.admin_dashboard(p_token text,p_service_date date default current_date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid;
begin
  v_admin:=public._require_admin(p_token);
  return jsonb_build_object(
    'counts',jsonb_build_object(
      'drivers',(select count(*) from public.app_users where role='driver' and active),
      'dispatch',(select count(*) from public.dispatch_assignments where service_date=p_service_date),
      'vehicle_changes',(select count(*) from public.vehicle_change_events where service_date=p_service_date),
      'taco_imports',(select count(*) from public.taco_imports where service_date=p_service_date),
      'unacknowledged',(select count(*) from public.driver_publications p left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=p.driver_user_id where a.publication_id is null)
    ),
    'changes',coalesce((select jsonb_agg(x) from (select * from public.vehicle_change_events where service_date=p_service_date order by detected_at desc limit 50) x),'[]'::jsonb),
    'taco_daily',coalesce((select jsonb_agg(x) from (select * from public.taco_driver_daily where service_date=p_service_date order by (rapid_start+rapid_accel+rapid_decel+rapid_stop+speed_watch) desc limit 50) x),'[]'::jsonb),
    'recent_imports',coalesce((select jsonb_agg(x) from (select * from public.taco_imports order by imported_at desc limit 20) x),'[]'::jsonb)
  );
end $$;

create or replace function public.admin_list_dispatch(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(to_jsonb(d) order by route_no,run_order,shift_type,vehicle_no) from public.dispatch_assignments d where service_date=p_service_date),'[]'::jsonb);
end $$;

create or replace function public.admin_list_users(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(x) from (select id,login_id,display_name,role,must_change_password,active,last_login_at,created_at from public.app_users order by role,display_name) x),'[]'::jsonb);
end $$;

create or replace function public.admin_reset_password(p_token text,p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid;
begin
  v_admin:=public._require_admin(p_token);
  update public.app_users set password_hash=extensions.crypt('1111',extensions.gen_salt('bf',10)),must_change_password=true,updated_at=now() where id=p_user_id;
  delete from public.app_sessions where user_id=p_user_id;
  perform public._audit(v_admin,'RESET_PASSWORD','app_user',p_user_id::text);
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.admin_ack_status(p_token text,p_limit int default 200)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(x) from (select p.id,p.driver_name,p.period_start,p.period_end,p.title,p.source,p.published_at,a.acknowledged_at,a.comment from public.driver_publications p left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=p.driver_user_id order by p.published_at desc limit p_limit) x),'[]'::jsonb);
end $$;

create or replace function public.admin_audit(p_token text,p_limit int default 200)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(x) from (select l.id,u.display_name user_name,l.action,l.entity_type,l.entity_id,l.detail,l.created_at from public.audit_logs l left join public.app_users u on u.id=l.user_id order by l.created_at desc limit p_limit) x),'[]'::jsonb);
end $$;

-- SECURITY DEFINER 함수의 기본 PUBLIC 실행권한 제거
revoke execute on function public._session_user_id(text) from public;
revoke execute on function public._require_admin(text) from public;
revoke execute on function public._audit(uuid,text,text,text,jsonb) from public;
revoke execute on function public.app_login(text,text) from public;
revoke execute on function public.app_me(text) from public;
revoke execute on function public.app_change_password(text,text,text) from public;
revoke execute on function public.app_logout(text) from public;
revoke execute on function public.admin_import_dispatch(text,jsonb,text) from public;
revoke execute on function public.admin_import_etas(text,jsonb) from public;
revoke execute on function public.collector_get_dispatch(text,date) from public;
revoke execute on function public.collector_get_vehicle_changes(text,date) from public;
revoke execute on function public.collector_ingest_vehicle_changes(text,jsonb) from public;
revoke execute on function public.collector_ingest_taco(text,jsonb,jsonb,jsonb) from public;
revoke execute on function public.driver_dashboard(text,int) from public;
revoke execute on function public.driver_acknowledge(text,bigint,text) from public;
revoke execute on function public.admin_dashboard(text,date) from public;
revoke execute on function public.admin_list_dispatch(text,date) from public;
revoke execute on function public.admin_list_users(text) from public;
revoke execute on function public.admin_reset_password(text,uuid) from public;
revoke execute on function public.admin_ack_status(text,int) from public;
revoke execute on function public.admin_audit(text,int) from public;

-- PostgREST anon role에는 RPC 실행만 허용. 테이블 직접 접근은 RLS로 차단됨.
grant execute on function public.app_login(text,text) to anon, authenticated;
grant execute on function public.app_me(text) to anon, authenticated;
grant execute on function public.app_change_password(text,text,text) to anon, authenticated;
grant execute on function public.app_logout(text) to anon, authenticated;
grant execute on function public.admin_import_dispatch(text,jsonb,text) to anon, authenticated;
grant execute on function public.admin_import_etas(text,jsonb) to anon, authenticated;
grant execute on function public.collector_get_dispatch(text,date) to anon, authenticated;
grant execute on function public.collector_get_vehicle_changes(text,date) to anon, authenticated;
grant execute on function public.collector_ingest_vehicle_changes(text,jsonb) to anon, authenticated;
grant execute on function public.collector_ingest_taco(text,jsonb,jsonb,jsonb) to anon, authenticated;
grant execute on function public.driver_dashboard(text,int) to anon, authenticated;
grant execute on function public.driver_acknowledge(text,bigint,text) to anon, authenticated;
grant execute on function public.admin_dashboard(text,date) to anon, authenticated;
grant execute on function public.admin_list_dispatch(text,date) to anon, authenticated;
grant execute on function public.admin_list_users(text) to anon, authenticated;
grant execute on function public.admin_reset_password(text,uuid) to anon, authenticated;
grant execute on function public.admin_ack_status(text,int) to anon, authenticated;
grant execute on function public.admin_audit(text,int) to anon, authenticated;


-- ===== v1.1.0 operational upgrade =====
-- Daewoon SafeDrive AI v1.1.0
-- Existing Supabase project upgrade: collector monitoring, automatic eTAS history,
-- administrator driver reports and collector commands.
-- Safe to run repeatedly. Existing business data is not deleted.

alter table public.etas_reports
  add column if not exists import_source text not null default 'manual',
  add column if not exists source_sha256 text,
  add column if not exists source_path text,
  add column if not exists collector_agent_id text;

alter table public.taco_imports
  add column if not exists collector_agent_id text;

alter table public.vehicle_change_events
  add column if not exists collector_agent_id text,
  add column if not exists confirmed_polls integer not null default 0;

create index if not exists ix_etas_imported_at on public.etas_reports(imported_at desc);
create index if not exists ix_etas_import_source on public.etas_reports(import_source, imported_at desc);

create table if not exists public.collector_agents (
  agent_id text primary key,
  host_name text,
  version text,
  status text not null default 'unknown',
  process_id integer,
  started_at timestamptz,
  last_heartbeat_at timestamptz,
  last_taco_scan_at timestamptz,
  last_bis_poll_at timestamptz,
  last_etas_scan_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  counters jsonb not null default '{}'::jsonb,
  config_summary jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.collector_activity_logs (
  id bigint generated always as identity primary key,
  agent_id text,
  category text not null,
  level text not null default 'info',
  message text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ix_collector_activity_created on public.collector_activity_logs(created_at desc);
create index if not exists ix_collector_activity_agent on public.collector_activity_logs(agent_id,created_at desc);

create table if not exists public.collector_commands (
  id bigint generated always as identity primary key,
  agent_id text not null,
  command text not null check(command in ('reload','restart','stop')),
  status text not null default 'pending' check(status in ('pending','delivered','completed','failed')),
  requested_by uuid references public.app_users(id),
  requested_at timestamptz not null default now(),
  delivered_at timestamptz,
  completed_at timestamptz,
  result text
);
create index if not exists ix_collector_commands_pending on public.collector_commands(agent_id,status,requested_at);

alter table public.collector_agents enable row level security;
alter table public.collector_activity_logs enable row level security;
alter table public.collector_commands enable row level security;

-- eTAS import: supports both browser/manual and collector/automatic sources.
create or replace function public.admin_import_etas(p_token text,p_report jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_admin uuid;
  v_driver uuid;
  v_report_id bigint;
  v_pub_id bigint;
  b jsonb;
  v_month date;
  v_source text;
begin
  v_admin:=public._require_admin(p_token);
  if coalesce(trim(p_report->>'driver_name'),'')='' then
    raise exception '운전자 이름이 없습니다.';
  end if;

  insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
  values(
    trim(p_report->>'driver_name'),
    trim(p_report->>'driver_name'),
    'driver',
    extensions.crypt('1111',extensions.gen_salt('bf',10)),
    true
  )
  on conflict(login_id) do nothing;

  select id into v_driver
  from public.app_users
  where login_id=trim(p_report->>'driver_name');

  v_month=(p_report->>'analysis_month')::date;
  v_source=coalesce(nullif(trim(p_report->>'import_source'),''),'manual');

  insert into public.etas_reports(
    driver_name,driver_user_id,analysis_month,safety_level,total_score,
    summary_text,weekday_text,time_text,trend_text,recommendations,
    source_file,raw,import_source,source_sha256,source_path,collector_agent_id
  )
  values(
    trim(p_report->>'driver_name'),v_driver,v_month,p_report->>'safety_level',
    nullif(p_report->>'total_score','')::numeric,p_report->>'summary_text',
    p_report->>'weekday_text',p_report->>'time_text',p_report->>'trend_text',
    coalesce(p_report->'recommendations','[]'::jsonb),p_report->>'source_file',p_report,
    v_source,nullif(p_report->>'source_sha256',''),p_report->>'source_path',p_report->>'collector_agent_id'
  )
  on conflict(driver_name,analysis_month) do update set
    safety_level=excluded.safety_level,
    total_score=excluded.total_score,
    summary_text=excluded.summary_text,
    weekday_text=excluded.weekday_text,
    time_text=excluded.time_text,
    trend_text=excluded.trend_text,
    recommendations=excluded.recommendations,
    source_file=excluded.source_file,
    raw=excluded.raw,
    import_source=excluded.import_source,
    source_sha256=excluded.source_sha256,
    source_path=excluded.source_path,
    collector_agent_id=excluded.collector_agent_id,
    imported_at=now(),
    driver_user_id=excluded.driver_user_id
  returning id into v_report_id;

  delete from public.etas_behavior_scores where report_id=v_report_id;
  for b in select * from jsonb_array_elements(coalesce(p_report->'behaviors','[]'::jsonb)) loop
    insert into public.etas_behavior_scores(
      report_id,behavior,current_score,previous_score,change_score,grade
    ) values(
      v_report_id,b->>'behavior',nullif(b->>'current_score','')::numeric,
      nullif(b->>'previous_score','')::numeric,nullif(b->>'change_score','')::numeric,
      b->>'grade'
    );
  end loop;

  insert into public.driver_publications(
    driver_user_id,driver_name,period_start,period_end,title,source,summary,published_at
  ) values(
    v_driver,trim(p_report->>'driver_name'),v_month,
    (v_month+interval '1 month - 1 day')::date,
    to_char(v_month,'YYYY-MM')||' 안전운전 분석','eTAS',
    jsonb_build_object(
      'report_id',v_report_id,
      'safety_level',p_report->>'safety_level',
      'total_score',p_report->>'total_score',
      'summary_text',p_report->>'summary_text',
      'weekday_text',p_report->>'weekday_text',
      'time_text',p_report->>'time_text',
      'trend_text',p_report->>'trend_text',
      'import_source',v_source
    ),now()
  )
  on conflict(driver_user_id,period_start,period_end,source) do update set
    summary=excluded.summary,published_at=now(),title=excluded.title
  returning id into v_pub_id;

  -- Updated analysis must be reviewed again by the driver.
  delete from public.driver_acknowledgements where publication_id=v_pub_id;

  perform public._audit(
    v_admin,'IMPORT_ETAS','etas_report',v_report_id::text,
    jsonb_build_object(
      'driver',p_report->>'driver_name','month',v_month,
      'source',v_source,'file',p_report->>'source_file'
    )
  );

  return jsonb_build_object(
    'ok',true,'report_id',v_report_id,'driver_user_id',v_driver,'import_source',v_source
  );
end $$;

create or replace function public.collector_heartbeat(p_token text,p_agent jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_agent_id text;
begin
  v_admin:=public._require_admin(p_token);
  v_agent_id=coalesce(nullif(trim(p_agent->>'agent_id'),''),'default');
  insert into public.collector_agents(
    agent_id,host_name,version,status,process_id,started_at,last_heartbeat_at,
    last_taco_scan_at,last_bis_poll_at,last_etas_scan_at,last_success_at,last_error,
    counters,config_summary,updated_at
  ) values(
    v_agent_id,p_agent->>'host_name',p_agent->>'version',coalesce(p_agent->>'status','running'),
    nullif(p_agent->>'process_id','')::int,nullif(p_agent->>'started_at','')::timestamptz,now(),
    nullif(p_agent->>'last_taco_scan_at','')::timestamptz,
    nullif(p_agent->>'last_bis_poll_at','')::timestamptz,
    nullif(p_agent->>'last_etas_scan_at','')::timestamptz,
    nullif(p_agent->>'last_success_at','')::timestamptz,
    p_agent->>'last_error',coalesce(p_agent->'counters','{}'::jsonb),
    coalesce(p_agent->'config_summary','{}'::jsonb),now()
  )
  on conflict(agent_id) do update set
    host_name=excluded.host_name,version=excluded.version,status=excluded.status,
    process_id=excluded.process_id,started_at=coalesce(excluded.started_at,public.collector_agents.started_at),
    last_heartbeat_at=now(),last_taco_scan_at=coalesce(excluded.last_taco_scan_at,public.collector_agents.last_taco_scan_at),
    last_bis_poll_at=coalesce(excluded.last_bis_poll_at,public.collector_agents.last_bis_poll_at),
    last_etas_scan_at=coalesce(excluded.last_etas_scan_at,public.collector_agents.last_etas_scan_at),
    last_success_at=coalesce(excluded.last_success_at,public.collector_agents.last_success_at),
    last_error=excluded.last_error,counters=excluded.counters,
    config_summary=excluded.config_summary,updated_at=now();
  return jsonb_build_object('ok',true,'agent_id',v_agent_id,'server_time',now());
end $$;

create or replace function public.collector_activity(p_token text,p_event jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_id bigint;
begin
  v_admin:=public._require_admin(p_token);
  insert into public.collector_activity_logs(agent_id,category,level,message,detail)
  values(
    p_event->>'agent_id',coalesce(p_event->>'category','SYSTEM'),
    coalesce(p_event->>'level','info'),coalesce(p_event->>'message',''),
    coalesce(p_event->'detail','{}'::jsonb)
  ) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end $$;

create or replace function public.collector_fetch_commands(p_token text,p_agent_id text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((
    with picked as (
      select id from public.collector_commands
      where agent_id=p_agent_id and status='pending'
      order by requested_at
      limit 10
      for update skip locked
    ), delivered as (
      update public.collector_commands c
      set status='delivered',delivered_at=now()
      from picked p
      where c.id=p.id
      returning c.id,c.command,c.requested_at
    )
    select jsonb_agg(to_jsonb(delivered)) from delivered
  ),'[]'::jsonb);
end $$;

create or replace function public.collector_complete_command(
  p_token text,p_command_id bigint,p_ok boolean,p_result text default null
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  update public.collector_commands
  set status=case when p_ok then 'completed' else 'failed' end,
      completed_at=now(),result=p_result
  where id=p_command_id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.admin_collector_command(
  p_token text,p_agent_id text,p_command text
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_id bigint;
begin
  v_admin:=public._require_admin(p_token);
  if p_command not in ('reload','restart','stop') then raise exception '지원하지 않는 명령입니다.'; end if;
  insert into public.collector_commands(agent_id,command,requested_by)
  values(p_agent_id,p_command,v_admin) returning id into v_id;
  perform public._audit(v_admin,'COLLECTOR_COMMAND','collector',p_agent_id,jsonb_build_object('command',p_command,'command_id',v_id));
  return jsonb_build_object('ok',true,'command_id',v_id);
end $$;

create or replace function public.admin_collector_status(p_token text,p_limit int default 100)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'server_time',now(),
    'agents',coalesce((select jsonb_agg(x order by x.last_heartbeat_at desc) from (
      select a.*,
        case when a.last_heartbeat_at > now()-interval '2 minutes' and a.status='running'
             then true else false end as online
      from public.collector_agents a
    ) x),'[]'::jsonb),
    'activities',coalesce((select jsonb_agg(x) from (
      select * from public.collector_activity_logs order by created_at desc limit p_limit
    ) x),'[]'::jsonb),
    'commands',coalesce((select jsonb_agg(x) from (
      select c.id,c.agent_id,c.command,c.status,c.requested_at,c.delivered_at,c.completed_at,c.result,
             u.display_name requested_by_name
      from public.collector_commands c left join public.app_users u on u.id=c.requested_by
      order by c.requested_at desc limit 30
    ) x),'[]'::jsonb),
    'etas_recent',coalesce((select jsonb_agg(x) from (
      select id,driver_name,analysis_month,safety_level,total_score,source_file,import_source,
             collector_agent_id,imported_at
      from public.etas_reports order by imported_at desc limit 30
    ) x),'[]'::jsonb),
    'taco_recent',coalesce((select jsonb_agg(x) from (
      select id,source_file,service_date,vehicle_no,record_count,parser_version,
             collector_agent_id,imported_at
      from public.taco_imports order by imported_at desc limit 30
    ) x),'[]'::jsonb),
    'bis_recent',coalesce((select jsonb_agg(x) from (
      select id,service_date,route_no,run_order,driver_name,old_vehicle,new_vehicle,
             detected_at,confidence,collector_agent_id,confirmed_polls
      from public.vehicle_change_events order by detected_at desc limit 30
    ) x),'[]'::jsonb),
    'dispatch_recent',coalesce((select jsonb_agg(x) from (
      select service_date,count(*) rows,max(imported_at) imported_at
      from public.dispatch_assignments group by service_date
      order by service_date desc limit 15
    ) x),'[]'::jsonb)
  );
end $$;

create or replace function public.admin_driver_reports(
  p_token text,p_driver_name text default null,p_limit int default 200
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'drivers',coalesce((select jsonb_agg(x) from (
      select id,login_id,display_name,last_login_at,active
      from public.app_users where role='driver'
      order by display_name
    ) x),'[]'::jsonb),
    'etas',coalesce((select jsonb_agg(x) from (
      select e.id,e.driver_name,e.analysis_month,e.safety_level,e.total_score,e.summary_text,
             e.weekday_text,e.time_text,e.trend_text,e.recommendations,e.source_file,
             e.import_source,e.imported_at,
             coalesce((select jsonb_agg(b order by b.id) from public.etas_behavior_scores b where b.report_id=e.id),'[]'::jsonb) behaviors,
             p.id publication_id,a.acknowledged_at
      from public.etas_reports e
      left join public.driver_publications p on p.driver_user_id=e.driver_user_id and p.source='eTAS'
        and p.period_start=e.analysis_month
      left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=e.driver_user_id
      where p_driver_name is null or p_driver_name='' or e.driver_name=p_driver_name
      order by e.analysis_month desc,e.driver_name limit p_limit
    ) x),'[]'::jsonb),
    'cdt',coalesce((select jsonb_agg(x) from (
      select d.*,p.id publication_id,a.acknowledged_at
      from public.taco_driver_daily d
      left join public.driver_publications p on p.driver_user_id=d.driver_user_id and p.source='CDT'
        and p.period_start=d.service_date and p.period_end=d.service_date
      left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=d.driver_user_id
      where p_driver_name is null or p_driver_name='' or d.driver_name=p_driver_name
      order by d.service_date desc,d.driver_name limit p_limit
    ) x),'[]'::jsonb)
  );
end $$;

-- Tag collector agent information during ingestion when supplied.
create or replace function public.collector_ingest_vehicle_changes(p_token text,p_changes jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; r jsonb; v_driver uuid; v_count int:=0;
begin
  v_admin:=public._require_admin(p_token);
  for r in select * from jsonb_array_elements(coalesce(p_changes,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(r->>'driver_name',''));
    insert into public.vehicle_change_events(
      change_key,service_date,route_no,run_order,driver_name,driver_user_id,
      old_vehicle,new_vehicle,detected_at,node_order,latitude,longitude,
      confidence,source,raw,collector_agent_id,confirmed_polls
    ) values(
      r->>'change_key',(r->>'service_date')::date,coalesce(r->>'route_no',''),
      coalesce(nullif(r->>'run_order','')::int,-1),r->>'driver_name',v_driver,
      r->>'old_vehicle',r->>'new_vehicle',(r->>'detected_at')::timestamptz,
      nullif(r->>'node_order','')::int,nullif(r->>'latitude','')::double precision,
      nullif(r->>'longitude','')::double precision,coalesce(r->>'confidence','medium'),
      coalesce(r->>'source','TAGO'),r,nullif(r->>'collector_agent_id',''),
      coalesce(nullif(r->>'confirmed_polls','')::int,0)
    ) on conflict(change_key) do update set
      confidence=excluded.confidence,raw=excluded.raw,
      confirmed_polls=greatest(public.vehicle_change_events.confirmed_polls,excluded.confirmed_polls),
      collector_agent_id=coalesce(excluded.collector_agent_id,public.vehicle_change_events.collector_agent_id);
    if found then v_count:=v_count+1; end if;
  end loop;
  if v_count>0 then perform public._audit(v_admin,'INGEST_BIS_CHANGE','vehicle_change',null,jsonb_build_object('rows',v_count)); end if;
  return jsonb_build_object('ok',true,'inserted',v_count);
end $$;

-- Tag TACO imports with the collector agent id supplied by the collector.
create or replace function public.collector_ingest_taco(p_token text,p_import jsonb,p_events jsonb,p_summaries jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_import_id bigint; r jsonb; s jsonb; v_driver uuid; v_pub_id bigint; v_pub_summary jsonb; v_event_count int:=0; v_sum_count int:=0;
begin
  v_admin:=public._require_admin(p_token);
  insert into public.taco_imports(
    source_file,source_path,sha256,service_date,vehicle_no,first_record_at,
    last_record_at,record_count,parser_version,collector_agent_id
  ) values(
    p_import->>'source_file',p_import->>'source_path',p_import->>'sha256',
    nullif(p_import->>'service_date','')::date,p_import->>'vehicle_no',
    nullif(p_import->>'first_record_at','')::timestamptz,
    nullif(p_import->>'last_record_at','')::timestamptz,
    coalesce(nullif(p_import->>'record_count','')::int,0),p_import->>'parser_version',
    nullif(p_import->>'collector_agent_id','')
  ) on conflict(sha256) do update set
    source_file=excluded.source_file,source_path=excluded.source_path,
    collector_agent_id=coalesce(excluded.collector_agent_id,public.taco_imports.collector_agent_id)
  returning id into v_import_id;

  for r in select * from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(r->>'driver_name',''));
    insert into public.taco_events(
      import_id,event_key,service_date,vehicle_no,driver_name,driver_user_id,
      route_no,run_order,recorded_at,event_type,severity,speed_before,speed_after,
      brake_on,latitude,longitude,evidence,criteria_version
    ) values(
      v_import_id,r->>'event_key',nullif(r->>'service_date','')::date,r->>'vehicle_no',
      r->>'driver_name',v_driver,coalesce(r->>'route_no',''),
      coalesce(nullif(r->>'run_order','')::int,-1),(r->>'recorded_at')::timestamptz,
      r->>'event_type',coalesce(r->>'severity','candidate'),
      nullif(r->>'speed_before','')::numeric,nullif(r->>'speed_after','')::numeric,
      nullif(r->>'brake_on','')::boolean,nullif(r->>'latitude','')::double precision,
      nullif(r->>'longitude','')::double precision,coalesce(r->'evidence','{}'::jsonb),
      coalesce(r->>'criteria_version','LOCAL-CANDIDATE-v1')
    ) on conflict(event_key) do nothing;
    if found then v_event_count:=v_event_count+1; end if;
  end loop;

  for s in select * from jsonb_array_elements(coalesce(p_summaries,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(s->>'driver_name',''));
    if v_driver is null or coalesce(s->>'driver_name','')='' then continue; end if;
    insert into public.taco_driver_daily(
      service_date,driver_name,driver_user_id,vehicle_no,route_no,distance_km,max_speed,
      rapid_start,rapid_accel,rapid_decel,rapid_stop,speed_watch,valid_pair_count,gap_seconds,data_quality
    ) values(
      (s->>'service_date')::date,s->>'driver_name',v_driver,coalesce(s->>'vehicle_no',''),
      coalesce(s->>'route_no',''),coalesce(nullif(s->>'distance_km','')::numeric,0),
      coalesce(nullif(s->>'max_speed','')::numeric,0),coalesce(nullif(s->>'rapid_start','')::int,0),
      coalesce(nullif(s->>'rapid_accel','')::int,0),coalesce(nullif(s->>'rapid_decel','')::int,0),
      coalesce(nullif(s->>'rapid_stop','')::int,0),coalesce(nullif(s->>'speed_watch','')::int,0),
      coalesce(nullif(s->>'valid_pair_count','')::int,0),coalesce(nullif(s->>'gap_seconds','')::int,0),
      coalesce(s->>'data_quality','unknown')
    ) on conflict(service_date,driver_name,vehicle_no,route_no) do update set
      distance_km=excluded.distance_km,max_speed=excluded.max_speed,
      rapid_start=excluded.rapid_start,rapid_accel=excluded.rapid_accel,
      rapid_decel=excluded.rapid_decel,rapid_stop=excluded.rapid_stop,
      speed_watch=excluded.speed_watch,valid_pair_count=excluded.valid_pair_count,
      gap_seconds=excluded.gap_seconds,data_quality=excluded.data_quality,
      updated_at=now(),driver_user_id=excluded.driver_user_id;
    v_sum_count:=v_sum_count+1;

    select jsonb_build_object(
      'service_date',(s->>'service_date')::date,'driver_name',s->>'driver_name',
      'distance_km',round(coalesce(sum(distance_km),0)::numeric,3),
      'max_speed',coalesce(max(max_speed),0),'rapid_start',coalesce(sum(rapid_start),0),
      'rapid_accel',coalesce(sum(rapid_accel),0),'rapid_decel',coalesce(sum(rapid_decel),0),
      'rapid_stop',coalesce(sum(rapid_stop),0),'speed_watch',coalesce(sum(speed_watch),0),
      'valid_pair_count',coalesce(sum(valid_pair_count),0),'gap_seconds',coalesce(sum(gap_seconds),0),
      'vehicles',to_jsonb(array_remove(array_agg(distinct nullif(vehicle_no,'')),null)),
      'routes',to_jsonb(array_remove(array_agg(distinct nullif(route_no,'')),null)),
      'data_quality',case when bool_or(data_quality='limited') then 'limited'
                          when bool_or(data_quality='review') then 'review' else 'good' end
    ) into v_pub_summary
    from public.taco_driver_daily
    where service_date=(s->>'service_date')::date and driver_name=s->>'driver_name';

    insert into public.driver_publications(
      driver_user_id,driver_name,period_start,period_end,title,source,summary,published_at
    ) values(
      v_driver,s->>'driver_name',(s->>'service_date')::date,(s->>'service_date')::date,
      (s->>'service_date')||' CDT 운행분석','CDT',v_pub_summary,now()
    ) on conflict(driver_user_id,period_start,period_end,source) do update set
      summary=excluded.summary,published_at=now(),title=excluded.title
    returning id into v_pub_id;
    delete from public.driver_acknowledgements where publication_id=v_pub_id;
  end loop;

  perform public._audit(
    v_admin,'INGEST_TACO','taco_import',v_import_id::text,
    jsonb_build_object('events',v_event_count,'summaries',v_sum_count,'file',p_import->>'source_file')
  );
  return jsonb_build_object('ok',true,'import_id',v_import_id,'events',v_event_count,'summaries',v_sum_count);
end $$;

-- Permissions for new/replaced RPC functions.
revoke execute on function public.collector_heartbeat(text,jsonb) from public;
revoke execute on function public.collector_activity(text,jsonb) from public;
revoke execute on function public.collector_fetch_commands(text,text) from public;
revoke execute on function public.collector_complete_command(text,bigint,boolean,text) from public;
revoke execute on function public.admin_collector_command(text,text,text) from public;
revoke execute on function public.admin_collector_status(text,int) from public;
revoke execute on function public.admin_driver_reports(text,text,int) from public;
revoke execute on function public.admin_import_etas(text,jsonb) from public;
revoke execute on function public.collector_ingest_vehicle_changes(text,jsonb) from public;
revoke execute on function public.collector_ingest_taco(text,jsonb,jsonb,jsonb) from public;

grant execute on function public.collector_heartbeat(text,jsonb) to anon,authenticated;
grant execute on function public.collector_activity(text,jsonb) to anon,authenticated;
grant execute on function public.collector_fetch_commands(text,text) to anon,authenticated;
grant execute on function public.collector_complete_command(text,bigint,boolean,text) to anon,authenticated;
grant execute on function public.admin_collector_command(text,text,text) to anon,authenticated;
grant execute on function public.admin_collector_status(text,int) to anon,authenticated;
grant execute on function public.admin_driver_reports(text,text,int) to anon,authenticated;
grant execute on function public.admin_import_etas(text,jsonb) to anon,authenticated;
grant execute on function public.collector_ingest_vehicle_changes(text,jsonb) to anon,authenticated;
grant execute on function public.collector_ingest_taco(text,jsonb,jsonb,jsonb) to anon,authenticated;

select 'SafeDrive AI v1.1.0 operational upgrade installed' as status;

-- Daewoon SafeDrive AI v1.2.0
-- 목적:
-- 1) 노선별 운행시간표 버전 관리
-- 2) BIS 실제 운행차량/차량교체 최소정보 저장
-- 3) 차량 입고가 늦어져 며칠 뒤 수집되는 CDT를 실제 운행일 기준으로 재매칭
-- 4) Supabase에는 원본 CDT/BIS 전체가 아닌 메타정보, 집계, 대표 이벤트만 저장
-- 기존 배차/사용자/운행분석 데이터는 삭제하지 않습니다.

begin;

create table if not exists public.route_timetable_versions (
  id bigint generated always as identity primary key,
  version_name text not null,
  effective_from date not null,
  effective_to date,
  season_type text not null default 'NORMAL',
  source_file text,
  active boolean not null default true,
  imported_by uuid references public.app_users(id),
  imported_at timestamptz not null default now(),
  unique(version_name,effective_from,season_type)
);

create table if not exists public.route_timetable_slots (
  id bigint generated always as identity primary key,
  version_id bigint not null references public.route_timetable_versions(id) on delete cascade,
  route_no text not null,
  run_order integer not null,
  day_type text not null,
  direction_name text not null default '',
  departure_time time not null,
  source_sheet text,
  source_row integer,
  unique(version_id,route_no,run_order,day_type,direction_name,departure_time)
);
create index if not exists ix_timetable_version_date on public.route_timetable_versions(effective_from desc,effective_to,active);
create index if not exists ix_timetable_slot_lookup on public.route_timetable_slots(version_id,day_type,route_no,run_order,departure_time);


create table if not exists public.service_calendar_overrides (
  service_date date primary key,
  day_type text not null check(day_type in ('WEEKDAY','SATURDAY','HOLIDAY')),
  note text,
  updated_by uuid references public.app_users(id),
  updated_at timestamptz not null default now()
);
create index if not exists ix_service_calendar_day_type on public.service_calendar_overrides(day_type,service_date);

create table if not exists public.trip_vehicle_bindings (
  id bigint generated always as identity primary key,
  binding_key text not null unique,
  service_date date not null,
  route_no text not null default '',
  run_order integer not null default -1,
  driver_name text,
  driver_user_id uuid references public.app_users(id),
  planned_vehicle text not null,
  actual_vehicle text not null,
  valid_from_at timestamptz not null,
  valid_to_at timestamptz,
  binding_type text not null default 'BIS_CONFIRMED',
  confidence text not null default 'medium',
  source text not null default 'TAGO',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_trip_binding_date_actual on public.trip_vehicle_bindings(service_date,actual_vehicle,valid_from_at);
create index if not exists ix_trip_binding_driver on public.trip_vehicle_bindings(driver_name,service_date,route_no,run_order);

alter table public.vehicle_change_events add column if not exists planned_vehicle text;
alter table public.vehicle_change_events add column if not exists actual_vehicle text;
alter table public.vehicle_change_events add column if not exists change_type text not null default 'MID_ROUTE';
alter table public.vehicle_change_events add column if not exists effective_from_at timestamptz;
alter table public.vehicle_change_events add column if not exists valid_to_at timestamptz;

alter table public.taco_imports add column if not exists collected_at timestamptz not null default now();
alter table public.taco_imports add column if not exists delay_days integer not null default 0;
alter table public.taco_imports add column if not exists match_status text not null default 'matched';
alter table public.taco_imports add column if not exists matched_seconds integer not null default 0;
alter table public.taco_imports add column if not exists unmatched_seconds integer not null default 0;
alter table public.taco_imports add column if not exists local_archive_ref text;
alter table public.taco_imports add column if not exists summary_only boolean not null default true;

alter table public.taco_driver_daily add column if not exists source_import_id bigint references public.taco_imports(id) on delete set null;
alter table public.taco_driver_daily add column if not exists run_order integer not null default -1;
alter table public.taco_driver_daily add column if not exists match_status text not null default 'matched';
alter table public.taco_driver_daily add column if not exists matched_seconds integer not null default 0;
alter table public.taco_driver_daily add column if not exists unmatched_seconds integer not null default 0;
alter table public.taco_driver_daily add column if not exists late_days integer not null default 0;
alter table public.taco_driver_daily add column if not exists safety_score numeric;
alter table public.taco_driver_daily add column if not exists safety_level text;
alter table public.taco_driver_daily add column if not exists event_rates jsonb not null default '{}'::jsonb;
alter table public.taco_driver_daily add column if not exists event_samples jsonb not null default '{}'::jsonb;
alter table public.taco_driver_daily add column if not exists analysis_text text;
alter table public.taco_driver_daily add column if not exists recommendations jsonb not null default '[]'::jsonb;

alter table public.route_timetable_versions enable row level security;
alter table public.route_timetable_slots enable row level security;
alter table public.service_calendar_overrides enable row level security;
alter table public.trip_vehicle_bindings enable row level security;

create or replace function public.admin_import_timetable(
  p_token text,
  p_meta jsonb,
  p_rows jsonb
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_admin uuid;
  v_version_id bigint;
  v_count integer := 0;
begin
  v_admin := public._require_admin(p_token);
  insert into public.route_timetable_versions(
    version_name,effective_from,effective_to,season_type,source_file,active,imported_by,imported_at
  ) values(
    coalesce(nullif(p_meta->>'version_name',''),p_meta->>'source_file','운행시간표'),
    (p_meta->>'effective_from')::date,
    nullif(p_meta->>'effective_to','')::date,
    coalesce(nullif(p_meta->>'season_type',''),'NORMAL'),
    p_meta->>'source_file',true,v_admin,now()
  ) on conflict(version_name,effective_from,season_type) do update set
    effective_to=excluded.effective_to,
    source_file=excluded.source_file,
    active=true,
    imported_by=excluded.imported_by,
    imported_at=now()
  returning id into v_version_id;

  delete from public.route_timetable_slots where version_id=v_version_id;
  insert into public.route_timetable_slots(
    version_id,route_no,run_order,day_type,direction_name,departure_time,source_sheet,source_row
  )
  select
    v_version_id,
    trim(r->>'route_no'),
    (r->>'run_order')::int,
    coalesce(nullif(r->>'day_type',''),'WEEKDAY'),
    coalesce(r->>'direction_name',''),
    (r->>'departure_time')::time,
    r->>'source_sheet',
    nullif(r->>'source_row','')::int
  from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) r
  where coalesce(r->>'route_no','')<>''
    and coalesce(nullif(r->>'run_order','')::int,-1)>0
    and coalesce(r->>'departure_time','')<>''
  on conflict do nothing;
  get diagnostics v_count=row_count;

  perform public._audit(v_admin,'IMPORT_TIMETABLE','route_timetable_version',v_version_id::text,
    jsonb_build_object('rows',v_count,'file',p_meta->>'source_file','effective_from',p_meta->>'effective_from'));
  return jsonb_build_object('ok',true,'version_id',v_version_id,'rows',v_count);
end $$;

create or replace function public.admin_list_timetable_versions(p_token text,p_limit int default 100)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(x) from (
    select v.id,v.version_name,v.effective_from,v.effective_to,v.season_type,v.source_file,
           v.active,v.imported_at,count(s.id)::int slot_count
    from public.route_timetable_versions v
    left join public.route_timetable_slots s on s.version_id=v.id
    group by v.id
    order by v.effective_from desc,v.imported_at desc
    limit p_limit
  ) x),'[]'::jsonb);
end $$;

create or replace function public.admin_upsert_service_calendar(
  p_token text,p_service_date date,p_day_type text,p_note text default null
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid;
begin
  v_admin:=public._require_admin(p_token);
  if p_day_type not in ('WEEKDAY','SATURDAY','HOLIDAY') then
    raise exception '운행일 유형이 올바르지 않습니다.';
  end if;
  insert into public.service_calendar_overrides(service_date,day_type,note,updated_by,updated_at)
  values(p_service_date,p_day_type,p_note,v_admin,now())
  on conflict(service_date) do update set day_type=excluded.day_type,note=excluded.note,
    updated_by=excluded.updated_by,updated_at=now();
  perform public._audit(v_admin,'UPSERT_SERVICE_DAY','service_calendar',p_service_date::text,
    jsonb_build_object('day_type',p_day_type,'note',p_note));
  return jsonb_build_object('ok',true,'service_date',p_service_date,'day_type',p_day_type);
end $$;

create or replace function public.admin_list_service_calendar(
  p_token text,p_from date default (current_date-30),p_to date default (current_date+365)
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(x) from (
    select service_date,day_type,note,updated_at
    from public.service_calendar_overrides
    where service_date between p_from and p_to
    order by service_date
  ) x),'[]'::jsonb);
end $$;

create or replace function public.collector_get_context(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_version_id bigint;
  v_season text;
  v_day_type text;
  v_override text;
begin
  perform public._require_admin(p_token);
  select id,season_type into v_version_id,v_season
  from public.route_timetable_versions
  where active and effective_from<=p_service_date
    and (effective_to is null or effective_to>=p_service_date)
  order by effective_from desc,
           case season_type when 'SPECIAL' then 0 when 'VACATION' then 1 else 2 end,
           imported_at desc
  limit 1;

  select day_type into v_override from public.service_calendar_overrides where service_date=p_service_date;
  v_day_type := coalesce(v_override,case
    when v_season='SPECIAL' then 'HOLIDAY'
    when extract(dow from p_service_date)=6 then 'SATURDAY'
    when extract(dow from p_service_date)=0 then 'HOLIDAY'
    else 'WEEKDAY'
  end);

  return jsonb_build_object(
    'service_date',p_service_date,
    'day_type',v_day_type,
    'day_type_source',case when v_override is null then 'AUTO' else 'OVERRIDE' end,
    'timetable_version_id',v_version_id,
    'dispatch',coalesce((select jsonb_agg(to_jsonb(d) order by d.route_no,d.run_order,d.shift_type)
      from public.dispatch_assignments d where d.service_date=p_service_date),'[]'::jsonb),
    'bindings',coalesce((select jsonb_agg(to_jsonb(b) order by b.valid_from_at)
      from public.trip_vehicle_bindings b where b.service_date=p_service_date),'[]'::jsonb),
    'timetable',coalesce((select jsonb_agg(jsonb_build_object(
      'route_no',s.route_no,'run_order',s.run_order,'day_type',s.day_type,
      'direction_name',s.direction_name,'departure_time',to_char(s.departure_time,'HH24:MI:SS')
    ) order by s.route_no,s.departure_time,s.run_order)
      from public.route_timetable_slots s
      where s.version_id=v_version_id and s.day_type=v_day_type),'[]'::jsonb)
  );
end $$;

create or replace function public.collector_ingest_vehicle_changes(p_token text,p_changes jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_admin uuid;
  r jsonb;
  v_driver uuid;
  v_count int:=0;
  v_from timestamptz;
  v_to timestamptz;
begin
  v_admin:=public._require_admin(p_token);
  for r in select * from jsonb_array_elements(coalesce(p_changes,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(r->>'driver_name',''));
    v_from:=coalesce(nullif(r->>'effective_from_at','')::timestamptz,(r->>'detected_at')::timestamptz);
    v_to:=nullif(r->>'valid_to_at','')::timestamptz;

    insert into public.vehicle_change_events(
      change_key,service_date,route_no,run_order,driver_name,driver_user_id,
      old_vehicle,new_vehicle,planned_vehicle,actual_vehicle,change_type,effective_from_at,valid_to_at,
      detected_at,node_order,latitude,longitude,confidence,source,raw,collector_agent_id,confirmed_polls
    ) values(
      r->>'change_key',(r->>'service_date')::date,coalesce(r->>'route_no',''),
      coalesce(nullif(r->>'run_order','')::int,-1),r->>'driver_name',v_driver,
      r->>'old_vehicle',r->>'new_vehicle',coalesce(r->>'planned_vehicle',r->>'old_vehicle'),
      coalesce(r->>'actual_vehicle',r->>'new_vehicle'),coalesce(r->>'change_type','MID_ROUTE'),
      v_from,v_to,(r->>'detected_at')::timestamptz,
      nullif(r->>'node_order','')::int,nullif(r->>'latitude','')::double precision,
      nullif(r->>'longitude','')::double precision,coalesce(r->>'confidence','medium'),
      coalesce(r->>'source','TAGO'),coalesce(r->'raw','{}'::jsonb),
      nullif(r->>'collector_agent_id',''),coalesce(nullif(r->>'confirmed_polls','')::int,0)
    ) on conflict(change_key) do update set
      confidence=excluded.confidence,raw=excluded.raw,valid_to_at=excluded.valid_to_at,
      confirmed_polls=greatest(public.vehicle_change_events.confirmed_polls,excluded.confirmed_polls),
      collector_agent_id=coalesce(excluded.collector_agent_id,public.vehicle_change_events.collector_agent_id);

    update public.trip_vehicle_bindings set valid_to_at=v_from,updated_at=now()
    where service_date=(r->>'service_date')::date
      and route_no=coalesce(r->>'route_no','')
      and run_order=coalesce(nullif(r->>'run_order','')::int,-1)
      and valid_to_at is null
      and actual_vehicle<>coalesce(r->>'actual_vehicle',r->>'new_vehicle');

    insert into public.trip_vehicle_bindings(
      binding_key,service_date,route_no,run_order,driver_name,driver_user_id,
      planned_vehicle,actual_vehicle,valid_from_at,valid_to_at,binding_type,confidence,source
    ) values(
      r->>'change_key',(r->>'service_date')::date,coalesce(r->>'route_no',''),
      coalesce(nullif(r->>'run_order','')::int,-1),r->>'driver_name',v_driver,
      coalesce(r->>'planned_vehicle',r->>'old_vehicle'),coalesce(r->>'actual_vehicle',r->>'new_vehicle'),
      v_from,v_to,coalesce(r->>'change_type','BIS_CONFIRMED'),coalesce(r->>'confidence','medium'),
      coalesce(r->>'source','TAGO')
    ) on conflict(binding_key) do update set
      actual_vehicle=excluded.actual_vehicle,valid_from_at=excluded.valid_from_at,
      valid_to_at=excluded.valid_to_at,confidence=excluded.confidence,
      driver_name=excluded.driver_name,driver_user_id=excluded.driver_user_id,updated_at=now();
    v_count:=v_count+1;
  end loop;
  if v_count>0 then perform public._audit(v_admin,'INGEST_BIS_BINDING','trip_vehicle_binding',null,jsonb_build_object('rows',v_count)); end if;
  return jsonb_build_object('ok',true,'inserted',v_count);
end $$;

create or replace function public.collector_ingest_taco(p_token text,p_import jsonb,p_events jsonb,p_summaries jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_admin uuid;
  v_import_id bigint;
  r jsonb;
  s jsonb;
  v_driver uuid;
  v_pub_id bigint;
  v_pub_summary jsonb;
  v_event_count int:=0;
  v_sum_count int:=0;
begin
  v_admin:=public._require_admin(p_token);
  insert into public.taco_imports(
    source_file,source_path,sha256,service_date,vehicle_no,first_record_at,last_record_at,
    record_count,parser_version,collector_agent_id,collected_at,delay_days,match_status,
    matched_seconds,unmatched_seconds,local_archive_ref,summary_only
  ) values(
    p_import->>'source_file',null,p_import->>'sha256',nullif(p_import->>'service_date','')::date,
    p_import->>'vehicle_no',nullif(p_import->>'first_record_at','')::timestamptz,
    nullif(p_import->>'last_record_at','')::timestamptz,coalesce(nullif(p_import->>'record_count','')::int,0),
    p_import->>'parser_version',nullif(p_import->>'collector_agent_id',''),
    coalesce(nullif(p_import->>'collected_at','')::timestamptz,now()),
    coalesce(nullif(p_import->>'delay_days','')::int,0),coalesce(p_import->>'match_status','pending'),
    coalesce(nullif(p_import->>'matched_seconds','')::int,0),coalesce(nullif(p_import->>'unmatched_seconds','')::int,0),
    p_import->>'local_archive_ref',true
  ) on conflict(sha256) do update set
    source_file=excluded.source_file,service_date=excluded.service_date,vehicle_no=excluded.vehicle_no,
    first_record_at=excluded.first_record_at,last_record_at=excluded.last_record_at,
    record_count=excluded.record_count,parser_version=excluded.parser_version,
    collector_agent_id=coalesce(excluded.collector_agent_id,public.taco_imports.collector_agent_id),
    collected_at=excluded.collected_at,delay_days=excluded.delay_days,match_status=excluded.match_status,
    matched_seconds=excluded.matched_seconds,unmatched_seconds=excluded.unmatched_seconds,
    local_archive_ref=excluded.local_archive_ref,summary_only=true,imported_at=now()
  returning id into v_import_id;

  delete from public.taco_events where import_id=v_import_id;
  delete from public.taco_driver_daily where source_import_id=v_import_id;

  for r in select * from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(r->>'driver_name',''));
    if v_driver is null then continue; end if;
    insert into public.taco_events(
      import_id,event_key,service_date,vehicle_no,driver_name,driver_user_id,route_no,run_order,
      recorded_at,event_type,severity,speed_before,speed_after,brake_on,latitude,longitude,evidence,criteria_version
    ) values(
      v_import_id,r->>'event_key',nullif(r->>'service_date','')::date,r->>'vehicle_no',r->>'driver_name',v_driver,
      coalesce(r->>'route_no',''),coalesce(nullif(r->>'run_order','')::int,-1),(r->>'recorded_at')::timestamptz,
      r->>'event_type',coalesce(r->>'severity','candidate'),nullif(r->>'speed_before','')::numeric,
      nullif(r->>'speed_after','')::numeric,nullif(r->>'brake_on','')::boolean,
      nullif(r->>'latitude','')::double precision,nullif(r->>'longitude','')::double precision,
      coalesce(r->'evidence','{}'::jsonb),coalesce(r->>'criteria_version','SAFEDRIVE-CANDIDATE-v2')
    ) on conflict(event_key) do nothing;
    if found then v_event_count:=v_event_count+1; end if;
  end loop;

  for s in select * from jsonb_array_elements(coalesce(p_summaries,'[]'::jsonb)) loop
    select id into v_driver from public.app_users where login_id=trim(coalesce(s->>'driver_name',''));
    if v_driver is null or coalesce(s->>'driver_name','')='' then continue; end if;
    insert into public.taco_driver_daily(
      source_import_id,service_date,driver_name,driver_user_id,vehicle_no,route_no,run_order,
      distance_km,max_speed,rapid_start,rapid_accel,rapid_decel,rapid_stop,speed_watch,
      valid_pair_count,gap_seconds,data_quality,match_status,matched_seconds,unmatched_seconds,late_days,
      safety_score,safety_level,event_rates,event_samples,analysis_text,recommendations
    ) values(
      v_import_id,(s->>'service_date')::date,s->>'driver_name',v_driver,coalesce(s->>'vehicle_no',''),
      coalesce(s->>'route_no',''),coalesce(nullif(s->>'run_order','')::int,-1),
      coalesce(nullif(s->>'distance_km','')::numeric,0),coalesce(nullif(s->>'max_speed','')::numeric,0),
      coalesce(nullif(s->>'rapid_start','')::int,0),coalesce(nullif(s->>'rapid_accel','')::int,0),
      coalesce(nullif(s->>'rapid_decel','')::int,0),coalesce(nullif(s->>'rapid_stop','')::int,0),
      coalesce(nullif(s->>'speed_watch','')::int,0),coalesce(nullif(s->>'valid_pair_count','')::int,0),
      coalesce(nullif(s->>'gap_seconds','')::int,0),coalesce(s->>'data_quality','unknown'),
      coalesce(s->>'match_status','matched'),coalesce(nullif(s->>'matched_seconds','')::int,0),
      coalesce(nullif(s->>'unmatched_seconds','')::int,0),coalesce(nullif(s->>'late_days','')::int,0),
      nullif(s->>'safety_score','')::numeric,s->>'safety_level',coalesce(s->'event_rates','{}'::jsonb),
      coalesce(s->'event_samples','{}'::jsonb),s->>'analysis_text',coalesce(s->'recommendations','[]'::jsonb)
    ) on conflict(service_date,driver_name,vehicle_no,route_no) do update set
      source_import_id=excluded.source_import_id,run_order=excluded.run_order,distance_km=excluded.distance_km,
      max_speed=excluded.max_speed,rapid_start=excluded.rapid_start,rapid_accel=excluded.rapid_accel,
      rapid_decel=excluded.rapid_decel,rapid_stop=excluded.rapid_stop,speed_watch=excluded.speed_watch,
      valid_pair_count=excluded.valid_pair_count,gap_seconds=excluded.gap_seconds,data_quality=excluded.data_quality,
      match_status=excluded.match_status,matched_seconds=excluded.matched_seconds,
      unmatched_seconds=excluded.unmatched_seconds,late_days=excluded.late_days,
      safety_score=excluded.safety_score,safety_level=excluded.safety_level,event_rates=excluded.event_rates,
      event_samples=excluded.event_samples,analysis_text=excluded.analysis_text,
      recommendations=excluded.recommendations,updated_at=now(),driver_user_id=excluded.driver_user_id;
    v_sum_count:=v_sum_count+1;

    select jsonb_build_object(
      'service_date',(s->>'service_date')::date,'driver_name',s->>'driver_name',
      'distance_km',round(coalesce(sum(distance_km),0)::numeric,3),
      'max_speed',coalesce(max(max_speed),0),'safety_score',round(coalesce(avg(safety_score),0)::numeric,1),
      'safety_level',case when avg(safety_score)>=95 then '매우양호' when avg(safety_score)>=90 then '양호'
                          when avg(safety_score)>=80 then '주의' else '개선필요' end,
      'rapid_start',coalesce(sum(rapid_start),0),'rapid_accel',coalesce(sum(rapid_accel),0),
      'rapid_decel',coalesce(sum(rapid_decel),0),'rapid_stop',coalesce(sum(rapid_stop),0),
      'speed_watch',coalesce(sum(speed_watch),0),
      'vehicles',to_jsonb(array_remove(array_agg(distinct nullif(vehicle_no,'')),null)),
      'routes',to_jsonb(array_remove(array_agg(distinct nullif(route_no,'')),null)),
      'analysis_text',max(analysis_text),'recommendations',coalesce((
        select jsonb_agg(distinct e.value)
        from public.taco_driver_daily rd
        cross join lateral jsonb_array_elements_text(rd.recommendations) e(value)
        where rd.service_date=(s->>'service_date')::date and rd.driver_name=s->>'driver_name'
      ),'[]'::jsonb),
      'data_quality',case when bool_or(data_quality='limited') then 'limited'
                          when bool_or(data_quality='review') then 'review' else 'good' end,
      'match_status',case when bool_or(match_status='partial') then 'partial' else 'matched' end,
      'late_days',coalesce(max(late_days),0)
    ) into v_pub_summary
    from public.taco_driver_daily
    where service_date=(s->>'service_date')::date and driver_name=s->>'driver_name';

    insert into public.driver_publications(
      driver_user_id,driver_name,period_start,period_end,title,source,summary,published_at
    ) values(
      v_driver,s->>'driver_name',(s->>'service_date')::date,(s->>'service_date')::date,
      (s->>'service_date')||' SafeDrive 운행분석','SAFEDRIVE',v_pub_summary,now()
    ) on conflict(driver_user_id,period_start,period_end,source) do update set
      summary=excluded.summary,published_at=now(),title=excluded.title
    returning id into v_pub_id;
    delete from public.driver_acknowledgements where publication_id=v_pub_id;
  end loop;

  perform public._audit(v_admin,'INGEST_TACO_SUMMARY','taco_import',v_import_id::text,
    jsonb_build_object('event_samples',v_event_count,'summaries',v_sum_count,'file',p_import->>'source_file',
      'match_status',p_import->>'match_status','delay_days',p_import->>'delay_days'));
  return jsonb_build_object('ok',true,'import_id',v_import_id,'event_samples',v_event_count,
    'summaries',v_sum_count,'match_status',p_import->>'match_status');
end $$;

create or replace function public.collector_cleanup_minimal_storage(
  p_token text,p_event_days int default 90,p_activity_days int default 30,p_audit_days int default 180
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_events int; v_activity int; v_audit int;
begin
  v_admin:=public._require_admin(p_token);
  delete from public.taco_events where recorded_at < now()-(greatest(p_event_days,30)||' days')::interval;
  get diagnostics v_events=row_count;
  delete from public.collector_activity_logs where created_at < now()-(greatest(p_activity_days,7)||' days')::interval;
  get diagnostics v_activity=row_count;
  delete from public.audit_logs where created_at < now()-(greatest(p_audit_days,30)||' days')::interval;
  get diagnostics v_audit=row_count;
  return jsonb_build_object('ok',true,'deleted_event_samples',v_events,'deleted_activity',v_activity,'deleted_audit',v_audit);
end $$;

create or replace function public.admin_driver_reports(
  p_token text,p_driver_name text default null,p_from date default null,p_to date default null,p_limit int default 500
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'drivers',coalesce((select jsonb_agg(x) from (
      select id,login_id,display_name,last_login_at,active from public.app_users
      where role='driver' order by display_name
    ) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (
      select d.*,p.id publication_id,a.acknowledged_at
      from public.taco_driver_daily d
      left join public.driver_publications p on p.driver_user_id=d.driver_user_id and p.source='SAFEDRIVE'
        and p.period_start=d.service_date and p.period_end=d.service_date
      left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=d.driver_user_id
      where (p_driver_name is null or p_driver_name='' or d.driver_name=p_driver_name)
        and (p_from is null or d.service_date>=p_from) and (p_to is null or d.service_date<=p_to)
      order by d.service_date desc,d.driver_name limit p_limit
    ) x),'[]'::jsonb),
    'monthly',coalesce((select jsonb_agg(x) from (
      select driver_name,to_char(date_trunc('month',service_date),'YYYY-MM') analysis_month,
        count(distinct service_date)::int days_count,round(sum(distance_km)::numeric,1) distance_km,
        round(avg(safety_score)::numeric,1) avg_score,sum(rapid_start)::int rapid_start,
        sum(rapid_accel)::int rapid_accel,sum(rapid_decel)::int rapid_decel,
        sum(rapid_stop)::int rapid_stop,sum(speed_watch)::int speed_watch
      from public.taco_driver_daily
      where (p_driver_name is null or p_driver_name='' or driver_name=p_driver_name)
        and (p_from is null or service_date>=p_from) and (p_to is null or service_date<=p_to)
      group by driver_name,date_trunc('month',service_date)
      order by date_trunc('month',service_date) desc,driver_name limit p_limit
    ) x),'[]'::jsonb),
    'pending',coalesce((select jsonb_agg(x) from (
      select id,source_file,service_date,vehicle_no,collected_at,delay_days,match_status,
             matched_seconds,unmatched_seconds,record_count
      from public.taco_imports where match_status in ('pending','partial')
      order by imported_at desc limit 100
    ) x),'[]'::jsonb)
  );
end $$;

create or replace function public.driver_dashboard(p_token text,p_limit int default 30)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid; v_name text;
begin
  v_uid:=public._session_user_id(p_token); if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  select display_name into v_name from public.app_users where id=v_uid;
  return jsonb_build_object(
    'user',(select jsonb_build_object('display_name',display_name,'login_id',login_id,'must_change_password',must_change_password) from public.app_users where id=v_uid),
    'publications',coalesce((select jsonb_agg(x) from (
      select p.id,p.period_start,p.period_end,p.title,p.source,p.summary,p.published_at,
             (a.acknowledged_at is not null) acknowledged,a.acknowledged_at
      from public.driver_publications p left join public.driver_acknowledgements a
        on a.publication_id=p.id and a.user_id=v_uid
      where p.driver_user_id=v_uid and p.source='SAFEDRIVE'
      order by p.published_at desc limit p_limit
    ) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (
      select * from public.taco_driver_daily where driver_user_id=v_uid
      order by service_date desc limit p_limit
    ) x),'[]'::jsonb),
    'dispatch',coalesce((select jsonb_agg(x) from (
      select service_date,vehicle_no,shift_type,shift_start,shift_end,route_no,run_order
      from public.dispatch_assignments where driver_user_id=v_uid
      order by service_date desc,shift_start desc limit 60
    ) x),'[]'::jsonb),
    'vehicle_changes',coalesce((select jsonb_agg(x) from (
      select service_date,route_no,run_order,old_vehicle,new_vehicle,change_type,effective_from_at,
             detected_at,confidence from public.vehicle_change_events
      where driver_user_id=v_uid or driver_name=v_name order by detected_at desc limit 60
    ) x),'[]'::jsonb)
  );
end $$;

create or replace function public.admin_collector_status(p_token text,p_limit int default 100)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'server_time',now(),
    'agents',coalesce((select jsonb_agg(x order by x.last_heartbeat_at desc) from (
      select a.*,case when a.last_heartbeat_at>now()-interval '2 minutes' and a.status='running' then true else false end online
      from public.collector_agents a
    ) x),'[]'::jsonb),
    'activities',coalesce((select jsonb_agg(x) from (
      select * from public.collector_activity_logs order by created_at desc limit p_limit
    ) x),'[]'::jsonb),
    'commands',coalesce((select jsonb_agg(x) from (
      select c.id,c.agent_id,c.command,c.status,c.requested_at,c.delivered_at,c.completed_at,c.result,
             u.display_name requested_by_name
      from public.collector_commands c left join public.app_users u on u.id=c.requested_by
      order by c.requested_at desc limit 30
    ) x),'[]'::jsonb),
    'taco_recent',coalesce((select jsonb_agg(x) from (
      select id,source_file,service_date,vehicle_no,record_count,parser_version,collector_agent_id,
             imported_at,collected_at,delay_days,match_status,matched_seconds,unmatched_seconds
      from public.taco_imports order by imported_at desc limit 50
    ) x),'[]'::jsonb),
    'bis_recent',coalesce((select jsonb_agg(x) from (
      select id,service_date,route_no,run_order,driver_name,old_vehicle,new_vehicle,change_type,
             effective_from_at,detected_at,confidence,collector_agent_id,confirmed_polls
      from public.vehicle_change_events order by detected_at desc limit 50
    ) x),'[]'::jsonb),
    'dispatch_recent',coalesce((select jsonb_agg(x) from (
      select service_date,count(*) rows,max(imported_at) imported_at
      from public.dispatch_assignments group by service_date order by service_date desc limit 30
    ) x),'[]'::jsonb)
  );
end $$;

create or replace function public.admin_dashboard(p_token text,p_service_date date default current_date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'counts',jsonb_build_object(
      'drivers',(select count(*) from public.app_users where role='driver' and active),
      'dispatch',(select count(*) from public.dispatch_assignments where service_date=p_service_date),
      'vehicle_changes',(select count(*) from public.vehicle_change_events where service_date=p_service_date),
      'taco_imports',(select count(*) from public.taco_imports where service_date=p_service_date),
      'pending_taco',(select count(*) from public.taco_imports where match_status in ('pending','partial')),
      'unacknowledged',(select count(*) from public.driver_publications p left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=p.driver_user_id where p.source='SAFEDRIVE' and a.publication_id is null)
    ),
    'changes',coalesce((select jsonb_agg(x) from (
      select * from public.vehicle_change_events where service_date=p_service_date order by detected_at desc limit 50
    ) x),'[]'::jsonb),
    'taco_daily',coalesce((select jsonb_agg(x) from (
      select * from public.taco_driver_daily where service_date=p_service_date order by safety_score asc nulls last limit 100
    ) x),'[]'::jsonb),
    'recent_imports',coalesce((select jsonb_agg(x) from (
      select * from public.taco_imports order by imported_at desc limit 30
    ) x),'[]'::jsonb)
  );
end $$;

-- v1.2.0 no longer imports eTAS Excel. Legacy tables are retained only to avoid destructive data loss.
drop function if exists public.admin_import_etas(text,jsonb);

revoke execute on function public.admin_import_timetable(text,jsonb,jsonb) from public;
revoke execute on function public.admin_list_timetable_versions(text,int) from public;
revoke execute on function public.admin_upsert_service_calendar(text,date,text,text) from public;
revoke execute on function public.admin_list_service_calendar(text,date,date) from public;
revoke execute on function public.collector_get_context(text,date) from public;
revoke execute on function public.collector_cleanup_minimal_storage(text,int,int,int) from public;
revoke execute on function public.admin_driver_reports(text,text,date,date,int) from public;

grant execute on function public.admin_import_timetable(text,jsonb,jsonb) to anon,authenticated;
grant execute on function public.admin_list_timetable_versions(text,int) to anon,authenticated;
grant execute on function public.admin_upsert_service_calendar(text,date,text,text) to anon,authenticated;
grant execute on function public.admin_list_service_calendar(text,date,date) to anon,authenticated;
grant execute on function public.collector_get_context(text,date) to anon,authenticated;
grant execute on function public.collector_cleanup_minimal_storage(text,int,int,int) to anon,authenticated;
grant execute on function public.admin_driver_reports(text,text,date,date,int) to anon,authenticated;

commit;
-- Daewoon SafeDrive AI v1.3.0
-- 1) Collector command RPC PostgreSQL CTE error repair
-- 2) driver/admin login count and estimated usage-time tracking
-- 3) data-linkage inspection by service date
-- 4) monthly driver analysis from 2026-10-01
-- Existing dispatch, CDT, BIS, users and analysis rows are preserved.

begin;

create table if not exists public.app_login_history (
  id bigint generated always as identity primary key,
  session_token uuid not null unique,
  user_id uuid not null references public.app_users(id) on delete cascade,
  login_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  logout_at timestamptz,
  active_seconds integer not null default 0,
  client_info jsonb not null default '{}'::jsonb
);
create index if not exists ix_login_history_user_date
  on public.app_login_history(user_id,login_at desc);
create index if not exists ix_login_history_last_seen
  on public.app_login_history(last_seen_at desc);
alter table public.app_login_history enable row level security;

create or replace function public.app_login(p_login_id text,p_password text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_u public.app_users; v_token uuid;
begin
  select * into v_u from public.app_users where login_id=trim(p_login_id) and active=true;
  if v_u.id is null or extensions.crypt(p_password,v_u.password_hash)<>v_u.password_hash then
    raise exception '아이디 또는 비밀번호가 올바르지 않습니다.';
  end if;
  delete from public.app_sessions where expires_at<=now();
  insert into public.app_sessions(user_id) values(v_u.id) returning token into v_token;
  insert into public.app_login_history(session_token,user_id)
  values(v_token,v_u.id)
  on conflict(session_token) do update set last_seen_at=now(),logout_at=null;
  update public.app_users set last_login_at=now() where id=v_u.id;
  perform public._audit(v_u.id,'LOGIN','app_user',v_u.id::text,jsonb_build_object('login_id',v_u.login_id));
  return jsonb_build_object(
    'token',v_token::text,'user_id',v_u.id,'login_id',v_u.login_id,
    'display_name',v_u.display_name,'role',v_u.role,
    'must_change_password',v_u.must_change_password,
    'expires_at',now()+interval '7 days'
  );
end $$;

create or replace function public.app_touch(p_token text,p_client_info jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid; v_seconds integer:=0;
begin
  v_uid:=public._session_user_id(p_token);
  if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;

  update public.app_login_history
  set active_seconds=active_seconds + least(
        90,
        greatest(0,extract(epoch from (now()-last_seen_at))::integer)
      ),
      last_seen_at=now(),
      client_info=coalesce(client_info,'{}'::jsonb)||coalesce(p_client_info,'{}'::jsonb)
  where session_token::text=p_token and user_id=v_uid and logout_at is null
  returning active_seconds into v_seconds;

  if not found then
    insert into public.app_login_history(session_token,user_id,client_info)
    values(p_token::uuid,v_uid,coalesce(p_client_info,'{}'::jsonb))
    returning active_seconds into v_seconds;
  end if;
  return jsonb_build_object('ok',true,'active_seconds',coalesce(v_seconds,0),'server_time',now());
end $$;

create or replace function public.app_logout(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid;
begin
  v_uid:=public._session_user_id(p_token);
  if v_uid is not null then
    update public.app_login_history
    set active_seconds=active_seconds + least(
          90,
          greatest(0,extract(epoch from (now()-last_seen_at))::integer)
        ),
        last_seen_at=now(),logout_at=now()
    where session_token::text=p_token and user_id=v_uid and logout_at is null;
  end if;
  delete from public.app_sessions where token::text=p_token;
  if v_uid is not null then perform public._audit(v_uid,'LOGOUT','app_user',v_uid::text); end if;
  return jsonb_build_object('ok',true);
end $$;

-- Data-modifying CTE must be attached to the top-level SQL statement.
-- The previous nested RETURN COALESCE((WITH ... UPDATE ...)) form caused:
-- "WITH clause containing a data-modifying statement must be at the top level".
create or replace function public.collector_fetch_commands(p_token text,p_agent_id text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_result jsonb;
begin
  perform public._require_admin(p_token);
  with picked as (
    select id from public.collector_commands
    where agent_id=p_agent_id and status='pending'
    order by requested_at
    limit 10
    for update skip locked
  ), delivered as (
    update public.collector_commands c
    set status='delivered',delivered_at=now()
    from picked p
    where c.id=p.id
    returning c.id,c.command,c.requested_at
  )
  select coalesce(jsonb_agg(to_jsonb(delivered)),'[]'::jsonb)
  into v_result
  from delivered;
  return coalesce(v_result,'[]'::jsonb);
end $$;

create or replace function public.admin_list_users(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(x order by x.role,x.display_name) from (
    select u.id,u.login_id,u.display_name,u.role,u.must_change_password,u.active,
           u.last_login_at,u.created_at,
           coalesce(s.login_count,0)::int login_count,
           coalesce(s.active_seconds,0)::bigint active_seconds,
           s.last_seen_at,
           coalesce(s.online,false) online
    from public.app_users u
    left join lateral (
      select count(*)::int login_count,
             coalesce(sum(h.active_seconds),0)::bigint active_seconds,
             max(h.last_seen_at) last_seen_at,
             bool_or(h.logout_at is null and h.last_seen_at>now()-interval '2 minutes') online
      from public.app_login_history h
      where h.user_id=u.id and h.login_at>=date '2026-10-01'
    ) s on true
  ) x),'[]'::jsonb);
end $$;

create or replace function public.admin_driver_reports(
  p_token text,p_driver_name text default null,p_from date default null,p_to date default null,p_limit int default 500
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_from date:=greatest(coalesce(p_from,date '2026-10-01'),date '2026-10-01');
        v_to date:=coalesce(p_to,current_date);
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'analysis_start_date',date '2026-10-01',
    'from_date',v_from,'to_date',v_to,
    'drivers',coalesce((select jsonb_agg(x) from (
      select id,login_id,display_name,last_login_at,active from public.app_users
      where role='driver' order by display_name
    ) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (
      select d.*,p.id publication_id,a.acknowledged_at
      from public.taco_driver_daily d
      left join public.driver_publications p on p.driver_user_id=d.driver_user_id and p.source='SAFEDRIVE'
        and p.period_start=d.service_date and p.period_end=d.service_date
      left join public.driver_acknowledgements a on a.publication_id=p.id and a.user_id=d.driver_user_id
      where (p_driver_name is null or p_driver_name='' or d.driver_name=p_driver_name)
        and d.service_date between v_from and v_to
      order by d.service_date desc,d.driver_name limit p_limit
    ) x),'[]'::jsonb),
    'monthly',coalesce((select jsonb_agg(x) from (
      select driver_name,to_char(date_trunc('month',service_date),'YYYY-MM') analysis_month,
        count(distinct service_date)::int days_count,round(sum(distance_km)::numeric,1) distance_km,
        round(avg(safety_score)::numeric,1) avg_score,sum(rapid_start)::int rapid_start,
        sum(rapid_accel)::int rapid_accel,sum(rapid_decel)::int rapid_decel,
        sum(rapid_stop)::int rapid_stop,sum(speed_watch)::int speed_watch,
        round((sum(rapid_start+rapid_accel+rapid_decel+rapid_stop+speed_watch)
          /nullif(sum(distance_km),0)*100)::numeric,2) total_events_per_100km
      from public.taco_driver_daily
      where (p_driver_name is null or p_driver_name='' or driver_name=p_driver_name)
        and service_date between v_from and v_to
      group by driver_name,date_trunc('month',service_date)
      order by date_trunc('month',service_date) desc,driver_name limit p_limit
    ) x),'[]'::jsonb),
    'pending',coalesce((select jsonb_agg(x) from (
      select id,source_file,service_date,vehicle_no,collected_at,delay_days,match_status,
             matched_seconds,unmatched_seconds,record_count
      from public.taco_imports where match_status in ('pending','partial')
        and service_date between v_from and v_to
      order by imported_at desc limit 100
    ) x),'[]'::jsonb)
  );
end $$;

create or replace function public.driver_dashboard(p_token text,p_limit int default 30)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_uid uuid; v_name text;
begin
  v_uid:=public._session_user_id(p_token); if v_uid is null then raise exception '세션이 만료되었습니다.'; end if;
  select display_name into v_name from public.app_users where id=v_uid;
  return jsonb_build_object(
    'analysis_start_date',date '2026-10-01',
    'user',(select jsonb_build_object('display_name',display_name,'login_id',login_id,'must_change_password',must_change_password) from public.app_users where id=v_uid),
    'publications',coalesce((select jsonb_agg(x) from (
      select p.id,p.period_start,p.period_end,p.title,p.source,p.summary,p.published_at,
             (a.acknowledged_at is not null) acknowledged,a.acknowledged_at
      from public.driver_publications p left join public.driver_acknowledgements a
        on a.publication_id=p.id and a.user_id=v_uid
      where p.driver_user_id=v_uid and p.source='SAFEDRIVE' and p.period_start>=date '2026-10-01'
      order by p.published_at desc limit p_limit
    ) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (
      select * from public.taco_driver_daily where driver_user_id=v_uid and service_date>=date '2026-10-01'
      order by service_date desc limit p_limit
    ) x),'[]'::jsonb),
    'monthly',coalesce((select jsonb_agg(x) from (
      select to_char(date_trunc('month',service_date),'YYYY-MM') analysis_month,
        count(distinct service_date)::int days_count,round(sum(distance_km)::numeric,1) distance_km,
        round(avg(safety_score)::numeric,1) avg_score,sum(rapid_start)::int rapid_start,
        sum(rapid_accel)::int rapid_accel,sum(rapid_decel)::int rapid_decel,
        sum(rapid_stop)::int rapid_stop,sum(speed_watch)::int speed_watch,
        round((sum(rapid_start+rapid_accel+rapid_decel+rapid_stop+speed_watch)
          /nullif(sum(distance_km),0)*100)::numeric,2) total_events_per_100km
      from public.taco_driver_daily
      where driver_user_id=v_uid and service_date>=date '2026-10-01'
      group by date_trunc('month',service_date)
      order by date_trunc('month',service_date) desc limit 24
    ) x),'[]'::jsonb),
    'dispatch',coalesce((select jsonb_agg(x) from (
      select service_date,vehicle_no,shift_type,shift_start,shift_end,route_no,run_order
      from public.dispatch_assignments where driver_user_id=v_uid and service_date>=date '2026-10-01'
      order by service_date desc,shift_start desc limit 100
    ) x),'[]'::jsonb),
    'vehicle_changes',coalesce((select jsonb_agg(x) from (
      select service_date,route_no,run_order,old_vehicle,new_vehicle,change_type,effective_from_at,
             detected_at,confidence from public.vehicle_change_events
      where (driver_user_id=v_uid or driver_name=v_name) and service_date>=date '2026-10-01'
      order by detected_at desc limit 100
    ) x),'[]'::jsonb)
  );
end $$;

create or replace function public.admin_linkage_status(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_version_id bigint; v_season text; v_day_type text; v_override text;
begin
  perform public._require_admin(p_token);
  select id,season_type into v_version_id,v_season
  from public.route_timetable_versions
  where active and effective_from<=p_service_date
    and (effective_to is null or effective_to>=p_service_date)
  order by effective_from desc,
           case season_type when 'SPECIAL' then 0 when 'VACATION' then 1 else 2 end,
           imported_at desc
  limit 1;

  select day_type into v_override from public.service_calendar_overrides where service_date=p_service_date;
  v_day_type:=coalesce(v_override,case
    when v_season='SPECIAL' then 'HOLIDAY'
    when extract(dow from p_service_date)=6 then 'SATURDAY'
    when extract(dow from p_service_date)=0 then 'HOLIDAY'
    else 'WEEKDAY' end);

  return jsonb_build_object(
    'service_date',p_service_date,
    'day_type',v_day_type,
    'timetable_version_id',v_version_id,
    'timetable_version',(select jsonb_build_object('id',id,'version_name',version_name,'effective_from',effective_from,'effective_to',effective_to,'season_type',season_type,'source_file',source_file)
      from public.route_timetable_versions where id=v_version_id),
    'counts',jsonb_build_object(
      'dispatch',(select count(*) from public.dispatch_assignments where service_date=p_service_date),
      'timetable',(select count(*) from public.route_timetable_slots where version_id=v_version_id and day_type=v_day_type),
      'bindings',(select count(*) from public.trip_vehicle_bindings where service_date=p_service_date),
      'changes',(select count(*) from public.vehicle_change_events where service_date=p_service_date),
      'taco_imports',(select count(*) from public.taco_imports where service_date=p_service_date),
      'taco_matched',(select count(*) from public.taco_imports where service_date=p_service_date and match_status='matched'),
      'taco_pending',(select count(*) from public.taco_imports where service_date=p_service_date and match_status in ('pending','partial')),
      'driver_daily',(select count(*) from public.taco_driver_daily where service_date=p_service_date)
    ),
    'dispatch',coalesce((select jsonb_agg(x) from (
      select service_date,vehicle_no,driver_name,shift_type,shift_start,shift_end,route_no,run_order,source_file
      from public.dispatch_assignments where service_date=p_service_date
      order by route_no,run_order,shift_type,vehicle_no limit 200
    ) x),'[]'::jsonb),
    'bindings',coalesce((select jsonb_agg(x) from (
      select service_date,route_no,run_order,driver_name,planned_vehicle,actual_vehicle,
             valid_from_at,valid_to_at,binding_type,confidence
      from public.trip_vehicle_bindings where service_date=p_service_date
      order by route_no,run_order,valid_from_at limit 200
    ) x),'[]'::jsonb),
    'imports',coalesce((select jsonb_agg(x) from (
      select source_file,vehicle_no,service_date,collected_at,delay_days,match_status,
             matched_seconds,unmatched_seconds,record_count
      from public.taco_imports where service_date=p_service_date
      order by imported_at desc limit 100
    ) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (
      select driver_name,vehicle_no,route_no,run_order,distance_km,safety_score,safety_level,
             match_status,late_days,rapid_start,rapid_accel,rapid_decel,rapid_stop,speed_watch
      from public.taco_driver_daily where service_date=p_service_date
      order by driver_name,route_no,run_order limit 200
    ) x),'[]'::jsonb)
  );
end $$;

revoke execute on function public.app_touch(text,jsonb) from public;
revoke execute on function public.admin_linkage_status(text,date) from public;
grant execute on function public.app_touch(text,jsonb) to anon,authenticated;
grant execute on function public.admin_linkage_status(text,date) to anon,authenticated;

commit;
