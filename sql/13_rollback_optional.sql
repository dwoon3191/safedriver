-- OPTIONAL rollback for v2.1.0. Removes only the new function.
-- Accounts linked by the app's "전체 연결" button stay linked (mr_profiles rows are data, not code).
-- If you also need to undo links made on a given day, review them first:
--   select user_id,etas_name,employment,effective_date from public.mr_profiles order by updated_at desc;
-- and delete only the exact rows you want removed. Do not delete rows that have reports attached.
begin;
drop function if exists public.mr_api2(text,text,jsonb);
commit;
