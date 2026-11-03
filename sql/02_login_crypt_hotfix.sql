-- 대운교통 SafeDrive NEW 로그인 crypt() 오류 긴급 수정
-- 증상 예: function crypt(text, text) does not exist
-- Supabase SQL Editor에서 이 파일 전체를 1회 실행하세요.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Supabase는 확장 기능을 보통 extensions 스키마에 설치합니다.
-- 기존 SECURITY DEFINER 함수가 search_path=public 으로 고정되어 있으면
-- pgcrypto의 crypt()/gen_salt()를 찾지 못하므로 extensions를 추가합니다.
alter function public.app_login(text,text)
  set search_path = public, extensions;

alter function public.app_change_password(text,text,text)
  set search_path = public, extensions;

alter function public.admin_import_dispatch(text,jsonb,text)
  set search_path = public, extensions;

alter function public.admin_import_etas(text,jsonb)
  set search_path = public, extensions;

alter function public.admin_reset_password(text,uuid)
  set search_path = public, extensions;

-- 확인용: crypt 함수가 어느 스키마에 설치되어 있는지 확인
select e.extname, n.nspname as extension_schema
from pg_extension e
join pg_namespace n on n.oid=e.extnamespace
where e.extname='pgcrypto';

-- 관리자 계정 존재 여부 확인(비밀번호 해시는 출력하지 않음)
select login_id, display_name, role, must_change_password, active
from public.app_users
where login_id='관리자';
