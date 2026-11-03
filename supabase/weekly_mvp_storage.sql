-- Storage bucket for weekly MVP and Top 3 player photos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('weekly-mvp-photos', 'weekly-mvp-photos', true, 8388608, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update
set public = true,
    file_size_limit = 8388608,
    allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "MVP admins can upload photos" on storage.objects;
create policy "MVP admins can upload photos"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'weekly-mvp-photos'
  and exists (
    select 1 from public.profiles
    where id = auth.uid()
      and lower(trim(role)) in ('founder','admin','results_manager','tournament_manager')
  )
);

drop policy if exists "MVP admins can update photos" on storage.objects;
create policy "MVP admins can update photos"
on storage.objects for update to authenticated
using (
  bucket_id = 'weekly-mvp-photos'
  and exists (
    select 1 from public.profiles
    where id = auth.uid()
      and lower(trim(role)) in ('founder','admin','results_manager','tournament_manager')
  )
)
with check (
  bucket_id = 'weekly-mvp-photos'
  and exists (
    select 1 from public.profiles
    where id = auth.uid()
      and lower(trim(role)) in ('founder','admin','results_manager','tournament_manager')
  )
);

drop policy if exists "MVP admins can delete photos" on storage.objects;
create policy "MVP admins can delete photos"
on storage.objects for delete to authenticated
using (
  bucket_id = 'weekly-mvp-photos'
  and exists (
    select 1 from public.profiles
    where id = auth.uid()
      and lower(trim(role)) in ('founder','admin','results_manager','tournament_manager')
  )
);
