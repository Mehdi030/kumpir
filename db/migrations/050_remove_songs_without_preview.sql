-- ============================================================
-- Migration 050: Songs ohne iTunes-Vorschau entfernen
-- ============================================================
-- Live-Test mit 5 Spielern hat den Bug bestätigt: _pick_next_song zog
-- bisher aus dem GESAMTEN song_pool, auch aus Songs, für die
-- db/scripts/backfill-song-previews.mjs schon geprüft hat und KEINE
-- iTunes-30s-Vorschau gefunden hat (preview_url NULL, preview_checked_at
-- gesetzt). In diesen Runden blieb der Ton komplett stumm -- der Halter
-- musste blind raten. Betraf ca. 53 von 150 Songs (31 Deutschrap-Songs,
-- 21 Shisha Club, 1 2000er Old School).
--
-- Fix: diese Songs werden komplett aus dem Pool entfernt (nicht nur aus
-- der Ziehung ausgefiltert), damit song_pool nur noch tatsächlich
-- spielbare Songs enthält. Verbleibend: 2000er Old School 49, Deutschrap-
-- Songs 19, Shisha Club 29 -- alle noch ausreichend groß für Varianz.
-- ============================================================

BEGIN;

-- Verteidigung gegen einen seltenen Zeitpunkt-Zufall: falls doch gerade
-- eine laufende Lobby auf einen der zu löschenden Songs zeigt, den
-- FK-Verweis vorher lösen statt die Migration mit einem FK-Fehler
-- abzubrechen. _pick_next_song zieht beim nächsten Halterwechsel neu.
UPDATE public.lobbies
SET current_song_id = NULL
WHERE current_song_id IN (SELECT id FROM public.song_pool WHERE preview_url IS NULL);

DELETE FROM public.song_pool WHERE preview_url IS NULL;

COMMIT;
