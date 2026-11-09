-- v2.0 additive migration. Run ONLY this file on existing v1.4.x database.
begin;
create table if not exists public.mr_profiles (
 user_id uuid primary key references public.app_users(id), etas_name text not null unique check(length(trim(etas_name)) between 1 and 100),
 employment text not null default '재직' check(employment in ('재직','휴직','퇴사')), effective_date date not null default current_date,
 updated_at timestamptz not null default now());
create table if not exists public.mr_reports (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.app_users(id),
 month date not null check(extract(day from month)=1), etas_name text not null,
 pdf_path text, excel_path text, pdf_hash text, excel_hash text, excel_ext text,
 verified boolean not null default false, published boolean not null default false,
 opened_at timestamptz, acknowledged_at timestamptz, revision integer not null default 1,
 updated_at timestamptz not null default now(), unique(user_id,month));
create table if not exists public.mr_messages (
 id bigint generated always as identity primary key, user_id uuid not null references public.app_users(id),
 report_id uuid references public.mr_reports(id), author_id uuid not null references public.app_users(id),
 body text not null check(length(trim(body)) between 1 and 5000), internal boolean not null default false,
 kind text not null default '피드백' check(kind in ('피드백','민원','사고','지도')),
 created_at timestamptz not null default now());
create index if not exists mr_messages_user on public.mr_messages(user_id,created_at);
alter table public.mr_profiles enable row level security;
alter table public.mr_reports enable row level security;
alter table public.mr_messages enable row level security;
revoke all on public.mr_profiles,public.mr_reports,public.mr_messages from public,anon,authenticated;
-- This function is callable only by the Netlify server, never the browser directly.
create or replace function public.mr_api(p_token text,p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid; adm boolean; target uuid; rid uuid; r public.mr_reports; result jsonb; nm text; st text; mo date;
begin
 uid:=public._session_user_id(p_token);
 if uid is null then raise exception '로그인이 만료되었거나 계정이 비활성 상태입니다.'; end if;
 select role='admin' into adm from public.app_users where id=uid;
 if exists(select 1 from public.app_users where id=uid and must_change_password) then raise exception '먼저 비밀번호를 변경하세요.'; end if;
 if p_action='list' then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.month desc,t.etas_name),'[]') into result from
   (select id,user_id,month,etas_name,pdf_path is not null as has_pdf,excel_path is not null as has_excel,
    verified,published,opened_at,acknowledged_at,revision,updated_at from public.mr_reports
    where adm or (user_id=uid and published)) t;
  return result;
 elsif p_action='users' then
  if not adm then raise exception '관리자 권한 필요'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by display_name),'[]') into result from
  (select u.id,u.login_id,u.display_name,u.active,p.etas_name,coalesce(p.employment,'재직') employment,p.effective_date
   from public.app_users u left join public.mr_profiles p on p.user_id=u.id where u.role='driver') t;
  return result;
 elsif p_action='user_save' then
  if not adm then raise exception '관리자 권한 필요'; end if;
  target:=nullif(p_data->>'id','')::uuid; nm:=trim(p_data->>'etas_name'); st:=p_data->>'employment';
  if nm is null or length(nm)<1 or length(nm)>100 or st not in ('재직','휴직','퇴사') then raise exception '기사명과 재직 상태를 확인하세요.'; end if;
  if target is null then
   if length(trim(coalesce(p_data->>'login_id','')))<1 or length(coalesce(p_data->>'password',''))<6 then raise exception '로그인 ID와 6자 이상 초기 비밀번호 필요'; end if;
   insert into public.app_users(login_id,display_name,password_hash,role,must_change_password)
   values(trim(p_data->>'login_id'),nm,extensions.crypt(p_data->>'password',extensions.gen_salt('bf',10)),'driver',true) returning id into target;
  end if;
  if not exists(select 1 from public.app_users where id=target and role='driver') then raise exception '기사 계정이 아닙니다.'; end if;
  update public.app_users set display_name=nm,active=coalesce((p_data->>'active')::boolean,true),updated_at=now() where id=target;
  if not coalesce((p_data->>'active')::boolean,true) then delete from public.app_sessions where user_id=target; end if;
  insert into public.mr_profiles(user_id,etas_name,employment,effective_date) values(target,nm,st,(p_data->>'effective_date')::date)
   on conflict(user_id) do update set etas_name=excluded.etas_name,employment=excluded.employment,effective_date=excluded.effective_date,updated_at=now();
  perform public._audit(uid,'MR_USER_SAVE','app_user',target::text,p_data-'password');
  return jsonb_build_object('id',target);
 elsif p_action='user_delete' then
  if not adm then raise exception '관리자 권한 필요'; end if;
  target:=(p_data->>'id')::uuid;
  update public.app_users set active=false,updated_at=now() where id=target and role='driver';
  if not found then raise exception '기사 계정을 찾을 수 없습니다.'; end if;
  delete from public.app_sessions where user_id=target;
  perform public._audit(uid,'MR_ACCOUNT_DISABLED','app_user',target::text);
  return jsonb_build_object('ok',true);
 elsif p_action='prepare' then
  if not adm then raise exception '관리자 권한 필요'; end if;
  target:=(p_data->>'user_id')::uuid; mo:=(p_data->>'month')::date;
  if mo>date_trunc('month',current_date)::date then raise exception '미래 월은 등록할 수 없습니다.'; end if;
  select etas_name into nm from public.mr_profiles where user_id=target;
  if nm is null then raise exception '먼저 공단 기사명 연결을 저장하세요.'; end if;
  insert into public.mr_reports(user_id,month,etas_name) values(target,mo,nm) on conflict(user_id,month) do nothing;
  select * into r from public.mr_reports where user_id=target and month=mo;
  return to_jsonb(r);
 elsif p_action in ('file_get','file_commit','verify','publish','unpublish','ack') then
  rid:=(p_data->>'id')::uuid;
  select * into r from public.mr_reports where id=rid for update;
  if r.id is null or (not adm and (r.user_id<>uid or not r.published)) then raise exception '접근할 수 없는 보고서입니다.'; end if;
  if p_action='file_get' then
   if not adm and p_data->>'kind'<>'pdf' then raise exception '엑셀은 관리자만 열 수 있습니다.'; end if;
   return jsonb_build_object('path',case when p_data->>'kind'='pdf' then r.pdf_path else r.excel_path end);
  elsif p_action='ack' then
   if adm then raise exception '기사 본인이 확인해야 합니다.'; end if;
   if (p_data->>'revision')::integer is distinct from r.revision then raise exception '자료가 교체되었습니다. 다시 열어 확인하세요.'; end if;
   if r.opened_at is null then raise exception '보고서를 먼저 여세요.'; end if;
   update public.mr_reports set acknowledged_at=coalesce(acknowledged_at,now()) where id=rid;
  else
   if not adm then raise exception '관리자 권한 필요'; end if;
   if p_action='file_commit' then
    if r.revision<>(p_data->>'revision')::int then raise exception '다른 작업에서 자료를 변경했습니다. 새로고침하세요.'; end if;
    if p_data->>'kind'='pdf' then
     if r.pdf_hash=p_data->>'hash' then return jsonb_build_object('duplicate',true); end if;
     update public.mr_reports set pdf_path=p_data->>'path',pdf_hash=p_data->>'hash' where id=rid;
    elsif p_data->>'kind'='excel' then
     if r.excel_hash=p_data->>'hash' then return jsonb_build_object('duplicate',true); end if;
     update public.mr_reports set excel_path=p_data->>'path',excel_hash=p_data->>'hash',excel_ext=p_data->>'ext' where id=rid;
    else raise exception '잘못된 파일 종류'; end if;
    update public.mr_reports set verified=false,published=false,opened_at=null,acknowledged_at=null,revision=revision+1,updated_at=now() where id=rid;
   elsif p_action='verify' then
    if r.pdf_path is null or r.excel_path is null then raise exception 'PDF와 엑셀을 모두 등록하세요.'; end if;
    if (p_data->>'revision')::int is distinct from r.revision then raise exception '자료가 변경되었습니다.'; end if;
    update public.mr_reports set verified=true where id=rid;
   elsif p_action='publish' then
    if not r.verified or r.pdf_path is null or r.excel_path is null then raise exception '검증 완료된 PDF·엑셀만 게시할 수 있습니다.'; end if;
    update public.mr_reports set published=true where id=rid;
   elsif p_action='unpublish' then update public.mr_reports set published=false where id=rid;
   end if;
  end if;
  perform public._audit(uid,'MR_'||upper(p_action),'mr_report',rid::text,jsonb_build_object('revision',r.revision,'previous_pdf',r.pdf_path,'previous_excel',r.excel_path));
  return jsonb_build_object('ok',true);
 elsif p_action='opened' then
  rid:=(p_data->>'id')::uuid;
  update public.mr_reports set opened_at=coalesce(opened_at,now()) where id=rid and user_id=uid and published and revision=(p_data->>'revision')::int;
  return jsonb_build_object('ok',true);
 elsif p_action in ('messages','message_add') then
  target:=case when adm then (p_data->>'user_id')::uuid else uid end;
  if p_action='message_add' then
   rid:=nullif(p_data->>'report_id','')::uuid;
   if rid is not null and not exists(select 1 from public.mr_reports where id=rid and user_id=target and (adm or published)) then raise exception '보고서 연결 오류'; end if;
   insert into public.mr_messages(user_id,report_id,author_id,body,internal,kind)
   values(target,rid,uid,trim(p_data->>'body'),adm and coalesce((p_data->>'internal')::boolean,false),case when adm then coalesce(p_data->>'kind','피드백') else '피드백' end);
   perform public._audit(uid,'MR_MESSAGE','app_user',target::text);
  end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by created_at),'[]') into result from
   (select m.*,u.display_name author_name from public.mr_messages m join public.app_users u on u.id=m.author_id
    where m.user_id=target and (adm or not m.internal)) t;
  return result;
 else raise exception '지원하지 않는 작업'; end if;
end $$;
revoke all on function public.mr_api(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.mr_api(text,text,jsonb) to service_role;
commit;
