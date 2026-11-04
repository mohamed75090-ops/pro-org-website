-- PROFESSIONAL ESPORTS: Fix ambiguous status reference in tournament registration RPC
-- The RETURNS TABLE output column "status" conflicts with an unqualified tournaments.status reference.
create or replace function public.submit_tournament_team_application(
  p_tournament_id uuid,
  p_team_name text,
  p_team_tag text,
  p_team_representative text
)
returns table(access_code text, status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.tournaments%rowtype;
  v_code text;
begin
  select tr.*
    into t
  from public.tournaments as tr
  where tr.id = p_tournament_id
    and tr.status = 'published';

  if not found then
    raise exception 'البطولة غير متاحة للتسجيل';
  end if;

  if not coalesce(t.registration_enabled, false) then
    raise exception 'التسجيل غير مفتوح لهذه البطولة';
  end if;

  if t.registration_opens_at is not null and now() < t.registration_opens_at then
    raise exception 'لم يبدأ التسجيل بعد';
  end if;

  if t.registration_closes_at is not null and now() > t.registration_closes_at then
    raise exception 'انتهى التسجيل';
  end if;

  if length(trim(coalesce(p_team_name, ''))) < 2
     or length(trim(coalesce(p_team_tag, ''))) < 2
     or length(trim(coalesce(p_team_representative, ''))) < 2 then
    raise exception 'أكمل بيانات الفريق';
  end if;

  if exists (
    select 1
    from public.tournament_team_applications as a
    where a.tournament_id = p_tournament_id
      and lower(a.team_tag) = lower(trim(p_team_tag))
  ) then
    raise exception 'هذا الفريق أرسل طلباً لهذه البطولة من قبل';
  end if;

  if (
    select count(*)
    from public.tournament_team_applications as a
    where a.tournament_id = p_tournament_id
      and a.status in ('pending', 'accepted', 'backup')
  ) >= greatest(coalesce(t.max_teams, 25), 1) then
    raise exception 'اكتمل عدد طلبات الفرق لهذه البطولة';
  end if;

  v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));

  insert into public.tournament_team_applications
    (tournament_id, team_name, team_tag, team_representative, access_code)
  values
    (p_tournament_id, trim(p_team_name), upper(trim(p_team_tag)),
     trim(p_team_representative), v_code);

  return query select v_code, 'pending'::text;
end;
$$;

revoke all on function public.submit_tournament_team_application(uuid, text, text, text) from public;
grant execute on function public.submit_tournament_team_application(uuid, text, text, text) to anon, authenticated;

-- Match the dashboard's allowed tournament staff roles.
drop policy if exists "Tournament managers read applications" on public.tournament_team_applications;
create policy "Tournament managers read applications"
on public.tournament_team_applications
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in ('founder', 'admin', 'organizer', 'tournament_manager')
  )
);

drop policy if exists "Tournament managers update applications" on public.tournament_team_applications;
create policy "Tournament managers update applications"
on public.tournament_team_applications
for update to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in ('founder', 'admin', 'organizer', 'tournament_manager')
  )
)
with check (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in ('founder', 'admin', 'organizer', 'tournament_manager')
  )
);
