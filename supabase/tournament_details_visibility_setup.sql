-- Adds an independent public visibility switch for tournament registration details.
-- Existing tournaments keep their current behavior (details visible).
ALTER TABLE public.tournaments
ADD COLUMN IF NOT EXISTS details_visible boolean NOT NULL DEFAULT true;
