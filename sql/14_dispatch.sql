-- v2.2.0 additive migration. Run ONLY this file, after sql/11, sql/12 and sql/13 were applied.
-- Adds two NEW tables (dp_days, dp_rows) and one NEW function (dp_api). Nothing existing is changed.
-- The tables are reachable only through dp_api (security definer) called by the Netlify gateway.
begin;

create table if not exists public.dp_days(
 service_date date primary key,
 row_count int not null default 0,
 source_files text,
 uploaded_by uuid,
 uploaded_at timestamptz not null default now()
);
create table if not exists public.dp_rows(
 service_date date not null references public.dp_days(service_date) on delete cascade,
 route text not null,
 seq int not null,
 car text not null,
 am_name text, am_time text,
 pm_name text, pm_time text,
 support_route text, support_seq text,
 ord int not null default 0,
 primary key(service_date,route,seq)
);
create index if not exists dp_rows_am_idx on public.dp_rows(service_date,am_name);
create index if not exists dp_rows_pm_idx on public.dp_rows(service_date,pm_name);
alter table public.dp_days enable row level security;
alter table public.dp_rows enable row level security;
revoke all on public.dp_days,public.dp_rows from public,anon,authenticated;

create or replace function public.dp_api(p_token text,p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid; adm boolean; r record; dt date; target uuid; me text; outv jsonb; days jsonb:='[]'::jsonb;
 existed boolean; n int; replaced int:=0; saved jsonb:='[]'::jsonb; item jsonb; items jsonb; d text;
begin
 uid:=public._session_user_id(p_token);
 if uid is null then raise exception '로그인이 만료되었거나 계정이 비활성 상태입니다.'; end if;
 select role='admin' into adm from public.app_users where id=uid;
 if exists(select 1 from public.app_users where id=uid and must_change_password) then raise exception '먼저 비밀번호를 변경하세요.'; end if;

 if p_action='upload' then
  if not adm then raise exception '관리자 권한 필요'; end if;
  if jsonb_typeof(p_data->'days')<>'array' or jsonb_array_length(p_data->'days') not between 1 and 14 then
   raise exception '한 번에 1~14일치만 저장할 수 있습니다.'; end if;
  for r in select value as v from jsonb_array_elements(p_data->'days') loop
   dt:=(r.v->>'date')::date;
   if dt<date '2020-01-01' or dt>current_date+400 then raise exception '날짜 범위를 확인하세요: %',dt; end if;
   if jsonb_typeof(r.v->'rows')<>'array' or jsonb_array_length(r.v->'rows') not between 1 and 400 then
    raise exception '% 배차 줄 수는 1~400이어야 합니다.',dt; end if;
   if exists(
    select 1 from jsonb_to_recordset(r.v->'rows') as x(route text,seq int,car text,am_name text,am_time text,pm_name text,pm_time text,support_route text,support_seq text,ord int)
    where coalesce(trim(route),'')='' or length(route)>12 or seq is null or seq<1 or seq>999
       or coalesce(trim(car),'')='' or length(car)>20
       or length(coalesce(am_name,''))>30 or length(coalesce(pm_name,''))>30
       or length(coalesce(support_route,''))>12 or length(coalesce(support_seq,''))>12
       or (am_time is not null and am_time!~'^([01][0-9]|2[0-3])[0-5][0-9]$')
       or (pm_time is not null and pm_time!~'^([01][0-9]|2[0-3])[0-5][0-9]$')
   ) then raise exception '% 자료에 형식이 올바르지 않은 줄이 있습니다.',dt; end if;
   existed:=exists(select 1 from public.dp_days where service_date=dt);
   delete from public.dp_rows where service_date=dt;
   insert into public.dp_days(service_date,row_count,source_files,uploaded_by,uploaded_at)
    values(dt,jsonb_array_length(r.v->'rows'),left(coalesce(r.v->>'source',''),500),uid,now())
    on conflict (service_date) do update set row_count=excluded.row_count,source_files=excluded.source_files,uploaded_by=excluded.uploaded_by,uploaded_at=excluded.uploaded_at;
   insert into public.dp_rows(service_date,route,seq,car,am_name,am_time,pm_name,pm_time,support_route,support_seq,ord)
    select dt,trim(route),seq,trim(car),
      normalize(nullif(trim(am_name),''),NFC),am_time,
      normalize(nullif(trim(pm_name),''),NFC),pm_time,
      nullif(trim(support_route),''),nullif(trim(support_seq),''),coalesce(ord,0)
    from jsonb_to_recordset(r.v->'rows') as x(route text,seq int,car text,am_name text,am_time text,pm_name text,pm_time text,support_route text,support_seq text,ord int);
   if existed then replaced:=replaced+1; end if;
   saved:=saved||jsonb_build_object('date',dt,'rows',jsonb_array_length(r.v->'rows'),'replaced',existed);
  end loop;
  perform public._audit(uid,'DP_UPLOAD','dispatch','days',jsonb_build_object('days',jsonb_array_length(saved),'replaced',replaced));
  return jsonb_build_object('saved',saved);

 elsif p_action='days' then
  select coalesce(jsonb_agg(jsonb_build_object('date',service_date,'rows',row_count,'uploaded_at',uploaded_at) order by service_date desc),'[]'::jsonb)
   into outv from (select * from public.dp_days where adm or service_date>=current_date-30 order by service_date desc limit 200) t;
  return outv;

 elsif p_action='day' then
  if not adm then raise exception '관리자 권한 필요'; end if;
  dt:=(p_data->>'date')::date;
  if not exists(select 1 from public.dp_days where service_date=dt) then return jsonb_build_object('registered',false); end if;
  select coalesce(jsonb_agg(jsonb_build_object('route',route,'seq',seq,'car',car,'am_name',am_name,'am_time',am_time,'pm_name',pm_name,'pm_time',pm_time,'support_route',support_route,'support_seq',support_seq) order by ord,route,seq),'[]'::jsonb)
   into items from public.dp_rows where service_date=dt;
  select coalesce(jsonb_agg(nm order by nm),'[]'::jsonb) into outv from (
   select normalize(coalesce(nullif(trim(p.etas_name),''),u.display_name),NFC) as nm
   from public.app_users u left join public.mr_profiles p on p.user_id=u.id
   where u.role='driver' and u.active and length(trim(coalesce(nullif(trim(p.etas_name),''),u.display_name,'')))>0
     and not exists(select 1 from public.dp_rows w where w.service_date=dt
        and normalize(coalesce(nullif(trim(p.etas_name),''),u.display_name),NFC) in (coalesce(w.am_name,''),coalesce(w.pm_name,'')))
  ) q;
  return jsonb_build_object('registered',true,'rows',items,'off',outv);

 elsif p_action='mine' then
  target:=uid;
  if adm and nullif(p_data->>'user_id','') is not null then target:=(p_data->>'user_id')::uuid; end if;
  select normalize(coalesce(nullif(trim(p.etas_name),''),u.display_name),NFC) into me
   from public.app_users u left join public.mr_profiles p on p.user_id=u.id where u.id=target;
  if me is null then raise exception '기사 정보를 찾을 수 없습니다.'; end if;
  if jsonb_typeof(p_data->'dates')<>'array' or jsonb_array_length(p_data->'dates') not between 1 and 7 then
   raise exception '날짜는 1~7개만 조회할 수 있습니다.'; end if;
  for d in select jsonb_array_elements_text(p_data->'dates') loop
   dt:=d::date;
   if not exists(select 1 from public.dp_days where service_date=dt) then
    days:=days||jsonb_build_object('date',dt,'status','unregistered'); continue;
   end if;
   select coalesce(jsonb_agg(x order by sh),'[]'::jsonb) into items from (
    select case when w.am_name=me then 'am' else 'pm' end as sh,
     jsonb_build_object('shift',case when w.am_name=me then 'am' else 'pm' end,'route',w.route,'seq',w.seq,'car',w.car,
      'am_name',w.am_name,'am_time',w.am_time,'pm_name',w.pm_name,'pm_time',w.pm_time,'support_route',w.support_route,'support_seq',w.support_seq,
      'route_rows',(select coalesce(jsonb_agg(jsonb_build_object('seq',z.seq,'car',z.car,'am_name',z.am_name,'am_time',z.am_time,'pm_name',z.pm_name,'pm_time',z.pm_time) order by z.seq),'[]'::jsonb)
                    from public.dp_rows z where z.service_date=dt and z.route=w.route)) as x
    from public.dp_rows w where w.service_date=dt and (w.am_name=me or w.pm_name=me)
   ) s;
   days:=days||jsonb_build_object('date',dt,'status',case when jsonb_array_length(items)>0 then 'work' else 'off' end,'items',items);
  end loop;
  return jsonb_build_object('name',me,'days',days);

 else raise exception '지원하지 않는 작업';
 end if;
end $$;
revoke all on function public.dp_api(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.dp_api(text,text,jsonb) to service_role;
commit;

-- 새 함수를 Supabase API가 바로 인식하도록 스키마 캐시를 새로고침합니다.
notify pgrst, 'reload schema';
