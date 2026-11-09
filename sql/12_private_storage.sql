-- Existing project: create an isolated PRIVATE bucket. No existing bucket/table removed.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('driver-monthly-private','driver-monthly-private',false,3145728,
 array['application/pdf','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict(id) do update set public=false,file_size_limit=3145728,
 allowed_mime_types=excluded.allowed_mime_types;
-- No anon/authenticated policies added. Access is checked by the server gateway.
commit;
