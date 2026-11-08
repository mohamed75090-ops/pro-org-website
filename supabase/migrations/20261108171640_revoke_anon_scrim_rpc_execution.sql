-- These RPCs require an authenticated identity or staff role internally.
-- Anonymous callers have no valid use for them; preserve authenticated access.
revoke execute on function public.can_withdraw_own_scrim_team_application(text) from anon;
revoke execute on function public.review_tournament_team_application(uuid,text,text) from anon;
revoke execute on function public.withdraw_own_scrim_team_application(text) from anon;
revoke execute on function public.withdraw_scrim_team_application(bigint) from anon;
