-- ============================================================
-- Migration 038: "Internationale Pop-Charts" erweitert (13 -> 21)
-- ============================================================
-- Kleinster Song-Pool aller Kategorien -- bei langen Matches (viele
-- Runden) war das Risiko am größten, dass der Pool durchläuft und
-- Migration 037 (kein Sofort-Repeat) auf einen sehr kleinen Rest
-- zurückgreifen muss. Quelle: Billboard Global 200 Top-10-Singles
-- 2026 (Wikipedia), Titel/Interpret 1:1 übernommen wie in Migration
-- 033. Preview-URLs holt sich der bestehende Backfill-Job automatisch
-- (preview_checked_at ist bei neuen Zeilen NULL).
-- ============================================================

BEGIN;

INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Internationale Pop-Charts', 'Golden', 'Huntrix (Ejae, Audrey Nuna & Rei Ami)'),
    ('Internationale Pop-Charts', 'Ordinary', 'Alex Warren'),
    ('Internationale Pop-Charts', 'Back to Friends', 'Sombr'),
    ('Internationale Pop-Charts', 'Die with a Smile', 'Lady Gaga & Bruno Mars'),
    ('Internationale Pop-Charts', 'Animal', 'Katseye'),
    ('Internationale Pop-Charts', 'Loser', 'Tame Impala'),
    ('Internationale Pop-Charts', 'BbY WOW', 'Karol G, Judeline & Rusowsky'),
    ('Internationale Pop-Charts', 'Man I Need', 'Olivia Dean')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

COMMIT;
