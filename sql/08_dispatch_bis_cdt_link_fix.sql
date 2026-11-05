-- Daewoon SafeDrive AI v1.4.0
-- Safe additive update for existing Supabase projects.
-- Preserves all existing users, dispatch, timetable, BIS, CDT and analysis data.

begin;

create table if not exists public.daily_route_assignments (
  id bigint generated always as identity primary key,
  service_date date not null,
  vehicle_no text not null,
  shift_type text not null,
  route_no text not null,
  run_order integer not null,
  planned_departure timestamptz,
  source_file text,
  imported_at timestamptz not null default now(),
  unique(service_date, vehicle_no, shift_type)
);
create index if not exists ix_daily_route_date on public.daily_route_assignments(service_date,route_no,run_order);
alter table public.daily_route_assignments enable row level security;

-- Preserve existing useful route/order information as initial daily-plan rows.
insert into public.daily_route_assignments(service_date,vehicle_no,shift_type,route_no,run_order,planned_departure,source_file)
select service_date,vehicle_no,shift_type,route_no,run_order,shift_start,source_file
from public.dispatch_assignments
where coalesce(route_no,'')<>'' and run_order>0
on conflict(service_date,vehicle_no,shift_type) do nothing;

create or replace function public.admin_import_dispatch_bundle(
  p_token text,p_rows jsonb,p_source_file text
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_admin uuid;
  v_default_hash text;
  v_route_count int:=0;
  v_dispatch_count int:=0;
  v_driver_count int:=0;
  v_input_count int:=0;
begin
  v_admin:=public._require_admin(p_token);
  v_input_count:=jsonb_array_length(coalesce(p_rows,'[]'::jsonb));
  if v_input_count=0 then
    return jsonb_build_object('ok',true,'input_rows',0,'route_rows',0,'dispatch_rows',0,'new_drivers',0);
  end if;

  -- 1) Save date/vehicle/AM-PM -> route/order/departure independently of driver files.
  with src as (
    select
      nullif(trim(e.value->>'service_date'),'')::date service_date,
      trim(e.value->>'vehicle_no') vehicle_no,
      upper(coalesce(nullif(trim(e.value->>'shift_type'),''),'UNKNOWN')) shift_type,
      trim(coalesce(e.value->>'route_no','')) route_no,
      coalesce(nullif(trim(e.value->>'run_order'),'')::int,-1) run_order,
      case when coalesce(trim(e.value->>'shift_start'),'')='' then null else (e.value->>'shift_start')::timestamptz end planned_departure,
      coalesce(nullif(trim(e.value->>'source_file'),''),p_source_file) source_file,
      coalesce(nullif(trim(e.value->>'source_format'),''),'') source_format
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) e(value)
  )
  insert into public.daily_route_assignments(service_date,vehicle_no,shift_type,route_no,run_order,planned_departure,source_file)
  select service_date,vehicle_no,shift_type,route_no,run_order,planned_departure,source_file
  from src
  where service_date is not null and vehicle_no<>'' and route_no<>'' and run_order>0
    and (source_format='DAILY_ROUTE' or source_format='MERGED')
  on conflict(service_date,vehicle_no,shift_type) do update set
    route_no=excluded.route_no,
    run_order=excluded.run_order,
    planned_departure=coalesce(excluded.planned_departure,public.daily_route_assignments.planned_departure),
    source_file=excluded.source_file,
    imported_at=now();
  get diagnostics v_route_count=row_count;

  -- 2) Create driver accounts only from rows that actually contain a driver.
  v_default_hash:=extensions.crypt('1111',extensions.gen_salt('bf',10));
  with src as (
    select distinct trim(e.value->>'driver_name') driver_name
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) e(value)
    where coalesce(trim(e.value->>'driver_name'),'')<>''
  )
  insert into public.app_users(login_id,display_name,role,password_hash,must_change_password)
  select driver_name,driver_name,'driver',v_default_hash,true from src
  on conflict(login_id) do nothing;
  get diagnostics v_driver_count=row_count;

  -- 3) Save driver duty rows, enriching route/order from the persistent daily route plan.
  with src as (
    select
      nullif(trim(e.value->>'service_date'),'')::date service_date,
      trim(e.value->>'vehicle_no') vehicle_no,
      trim(e.value->>'driver_name') driver_name,
      upper(coalesce(nullif(trim(e.value->>'shift_type'),''),'UNKNOWN')) shift_type,
      case when coalesce(trim(e.value->>'shift_start'),'')='' then null else (e.value->>'shift_start')::timestamptz end shift_start,
      case when coalesce(trim(e.value->>'shift_end'),'')='' then null else (e.value->>'shift_end')::timestamptz end shift_end,
      trim(coalesce(e.value->>'route_no','')) route_no,
      coalesce(nullif(trim(e.value->>'run_order'),'')::int,-1) run_order,
      nullif(trim(coalesce(e.value->>'support_route_no','')),'') support_route_no,
      nullif(trim(e.value->>'support_run_order'),'')::int support_run_order,
      coalesce(nullif(trim(e.value->>'source_format'),''),'WORK_TIME') source_format,
      coalesce(nullif(trim(e.value->>'source_file'),''),p_source_file) source_file
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) e(value)
    where coalesce(trim(e.value->>'driver_name'),'')<>''
      and coalesce(trim(e.value->>'vehicle_no'),'')<>''
      and coalesce(trim(e.value->>'service_date'),'')<>''
  ), enriched as (
    select s.*,
      coalesce(nullif(s.route_no,''),p.route_no,'') final_route_no,
      case when s.run_order>0 then s.run_order else coalesce(p.run_order,-1) end final_run_order
    from src s
    left join public.daily_route_assignments p
      on p.service_date=s.service_date and p.vehicle_no=s.vehicle_no and p.shift_type=s.shift_type
  )
  insert into public.dispatch_assignments(
    service_date,vehicle_no,driver_name,driver_user_id,shift_type,
    shift_start,shift_end,route_no,run_order,support_route_no,support_run_order,
    source_file,source_format
  )
  select e.service_date,e.vehicle_no,e.driver_name,u.id,e.shift_type,e.shift_start,e.shift_end,
         e.final_route_no,e.final_run_order,e.support_route_no,e.support_run_order,e.source_file,e.source_format
  from enriched e join public.app_users u on u.login_id=e.driver_name
  on conflict(service_date,vehicle_no,driver_name,shift_type) do update set
    driver_user_id=excluded.driver_user_id,
    shift_start=coalesce(excluded.shift_start,public.dispatch_assignments.shift_start),
    shift_end=coalesce(excluded.shift_end,public.dispatch_assignments.shift_end),
    route_no=case when excluded.route_no<>'' then excluded.route_no else public.dispatch_assignments.route_no end,
    run_order=case when excluded.run_order>0 then excluded.run_order else public.dispatch_assignments.run_order end,
    support_route_no=coalesce(excluded.support_route_no,public.dispatch_assignments.support_route_no),
    support_run_order=coalesce(excluded.support_run_order,public.dispatch_assignments.support_run_order),
    source_file=case
      when coalesce(public.dispatch_assignments.source_file,'')='' then excluded.source_file
      when position(coalesce(excluded.source_file,'') in public.dispatch_assignments.source_file)>0 then public.dispatch_assignments.source_file
      else public.dispatch_assignments.source_file||' + '||coalesce(excluded.source_file,'') end,
    source_format=case when public.dispatch_assignments.source_format<>excluded.source_format then 'MERGED' else excluded.source_format end,
    imported_at=now();
  get diagnostics v_dispatch_count=row_count;

  -- 4) If the daily route file was uploaded later, enrich already-saved driver duty rows now.
  update public.dispatch_assignments d set
    route_no=p.route_no,
    run_order=p.run_order,
    source_format=case when d.source_format='DAILY_ROUTE' then d.source_format else 'MERGED' end,
    source_file=case
      when coalesce(d.source_file,'')='' then p.source_file
      when position(coalesce(p.source_file,'') in d.source_file)>0 then d.source_file
      else d.source_file||' + '||coalesce(p.source_file,'') end,
    imported_at=now()
  from public.daily_route_assignments p
  where d.service_date=p.service_date and d.vehicle_no=p.vehicle_no and d.shift_type=p.shift_type
    and (coalesce(d.route_no,'')='' or d.run_order<1 or d.route_no<>p.route_no or d.run_order<>p.run_order);

  perform public._audit(v_admin,'IMPORT_DISPATCH_BUNDLE','dispatch',p_source_file,
    jsonb_build_object('input_rows',v_input_count,'route_rows',v_route_count,'dispatch_rows',v_dispatch_count,'new_drivers',v_driver_count));
  return jsonb_build_object('ok',true,'input_rows',v_input_count,'route_rows',v_route_count,'dispatch_rows',v_dispatch_count,'rows',v_dispatch_count,'new_drivers',v_driver_count);
