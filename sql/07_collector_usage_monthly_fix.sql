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
