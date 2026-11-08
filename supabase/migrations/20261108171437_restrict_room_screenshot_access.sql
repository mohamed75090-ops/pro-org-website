-- Restrict AI room screenshot storage to the same roles allowed to run the scanner.
drop policy if exists "Authenticated read room screenshots" on storage.objects;
drop policy if exists "Authenticated upload room screenshots" on storage.objects;

create policy "Authorized results staff read room screenshots"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'room-screenshots'
  and public.has_any_role(array['founder','admin','results_manager']::text[])
);

create policy "Authorized results staff upload room screenshots"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'room-screenshots'
  and public.has_any_role(array['founder','admin','results_manager']::text[])
);

update storage.buckets
set file_size_limit = 8388608,
    allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'room-screenshots';
