-- PROFESSIONAL ESPORTS: default every newly registered account to the player role.
-- Run once in Supabase SQL Editor. Existing elevated roles are preserved.

begin;

-- New profile rows default to player unless a trusted founder workflow assigns another role.
alter table public.profiles
  alter column role set default 'player';

-- Backfill profiles for existing Auth accounts that do not yet have a profile.
-- Existing profile rows and their current roles are not overwritten.
insert into public.profiles (id, role)
select u.id, 'player'
from auth.users u
on conflict (id) do nothing;

-- Repair only missing/blank roles. Founder/admin/organizer roles remain unchanged.
update public.profiles
set role = 'player'
where role is null or trim(role) = '';

create or replace function public.ensure_player_profile_on_signup()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.profiles (id, role)
  values (new.id, 'player')
  on conflict (id) do update
    set role = 'player'
    where public.profiles.role is null
       or trim(public.profiles.role) = '';
  return new;
end;
$$;

revoke all on function public.ensure_player_profile_on_signup() from public, anon, authenticated;

-- Run after other signup triggers so a profile created by the existing project trigger is retained.
drop trigger if exists zzz_ensure_player_profile_on_signup on auth.users;
create trigger zzz_ensure_player_profile_on_signup
after insert on auth.users
for each row execute function public.ensure_player_profile_on_signup();

commit;
