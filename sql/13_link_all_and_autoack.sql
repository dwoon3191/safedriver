-- v2.1.0 additive migration. Run ONLY this file, after sql/11 and sql/12 were applied.
-- Adds one NEW function (mr_api2). It does not change mr_api, tables, policies or data by itself.
-- link_all / link_one write rows only when an administrator presses the button in the app.
begin;
create or replace function public.mr_api2(p_token text,p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid; adm boolean; r record; rid uuid; target uuid; nm text; emp text; ack timestamptz;
 linked int:=0; already int:=0; conflicts jsonb:='[]'::jsonb; empties jsonb:='[]'::jsonb;
begin
 uid:=public._session_user_id(p_token);
 if uid is null then raise exception '로그인이 만료되었거나 계정이 비활성 상태입니다.'; end if;
 select role='admin' into adm from public.app_users where id=uid;
 if exists(select 1 from public.app_users where id=uid and must_change_password) then raise exception '먼저 비밀번호를 변경하세요.'; end if;

 if p_action='link_all' then
  -- Link every driver account that has no mr_profiles row yet, using the account name as the
  -- eTAS name. Existing links are never changed. Duplicate/empty names are reported, not linked.
  if not adm then raise exception '관리자 권한 필요'; end if;
  for r in select u.id,u.display_name,u.active from public.app_users u where u.role='driver' order by u.display_name loop
   if exists(select 1 from public.mr_profiles p where p.user_id=r.id) then already:=already+1; continue; end if;
   nm:=trim(coalesce(r.display_name,''));
   if nm='' or length(nm)>100 then empties:=empties||to_jsonb(coalesce(r.display_name,'')); continue; end if;
   emp:=case when r.active then '재직' else '퇴사' end;
   begin
    insert into public.mr_profiles(user_id,etas_name,employment,effective_date) values(r.id,nm,emp,current_date);
    linked:=linked+1;
   exception when unique_violation then
    conflicts:=conflicts||to_jsonb(nm);
   end;
  end loop;
  perform public._audit(uid,'MR_LINK_ALL','app_user','all',
   jsonb_build_object('linked',linked,'already',already,'conflicts',jsonb_array_length(conflicts),'empty',jsonb_array_length(empties)));
  return jsonb_build_object('linked',linked,'already',already,'conflicts',conflicts,'empty',empties);

 elsif p_action='link_one' then
  -- Link one account that has no eTAS name yet (used when a file name matches that account).
  if not adm then raise exception '관리자 권한 필요'; end if;
  target:=nullif(p_data->>'user_id','')::uuid; nm:=trim(coalesce(p_data->>'etas_name',''));
  if target is null or length(nm)<1 or length(nm)>100 then raise exception '기사와 공단 이름을 확인하세요.'; end if;
  select case when u.active then '재직' else '퇴사' end into emp from public.app_users u where u.id=target and u.role='driver';
  if emp is null then raise exception '기사 계정이 아닙니다.'; end if;
  if exists(select 1 from public.mr_profiles where user_id=target) then raise exception '이미 공단 이름이 연결된 기사입니다.'; end if;
  begin
   insert into public.mr_profiles(user_id,etas_name,employment,effective_date) values(target,nm,emp,current_date);
  exception when unique_violation then
   raise exception '같은 공단 이름이 이미 다른 기사에 연결되어 있습니다.';
  end;
  perform public._audit(uid,'MR_LINK_ONE','app_user',target::text,jsonb_build_object('etas_name',nm));
  return jsonb_build_object('ok',true,'etas_name',nm);

 elsif p_action='open_ack' then
  -- Driver opened the PDF: record opened and acknowledged together, for the current revision only.
  if adm then raise exception '기사 본인만 열람 확인을 기록합니다.'; end if;
  rid:=nullif(p_data->>'id','')::uuid;
  update public.mr_reports
     set opened_at=coalesce(opened_at,now()),acknowledged_at=coalesce(acknowledged_at,now())
   where id=rid and user_id=uid and published and revision=(p_data->>'revision')::int
   returning acknowledged_at into ack;
  if not found then raise exception '자료가 교체되었거나 열 수 없는 보고서입니다. 화면을 새로고침하세요.'; end if;
  perform public._audit(uid,'MR_OPEN_ACK','mr_report',rid::text);
  return jsonb_build_object('ok',true,'acknowledged_at',ack);

 else raise exception '지원하지 않는 작업';
 end if;
end $$;
revoke all on function public.mr_api2(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.mr_api2(text,text,jsonb) to service_role;
commit;
