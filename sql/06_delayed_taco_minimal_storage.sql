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
