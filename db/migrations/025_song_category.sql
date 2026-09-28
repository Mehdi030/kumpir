-- ============================================================
-- Migration 025: Neue Kategorie "Deutschrap-Songs" (Song-Raten)
-- ============================================================
-- Nutzt die bestehende Topic-Mechanik B 1:1 -- keine neue Spalte,
-- kein neuer Modus, keine neue RPC. "Song erraten" ist einfach eine
-- weitere Zeile in topic_pool, genau wie "Filme" oder "Bekannte
-- YouTuber". Wird sie in der Themen-Wahl ausgelost, muss der Halter
-- einen Song aus der Kategorie nennen (per Text ODER per Spracheingabe
-- -- siehe apps/web/src/components/game/VoiceInput.tsx), die anderen
-- stimmen ab wie bei jedem anderen Thema.
--
-- Mix aus hochaktuellen (2025/2026) und bekannten/klassischen
-- Deutschrap-Songs, damit sowohl "Kenner" als auch Gelegenheitshörer
-- eine faire Chance haben.
--
-- Spotify-Playlist zur Einstimmung während der Runde (echte, öffentlich
-- erreichbare Playlist, per oEmbed verifiziert -- kein API-Key nötig):
-- "Deutschrap Charts 2026" von Redlist, open.spotify.com/playlist/5lJ1Ko6KMm9lTfdcngqNdA
-- Eingebunden in game/[code]/page.tsx, sichtbar wenn topic_selected
-- dieser Kategorie entspricht.
-- ============================================================

BEGIN;

INSERT INTO public.topic_pool (text, example, active)
SELECT v.text, v.example, TRUE
FROM (VALUES
    ('Deutschrap-Songs', 'Tequila')
) AS v(text, example)
WHERE NOT EXISTS (
    SELECT 1 FROM public.topic_pool WHERE lower(text) = lower(v.text)
);

COMMIT;
