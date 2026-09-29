-- ============================================================
-- Migration 041: 3 ältere Musik-Kategorien entfernt
-- ============================================================
-- Auf Wunsch: nur die 3 zuletzt vom User kuratierten Kategorien
-- behalten (Deutschrap-Songs, 2000er Old School, Shisha Club, siehe
-- Migration 039/040) -- die 3 ursprünglichen (Migration 026/033)
-- komplett entfernt.
--
-- topic_pool.id ist per ON DELETE CASCADE Referenz aus song_pool +
-- topic_answers verlinkt -- das Löschen der topic_pool-Zeile räumt
-- also automatisch die zugehörigen Songs mit ab. current_song_id auf
-- lobbies zeigt aber OHNE CASCADE auf song_pool, muss also vorher
-- genullt werden (gleiches Muster wie Migration 033/039).
-- ============================================================

BEGIN;

UPDATE public.lobbies l
SET current_song_id = NULL
FROM public.song_pool sp
JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id
WHERE l.current_song_id = sp.id
  AND tp.text IN ('Deutschrap Klassiker', 'Englische All-Time-Hits', 'Internationale Pop-Charts');

DELETE FROM public.topic_pool
WHERE text IN ('Deutschrap Klassiker', 'Englische All-Time-Hits', 'Internationale Pop-Charts');

COMMIT;
