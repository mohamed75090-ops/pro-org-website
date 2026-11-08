-- Professional eSports: uploaded scrim result posts
create table if not exists public.scrim_result_posts (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  description text check (description is null or char_length(description) <= 500),
  image_url text not null,
  storage_path text not null,
  status text not null default 'draft' check (status in ('draft','published')),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.scrim_result_posts enable row level security;

drop policy if exists "Public can read published scrim result posts" on public.scrim_result_posts;
create policy "Public can read published scrim result posts" on public.scrim_result_posts
for select to anon, authenticated using (
  status = 'published' or exists (
    select 1 from public.profiles p where p.id = auth.uid()
    and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
  )
);
drop policy if exists "Results managers can insert scrim result posts" on public.scrim_result_posts;
create policy "Results managers can insert scrim result posts" on public.scrim_result_posts
for insert to authenticated with check (
  created_by = auth.uid() and exists (
    select 1 from public.profiles p where p.id = auth.uid()
    and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
  )
);
drop policy if exists "Results managers can update scrim result posts" on public.scrim_result_posts;
create policy "Results managers can update scrim result posts" on public.scrim_result_posts
for update to authenticated using (exists (
  select 1 from public.profiles p where p.id = auth.uid()
  and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
)) with check (exists (
  select 1 from public.profiles p where p.id = auth.uid()
  and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
));
drop policy if exists "Results managers can delete scrim result posts" on public.scrim_result_posts;
create policy "Results managers can delete scrim result posts" on public.scrim_result_posts
for delete to authenticated using (exists (
  select 1 from public.profiles p where p.id = auth.uid()
  and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
));
grant select on public.scrim_result_posts to anon, authenticated;
grant insert, update, delete on public.scrim_result_posts to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('scrim-results', 'scrim-results', true, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 8388608, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "Public can view scrim result images" on storage.objects;
create policy "Public can view scrim result images" on storage.objects
for select to anon, authenticated using (bucket_id = 'scrim-results');
drop policy if exists "Results managers can upload scrim result images" on storage.objects;
create policy "Results managers can upload scrim result images" on storage.objects
for insert to authenticated with check (
  bucket_id = 'scrim-results' and exists (
    select 1 from public.profiles p where p.id = auth.uid()
    and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
  )
);
drop policy if exists "Results managers can delete scrim result images" on storage.objects;
create policy "Results managers can delete scrim result images" on storage.objects
for delete to authenticated using (
  bucket_id = 'scrim-results' and exists (
    select 1 from public.profiles p where p.id = auth.uid()
    and lower(coalesce(p.role,'')) in ('founder','admin','results_manager')
  )
);
