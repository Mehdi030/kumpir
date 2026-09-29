-- ============================================================
-- Migration 036: iTunes-Preview-URL pro Song gecacht statt live geladen
-- ============================================================
-- Bisher fragte SongRound.tsx bei JEDEM neuen Song live die iTunes
-- Search API an, um die Preview-URL zu finden -- unnötige Ladezeit und
-- ein externer Request pro Rundenwechsel, obwohl sich der Titel eines
-- Songs nie ändert. Neue Spalten cachen das Ergebnis einmalig in der DB;
-- db/scripts/backfill-song-previews.mjs füllt sie, SongRound.tsx liest
-- nur noch preview_url mit (kein Live-Fetch mehr, außer als Fallback
-- für Songs ohne Treffer).
-- ============================================================

BEGIN;

ALTER TABLE public.song_pool
    ADD COLUMN IF NOT EXISTS preview_url text,
    ADD COLUMN IF NOT EXISTS preview_checked_at timestamptz;

COMMIT;