end $$;

create or replace function public.admin_list_dispatch_bundle(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return jsonb_build_object(
    'dispatch',coalesce((select jsonb_agg(to_jsonb(d) order by d.route_no,d.run_order,d.shift_type,d.vehicle_no)
      from public.dispatch_assignments d where d.service_date=p_service_date),'[]'::jsonb),
    'route_plan',coalesce((select jsonb_agg(to_jsonb(p) order by p.route_no,p.run_order,p.shift_type,p.vehicle_no)
      from public.daily_route_assignments p where p.service_date=p_service_date),'[]'::jsonb)
  );
end $$;

-- Collector context: use daily route departure first; generic timetable remains a fallback.
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
  where active and effective_from<=p_service_date and (effective_to is null or effective_to>=p_service_date)
  order by effective_from desc,case season_type when 'SPECIAL' then 0 when 'VACATION' then 1 else 2 end,imported_at desc
  limit 1;

  select day_type into v_override from public.service_calendar_overrides where service_date=p_service_date;
  v_day_type:=coalesce(v_override,case
    when extract(dow from p_service_date)=6 then 'SATURDAY'
    when extract(dow from p_service_date)=0 then 'HOLIDAY'
    else 'WEEKDAY' end);

  return jsonb_build_object(
    'service_date',p_service_date,
    'day_type',v_day_type,
    'day_type_source',case when v_override is null then 'AUTO' else 'OVERRIDE' end,
    'timetable_version_id',v_version_id,
    'dispatch',coalesce((select jsonb_agg(x order by x->>'route_no',x->>'run_order',x->>'shift_type') from (
      select jsonb_build_object(
        'id',d.id,'service_date',d.service_date,'vehicle_no',d.vehicle_no,'driver_name',d.driver_name,
        'driver_user_id',d.driver_user_id,'shift_type',d.shift_type,'shift_start',d.shift_start,'shift_end',d.shift_end,
        'route_no',coalesce(nullif(d.route_no,''),p.route_no,''),
        'run_order',case when d.run_order>0 then d.run_order else coalesce(p.run_order,-1) end,
        'planned_departure',p.planned_departure,
        'source_file',d.source_file,'source_format',d.source_format
      ) x
      from public.dispatch_assignments d
      left join public.daily_route_assignments p
        on p.service_date=d.service_date and p.vehicle_no=d.vehicle_no and p.shift_type=d.shift_type
      where d.service_date=p_service_date
    ) q),'[]'::jsonb),
    'bindings',coalesce((select jsonb_agg(to_jsonb(b) order by b.valid_from_at)
      from public.trip_vehicle_bindings b where b.service_date=p_service_date),'[]'::jsonb),
    'timetable',coalesce((select jsonb_agg(jsonb_build_object(
      'route_no',s.route_no,'run_order',s.run_order,'day_type',s.day_type,
      'direction_name',s.direction_name,'departure_time',to_char(s.departure_time,'HH24:MI:SS'))
      order by s.route_no,s.departure_time,s.run_order)
      from public.route_timetable_slots s where s.version_id=v_version_id and s.day_type=v_day_type),'[]'::jsonb)
  );
end $$;

create or replace function public.collector_known_taco_files(p_token text,p_limit int default 10000)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  perform public._require_admin(p_token);
  return coalesce((select jsonb_agg(source_file) from (
    select distinct source_file from public.taco_imports where source_file is not null order by source_file limit greatest(100,least(p_limit,50000))
  ) x),'[]'::jsonb);
end $$;

-- Linkage screen: expose daily route rows separately so missing route/order is diagnosable.
create or replace function public.admin_linkage_status(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_ctx jsonb; v_version_id bigint; v_day_type text;
begin
  perform public._require_admin(p_token);
  v_ctx:=public.collector_get_context(p_token,p_service_date);
  v_version_id:=nullif(v_ctx->>'timetable_version_id','')::bigint;
  v_day_type:=v_ctx->>'day_type';
  return jsonb_build_object(
    'service_date',p_service_date,'day_type',v_day_type,'timetable_version_id',v_version_id,
    'timetable_version',(select jsonb_build_object('id',id,'version_name',version_name,'effective_from',effective_from,'effective_to',effective_to,'season_type',season_type,'source_file',source_file) from public.route_timetable_versions where id=v_version_id),
    'counts',jsonb_build_object(
      'dispatch',(select count(*) from public.dispatch_assignments where service_date=p_service_date),
      'route_plan',(select count(*) from public.daily_route_assignments where service_date=p_service_date),
      'dispatch_unlinked',(select count(*) from public.dispatch_assignments where service_date=p_service_date and (coalesce(route_no,'')='' or run_order<1)),
      'timetable',(select count(*) from public.route_timetable_slots where version_id=v_version_id and day_type=v_day_type),
      'bindings',(select count(*) from public.trip_vehicle_bindings where service_date=p_service_date),
      'changes',(select count(*) from public.vehicle_change_events where service_date=p_service_date),
      'taco_imports',(select count(*) from public.taco_imports where service_date=p_service_date),
      'taco_matched',(select count(*) from public.taco_imports where service_date=p_service_date and match_status='matched'),
      'taco_pending',(select count(*) from public.taco_imports where service_date=p_service_date and match_status in ('pending','partial')),
      'driver_daily',(select count(*) from public.taco_driver_daily where service_date=p_service_date)
    ),
    'dispatch',coalesce(v_ctx->'dispatch','[]'::jsonb),
    'route_plan',coalesce((select jsonb_agg(x) from (select service_date,vehicle_no,shift_type,route_no,run_order,planned_departure,source_file from public.daily_route_assignments where service_date=p_service_date order by route_no,run_order,shift_type limit 300) x),'[]'::jsonb),
    'bindings',coalesce((select jsonb_agg(x) from (select service_date,route_no,run_order,driver_name,planned_vehicle,actual_vehicle,valid_from_at,valid_to_at,binding_type,confidence from public.trip_vehicle_bindings where service_date=p_service_date order by route_no,run_order,valid_from_at limit 300) x),'[]'::jsonb),
    'imports',coalesce((select jsonb_agg(x) from (select source_file,vehicle_no,service_date,collected_at,delay_days,match_status,matched_seconds,unmatched_seconds,record_count from public.taco_imports where service_date=p_service_date order by imported_at desc limit 200) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (select driver_name,vehicle_no,route_no,run_order,distance_km,safety_score,safety_level,match_status,late_days,rapid_start,rapid_accel,rapid_decel,rapid_stop,speed_watch from public.taco_driver_daily where service_date=p_service_date order by driver_name,route_no,run_order limit 300) x),'[]'::jsonb)
  );
end $$;

revoke all on table public.daily_route_assignments from anon,authenticated;
revoke execute on function public.admin_import_dispatch_bundle(text,jsonb,text) from public;
revoke execute on function public.admin_list_dispatch_bundle(text,date) from public;
revoke execute on function public.collector_get_context(text,date) from public;
revoke execute on function public.collector_known_taco_files(text,int) from public;
revoke execute on function public.admin_linkage_status(text,date) from public;
grant execute on function public.admin_import_dispatch_bundle(text,jsonb,text) to anon,authenticated;
grant execute on function public.admin_list_dispatch_bundle(text,date) to anon,authenticated;
grant execute on function public.collector_get_context(text,date) to anon,authenticated;
grant execute on function public.collector_known_taco_files(text,int) to anon,authenticated;
grant execute on function public.admin_linkage_status(text,date) to anon,authenticated;

commit;

select 'SafeDrive v1.4.0 dispatch/BIS/CDT linkage update installed' as status;
