-- Daewoon SafeDrive NEW v1.0.4
-- Existing DB hotfix: dispatch Excel import timeout
-- Safe to run on an existing project. It does not delete existing data.

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


revoke execute on function public.admin_import_dispatch(text,jsonb,text) from public;
grant execute on function public.admin_import_dispatch(text,jsonb,text) to anon, authenticated;

select 'dispatch import timeout fix installed' as status;
