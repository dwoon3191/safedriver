-- Daewoon SafeDrive AI v1.4.1
-- Timetable version policy: the latest uploaded timetable applies until the next upload.
-- Existing timetable slots and historical versions are preserved.

begin;

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
  v_from date;
  v_name text;
begin
  v_admin := public._require_admin(p_token);
  v_from := (p_meta->>'effective_from')::date;
  v_name := coalesce(nullif(p_meta->>'version_name',''),p_meta->>'source_file','운행시간표');
  if v_from is null then
    raise exception '시간표 적용 시작일이 필요합니다.';
  end if;

  -- The previous timetable remains valid through the day before the new version.
  update public.route_timetable_versions
     set effective_to = v_from - 1
   where active
     and effective_from < v_from
     and (effective_to is null or effective_to >= v_from);

  -- If another file is registered with the same effective date, keep it as history
  -- but make the newly uploaded file the active version for that date.
  update public.route_timetable_versions
     set active = false
   where effective_from = v_from
     and version_name <> v_name;

  insert into public.route_timetable_versions(
    version_name,effective_from,effective_to,season_type,source_file,active,imported_by,imported_at
  ) values(
    v_name,
    v_from,
    null,
    'NORMAL',
    p_meta->>'source_file',true,v_admin,now()
  ) on conflict(version_name,effective_from,season_type) do update set
    effective_to=null,
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
    jsonb_build_object('rows',v_count,'file',p_meta->>'source_file','effective_from',v_from,'policy','UNTIL_NEXT_UPLOAD'));
  return jsonb_build_object('ok',true,'version_id',v_version_id,'rows',v_count,'effective_from',v_from,'effective_to',null);
end $$;

revoke execute on function public.admin_import_timetable(text,jsonb,jsonb) from public;
grant execute on function public.admin_import_timetable(text,jsonb,jsonb) to anon,authenticated;

commit;

select 'SafeDrive v1.4.1 timetable auto-version update installed' as status;
