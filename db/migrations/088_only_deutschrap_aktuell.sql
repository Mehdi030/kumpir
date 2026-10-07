-- ============================================================
-- 088: Nur noch "Deutschrap aktuell" (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Alle anderen Musik-Playlists und das Song-Archiv werden gelöscht (Sicherung: db/backups/playlists-2026-10-07T07-11-45-545Z.json,
-- lokal, nicht im Git). In "Deutschrap aktuell" bleiben nur Songs mit funktionierender Hörprobe
-- (jede Vorschau-Datei geprüft). Das leere Archiv-Thema bleibt, weil "Song archivieren" im Admin-Panel es braucht.
-- ============================================================
BEGIN;

UPDATE public.lobbies SET current_song_id = NULL
WHERE current_song_id IN (
  SELECT sp.id FROM public.song_pool sp JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id
  WHERE (tp.is_song_category AND tp.text <> 'Deutschrap aktuell') OR tp.text = 'Archiv (deaktivierte Songs)'
);

-- Archiv leeren
DELETE FROM public.song_pool WHERE topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)');

-- andere Musik-Playlists samt Songs entfernen
DELETE FROM public.topic_pool WHERE is_song_category AND text <> 'Deutschrap aktuell';

COMMIT;
