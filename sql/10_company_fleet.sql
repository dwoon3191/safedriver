-- SafeDrive fleet upgrade. Run ONCE after stopping the existing collector.
-- No existing business rows are deleted or rewritten. Requires v1.4.1 schema.
begin;
do $$ begin
  if to_regprocedure('public.collector_get_context(text,date)') is null
     or to_regprocedure('public.admin_linkage_status(text,date)') is null
     or to_regclass('public.daily_route_assignments') is null then
    raise exception 'v1.4.1 설치 상태를 먼저 확인하세요.';
  end if;
end $$;
create table if not exists public.company_fleet_registry (
  singleton boolean primary key default true check(singleton),
  revision bigint not null default 0,
  source_file text,
  updated_at timestamptz,
  updated_by uuid references public.app_users(id)
);
insert into public.company_fleet_registry(singleton) values(true) on conflict do nothing;
create table if not exists public.company_fleet_vehicles (
  vehicle_no text primary key,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  check(vehicle_no ~ '^[가-힣]{2}[0-9]{2,3}[가-힣][0-9]{4}$')
);
alter table public.company_fleet_registry enable row level security;
alter table public.company_fleet_vehicles enable row level security;
revoke all on public.company_fleet_registry,public.company_fleet_vehicles from public,anon,authenticated;

create or replace function public._fleet_normalize(p_vehicle text)
returns text language sql immutable set search_path=public as $$
 select case when v ~ '^[0-9]{4}$' then '경남71자'||v
             when v ~ '^(경남)?71자?[0-9]{4}$' then '경남71자'||right(v,4)
             else v end
 from (select regexp_replace(coalesce(p_vehicle,''),'[[:space:]]','','g') v) x
$$;
create or replace function public._fleet_contains(p_vehicle text)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.company_fleet_vehicles
   where active and vehicle_no=public._fleet_normalize(p_vehicle))
