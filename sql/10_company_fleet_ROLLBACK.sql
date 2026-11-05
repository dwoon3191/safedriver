-- Only for rollback together with original web/collector files. Never run during upgrade.
begin;
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
notify pgrst, 'reload schema';
commit;
