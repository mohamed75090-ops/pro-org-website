-- Migration 006: secure scrim team-center RPCs.
-- A 3-digit access code is a lookup key, not proof of team ownership.
-- Only the player account linked through submitted_by may read private team-center data.

CREATE OR REPLACE FUNCTION public.get_team_application_status(team_code text)
RETURNS TABLE(
    status text,
    scrim_title text,
    team_name text,
    team_short_name text,
    team_representative text,
    team_tag text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT
        a.status::text,
        s.title::text,
        a.team_name::text,
        a.team_short_name::text,
        a.team_representative::text,
        a.team_tag::text
    FROM public.scrim_team_applications AS a
    JOIN public.scrims AS s ON s.id = a.scrim_id
    WHERE auth.uid() IS NOT NULL
      AND a.submitted_by = auth.uid()
      AND a.access_code = trim(team_code)
    LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.get_team_scrim_details(team_code text)
RETURNS TABLE(
    scrim_id uuid,
    scrim_title text,
    team_name text,
    team_short_name text,
    team_representative text,
    team_tag text,
    slot_number integer,
    withdrawal_closes_at timestamptz,
    room_id text,
    room_password text,
    room_published boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT
        s.id,
        s.title::text,
        a.team_name::text,
        a.team_short_name::text,
        a.team_representative::text,
        a.team_tag::text,
        a.slot_number,
        s.withdrawal_closes_at,
        CASE WHEN s.room_published THEN s.room_id::text ELSE NULL END,
        CASE WHEN s.room_published THEN s.room_password::text ELSE NULL END,
        COALESCE(s.room_published, false)
    FROM public.scrim_team_applications AS a
    JOIN public.scrims AS s ON s.id = a.scrim_id
    WHERE auth.uid() IS NOT NULL
      AND a.submitted_by = auth.uid()
      AND a.access_code = trim(team_code)
      AND a.status = 'accepted'
    LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.get_team_scrim_matches(team_code text)
RETURNS TABLE(
    match_number integer,
    title text,
    starts_at timestamptz,
    status text,
    room_id text,
    room_password text,
    room_published boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT
        m.match_number,
        m.title::text,
        m.starts_at,
        m.status::text,
        CASE WHEN m.room_published THEN m.room_id::text ELSE NULL END,
        CASE WHEN m.room_published THEN m.room_password::text ELSE NULL END,
        COALESCE(m.room_published, false)
    FROM public.scrim_team_applications AS a
    JOIN public.scrim_matches AS m ON m.scrim_id = a.scrim_id
    WHERE auth.uid() IS NOT NULL
      AND a.submitted_by = auth.uid()
      AND a.access_code = trim(team_code)
      AND a.status = 'accepted'
      AND m.status IN ('published', 'live', 'completed')
    ORDER BY m.match_number;
$function$;

REVOKE ALL ON FUNCTION public.get_team_application_status(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_team_application_status(text) FROM anon;
REVOKE ALL ON FUNCTION public.get_team_scrim_details(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_team_scrim_details(text) FROM anon;
REVOKE ALL ON FUNCTION public.get_team_scrim_matches(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_team_scrim_matches(text) FROM anon;

GRANT EXECUTE ON FUNCTION public.get_team_application_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_team_scrim_details(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_team_scrim_matches(text) TO authenticated;
