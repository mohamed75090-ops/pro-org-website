-- Public community messages for PROFESSIONAL ESPORTS
-- Everyone can read; only authenticated player accounts can post.
create table if not exists public.public_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  author_username text not null,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);

create index if not exists public_messages_created_at_idx
  on public.public_messages (created_at desc);
create index if not exists public_messages_user_created_idx
  on public.public_messages (user_id, created_at desc);

alter table public.public_messages enable row level security;

drop policy if exists "Public can read messages" on public.public_messages;
create policy "Public can read messages"
  on public.public_messages for select
  to anon, authenticated
  using (true);

drop policy if exists "Players can post messages" on public.public_messages;
create policy "Players can post messages"
  on public.public_messages for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "Owners and staff can delete messages" on public.public_messages;
create policy "Owners and staff can delete messages"
  on public.public_messages for delete
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and lower(coalesce(p.role, '')) in ('founder','admin','organizer')
    )
  );

create or replace function public.prepare_public_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
  v_account_type text;
  v_recent_count integer;
begin
  if auth.uid() is null or new.user_id is distinct from auth.uid() then
    raise exception 'يجب تسجيل الدخول بحساب لاعب لإرسال رسالة';
  end if;

  select
    nullif(btrim(u.raw_user_meta_data ->> 'username'), ''),
    lower(coalesce(u.raw_user_meta_data ->> 'account_type', ''))
  into v_username, v_account_type
  from auth.users u
  where u.id = auth.uid();

  if v_account_type <> 'player' then
    raise exception 'إرسال الرسائل متاح لحسابات اللاعبين فقط';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(auth.uid()::text, 741205)
  );

  select count(*) into v_recent_count
  from public.public_messages m
  where m.user_id = auth.uid()
    and m.created_at > now() - interval '1 minute';

  if v_recent_count >= 5 then
    raise exception 'أرسلت رسائل كثيرة. انتظر دقيقة ثم حاول مجدداً';
  end if;

  new.author_username := coalesce(v_username, 'لاعب');
  new.body := btrim(new.body);
  if char_length(new.body) < 1 or char_length(new.body) > 500 then
    raise exception 'الرسالة يجب أن تكون بين حرف واحد و500 حرف';
  end if;
  return new;
end;
$$;

drop trigger if exists prepare_public_message_before_insert on public.public_messages;
create trigger prepare_public_message_before_insert
before insert on public.public_messages
for each row execute function public.prepare_public_message();

revoke all on public.public_messages from public;
grant select on public.public_messages to anon, authenticated;
grant insert, delete on public.public_messages to authenticated;
revoke all on function public.prepare_public_message() from public, anon, authenticated;
grant execute on function public.prepare_public_message() to service_role;

alter table public.public_messages replica identity full;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'public_messages'
     ) then
    execute 'alter publication supabase_realtime add table public.public_messages';
  end if;
end;
$$;
