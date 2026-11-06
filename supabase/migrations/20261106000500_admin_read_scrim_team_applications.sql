-- Migration 005: allow admins to read scrim team applications.
-- This is a narrowly scoped SELECT policy; it does not grant write access.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'scrim_team_applications'
          AND policyname = 'scrim_team_applications_admin_select'
    ) THEN
        CREATE POLICY scrim_team_applications_admin_select
            ON public.scrim_team_applications
            FOR SELECT
            TO authenticated
            USING (
                EXISTS (
                    SELECT 1
                    FROM public.profiles AS p
                    WHERE p.id = auth.uid()
                      AND lower(COALESCE(p.role, '')) = 'admin'
                )
            );
    END IF;
END
$$;