$$;
create or replace function public.admin_fleet_get(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
 perform public._require_admin(p_token);
 return (select to_jsonb(r) from public.company_fleet_registry r where singleton)
 || jsonb_build_object('vehicles',coalesce((select jsonb_agg(vehicle_no order by vehicle_no)
 from public.company_fleet_vehicles where active),'[]'::jsonb));
end $$;
create or replace function public.admin_fleet_replace(
 p_token text,p_vehicles jsonb,p_source_file text,p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_admin uuid; v_revision bigint; v_count int;
begin
 v_admin:=public._require_admin(p_token);
 select revision into v_revision from public.company_fleet_registry where singleton for update;
 if p_expected_revision is distinct from v_revision then
   raise exception '다른 관리자가 명부를 변경했습니다. 새로고침 후 다시 등록하세요.';
 end if;
 if jsonb_typeof(p_vehicles) is distinct from 'array' then raise exception '차량번호 배열이 필요합니다.'; end if;
 v_count:=jsonb_array_length(p_vehicles);
 if v_count<1 or v_count>2000 then raise exception '차량명부는 1~2000대만 등록할 수 있습니다.'; end if;
 if exists(select 1 from jsonb_array_elements(p_vehicles) v where
    jsonb_typeof(v) <> 'string' or (v#>>'{}') !~ '^[가-힣]{2}[0-9]{2,3}[가-힣][0-9]{4}$') then
   raise exception '차량번호 형식이 올바르지 않습니다. 전체 번호를 확인하세요.';
 end if;
 if (select count(distinct v) from jsonb_array_elements_text(p_vehicles) v)<>v_count then
   raise exception '중복 차량번호가 있습니다.';
 end if;
 if length(coalesce(p_source_file,''))=0 or length(p_source_file)>255 then
   raise exception '파일명이 올바르지 않습니다.';
 end if;
 update public.company_fleet_vehicles set active=false,updated_at=now() where active;
 insert into public.company_fleet_vehicles(vehicle_no,active)
 select v,true from jsonb_array_elements_text(p_vehicles) v
 on conflict(vehicle_no) do update set active=true,updated_at=now();
 update public.company_fleet_registry set revision=revision+1,source_file=p_source_file,
 updated_at=now(),updated_by=v_admin where singleton;
 perform public._audit(v_admin,'REPLACE_COMPANY_FLEET','company_fleet',null,
   jsonb_build_object('count',v_count,'source_file',p_source_file,'revision',v_revision+1));
 return public.admin_fleet_get(p_token);
end $$;
create or replace function public.collector_get_fleet_context(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_ctx jsonb; v_fleet jsonb;
begin
 v_fleet:=public.admin_fleet_get(p_token);
 if jsonb_array_length(v_fleet->'vehicles')=0 then raise exception '웹 데이터 연계에서 보유차량 엑셀을 먼저 등록하세요.'; end if;
 v_ctx:=public.collector_get_context(p_token,p_service_date);
 return v_ctx || jsonb_build_object('fleet',v_fleet,
 'dispatch',coalesce((select jsonb_agg(x) from jsonb_array_elements(v_ctx->'dispatch') x
   where public._fleet_contains(x->>'vehicle_no')),'[]'::jsonb),
 'bindings',coalesce((select jsonb_agg(x) from jsonb_array_elements(v_ctx->'bindings') x
   where public._fleet_contains(x->>'planned_vehicle') and public._fleet_contains(x->>'actual_vehicle')),'[]'::jsonb));
end $$;

create or replace function public.admin_fleet_linkage_status(p_token text,p_service_date date)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_ctx jsonb; v_version_id bigint; v_day_type text;
begin
  perform public._require_admin(p_token);
  v_ctx:=public.collector_get_context(p_token,p_service_date);
  v_version_id:=nullif(v_ctx->>'timetable_version_id','')::bigint;
  v_day_type:=v_ctx->>'day_type';
  return jsonb_build_object(
    'fleet',public.admin_fleet_get(p_token),'service_date',p_service_date,'day_type',v_day_type,'timetable_version_id',v_version_id,
    'timetable_version',(select jsonb_build_object('id',id,'version_name',version_name,'effective_from',effective_from,'effective_to',effective_to,'season_type',season_type,'source_file',source_file) from public.route_timetable_versions where id=v_version_id),
    'counts',jsonb_build_object(
      'dispatch',(select count(*) from public.dispatch_assignments where service_date=p_service_date and public._fleet_contains(vehicle_no)),
      'route_plan',(select count(*) from public.daily_route_assignments where service_date=p_service_date and public._fleet_contains(vehicle_no)),
      'dispatch_unlinked',(select count(*) from public.dispatch_assignments where service_date=p_service_date and public._fleet_contains(vehicle_no) and (coalesce(route_no,'')='' or run_order<1)),
      'timetable',(select count(*) from public.route_timetable_slots where version_id=v_version_id and day_type=v_day_type),
      'bindings',(select count(*) from public.trip_vehicle_bindings where service_date=p_service_date and public._fleet_contains(planned_vehicle) and public._fleet_contains(actual_vehicle)),
      'changes',(select count(*) from public.vehicle_change_events where service_date=p_service_date and public._fleet_contains(coalesce(planned_vehicle,old_vehicle)) and public._fleet_contains(coalesce(actual_vehicle,new_vehicle))),
      'taco_imports',(select count(*) from public.taco_imports where service_date=p_service_date and public._fleet_contains(vehicle_no)),
      'taco_matched',(select count(*) from public.taco_imports where service_date=p_service_date and public._fleet_contains(vehicle_no) and match_status='matched'),
      'taco_pending',(select count(*) from public.taco_imports where service_date=p_service_date and public._fleet_contains(vehicle_no) and match_status in ('pending','partial')),
      'driver_daily',(select count(*) from public.taco_driver_daily where service_date=p_service_date and public._fleet_contains(vehicle_no))
    ),
    'dispatch',coalesce((select jsonb_agg(x) from jsonb_array_elements(v_ctx->'dispatch') x where public._fleet_contains(x->>'vehicle_no')),'[]'::jsonb),
    'route_plan',coalesce((select jsonb_agg(x) from (select service_date,vehicle_no,shift_type,route_no,run_order,planned_departure,source_file from public.daily_route_assignments where service_date=p_service_date and public._fleet_contains(vehicle_no) order by route_no,run_order,shift_type limit 300) x),'[]'::jsonb),
    'bindings',coalesce((select jsonb_agg(x) from (select service_date,route_no,run_order,driver_name,planned_vehicle,actual_vehicle,valid_from_at,valid_to_at,binding_type,confidence from public.trip_vehicle_bindings where service_date=p_service_date and public._fleet_contains(planned_vehicle) and public._fleet_contains(actual_vehicle) order by route_no,run_order,valid_from_at limit 300) x),'[]'::jsonb),
    'imports',coalesce((select jsonb_agg(x) from (select source_file,vehicle_no,service_date,collected_at,delay_days,match_status,matched_seconds,unmatched_seconds,record_count from public.taco_imports where service_date=p_service_date and public._fleet_contains(vehicle_no) order by imported_at desc limit 200) x),'[]'::jsonb),
    'daily',coalesce((select jsonb_agg(x) from (select driver_name,vehicle_no,route_no,run_order,distance_km,safety_score,safety_level,match_status,late_days,rapid_start,rapid_accel,rapid_decel,rapid_stop,speed_watch from public.taco_driver_daily where service_date=p_service_date and public._fleet_contains(vehicle_no) order by driver_name,route_no,run_order limit 300) x),'[]'::jsonb)
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
  perform 1 from public.company_fleet_registry where singleton for share;
  if not exists(select 1 from public.company_fleet_vehicles where active) then
    raise exception '보유차량 명부를 먼저 등록하세요.';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_changes,'[]'::jsonb)) loop
    if not public._fleet_contains(coalesce(r->>'planned_vehicle',r->>'old_vehicle'))
       or not public._fleet_contains(coalesce(r->>'actual_vehicle',r->>'new_vehicle'))
       or not public._fleet_contains(r->>'old_vehicle')
       or not public._fleet_contains(r->>'new_vehicle') then
      continue;
    end if;
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
  perform 1 from public.company_fleet_registry where singleton for share;
  if not public._fleet_contains(p_import->>'vehicle_no')
    or exists(select 1 from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) x where not public._fleet_contains(x->>'vehicle_no'))
    or exists(select 1 from jsonb_array_elements(coalesce(p_summaries,'[]'::jsonb)) x where not public._fleet_contains(x->>'vehicle_no')) then
    raise exception '보유차량 명부에 없는 CDT 차량입니다. 등록 상태를 확인하세요.';
  end if;
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
revoke execute on function public._fleet_normalize(text) from public,anon,authenticated;
revoke execute on function public._fleet_contains(text) from public,anon,authenticated;
revoke execute on function public.admin_fleet_get(text) from public,anon,authenticated;
revoke execute on function public.admin_fleet_replace(text,jsonb,text,bigint) from public,anon,authenticated;
revoke execute on function public.collector_get_fleet_context(text,date) from public,anon,authenticated;
revoke execute on function public.admin_fleet_linkage_status(text,date) from public,anon,authenticated;
grant execute on function public.admin_fleet_get(text) to anon,authenticated;
grant execute on function public.admin_fleet_replace(text,jsonb,text,bigint) to anon,authenticated;
grant execute on function public.collector_get_fleet_context(text,date) to anon,authenticated;
grant execute on function public.admin_fleet_linkage_status(text,date) to anon,authenticated;
notify pgrst, 'reload schema';
commit;
