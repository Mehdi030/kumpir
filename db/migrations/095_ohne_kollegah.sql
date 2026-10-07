-- ============================================================
-- 095: Kollegah raus aus "Deutschrap aktuell" (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Seine Klassiker gibt es bei iTunes nicht (keine Hörprobe), übrig waren nur Nebenwerke.
-- Die 5 Songs mit Kollegah gehen ins Archiv (nicht gelöscht: Spielprotokoll/Statistik bleiben gültig).
-- Auch aus db/scripts/data/deutschrap-rapper.json entfernt, damit ein neuer Bau ihn nicht zurückholt.
-- ============================================================
BEGIN;

UPDATE public.song_pool s
SET archived_from = 'Deutschrap aktuell',
    topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)')
WHERE s.topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Deutschrap aktuell')
  AND s.artist ILIKE '%kollegah%';

COMMIT;
