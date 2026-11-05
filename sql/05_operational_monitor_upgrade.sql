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
  into v_result from delivered;
  return coalesce(v_result,'[]'::jsonb);
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
