-- Let each authenticated player see only their own scrim applications and team access codes.
-- The access code is never exposed by this function for another player's application.

CREATE OR REPLACE FUNCTION public.get_my_scrim_team_applications()
RETURNS TABLE(
    application_id bigint,
    scrim_title text,
    team_name text,
    team_tag text,
    application_status text,
    slot_number integer,
    team_access_code text,
    created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT
        a.id,
        s.title::text,
        a.team_name::text,
        a.team_tag::text,
        a.status::text,
        a.slot_number,
        a.access_code::text,
        a.created_at
    FROM public.scrim_team_applications AS a
    JOIN public.scrims AS s ON s.id = a.scrim_id
    WHERE auth.uid() IS NOT NULL
      AND a.submitted_by = auth.uid()
    ORDER BY a.created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.get_my_scrim_team_applications() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_scrim_team_applications() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_scrim_team_applications() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_scrim_team_applications() TO service_role;
