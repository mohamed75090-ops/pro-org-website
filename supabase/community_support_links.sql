-- Community support links (Instagram / WhatsApp)
create table if not exists public.community_support_links (
  id integer primary key check (id = 1),
  instagram_url text,
  whatsapp_url text,
  updated_at timestamptz not null default now()
);

insert into public.community_support_links (id)
values (1)
on conflict (id) do nothing;

alter table public.community_support_links enable row level security;

drop policy if exists "Public can read community support links" on public.community_support_links;
create policy "Public can read community support links"
on public.community_support_links for select
to anon, authenticated
using (true);

drop policy if exists "Founder can manage community support links" on public.community_support_links;
create policy "Founder can manage community support links"
on public.community_support_links for all
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and lower(coalesce(p.role, '')) = 'founder'
  )
)
with check (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and lower(coalesce(p.role, '')) = 'founder'
  )
);

grant select on public.community_support_links to anon, authenticated;
grant insert, update, delete on public.community_support_links to authenticated;
