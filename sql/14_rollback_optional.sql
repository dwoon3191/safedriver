-- v2.2.0 선택적 롤백입니다. 배차 조회 함수만 제거합니다.
-- 업로드한 배차 자료(dp_days, dp_rows 표)는 자료 보존을 위해 삭제하지 않습니다.
-- 표까지 완전히 지우려면 아래 두 줄의 주석(--)을 제거하고 실행하세요. 되돌릴 수 없습니다.
begin;
drop function if exists public.dp_api(text,text,jsonb);
-- drop table if exists public.dp_rows;
-- drop table if exists public.dp_days;
commit;
notify pgrst, 'reload schema';
