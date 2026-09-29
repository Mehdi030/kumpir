-- ============================================================
-- Migration 033: Song-Pool "Deutschrap-Songs" + "Internationale
-- Pop-Charts" auf aktuelle Charts (Stand September 2026) aktualisiert
-- ============================================================
-- Feedback: die Songs in diesen zwei Kategorien waren teils Jahre alt
-- (z.B. "Tequila", "Wolke 10", "Roller" -- 2016-2020er Bonez MC/RAF
-- Camora/Apache207-Ära). Das ist bei "Deutschrap Klassiker" und
-- "Englische All-Time-Hits" GEWOLLT (die Kategorien heißen absichtlich
-- so), aber "Deutschrap-Songs" und "Internationale Pop-Charts" sollen
-- die aktuell laufenden Charts abbilden.
--
-- Quelle: mix1.de Hip-Hop Single-Charts (Woche 39/2026) für Deutschrap,
-- Billboard Hot 100 (aktuelle Top 10 + 2026er Nr.-1-Hits) für Pop.
-- Titel/Interpret 1:1 aus den Charts übernommen -- iTunes-Suche findet
-- aktuelle Chart-Hits erfahrungsgemäß zuverlässig, im Zweifel liefert
-- SongRound.tsx dann einfach keinen Preview (kein Absturz, siehe dort).
--
-- current_song_id zeigt per FK auf song_pool -- vor dem Löschen alter
-- Zeilen müssen eventuell noch darauf zeigende Lobbys (alte, meist
-- längst beendete Test-Runden) erst genullt werden, sonst schlägt der
-- DELETE mit einer FK-Verletzung fehl.
-- ============================================================

BEGIN;

UPDATE public.lobbies l
SET current_song_id = NULL
FROM public.song_pool sp
JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id
WHERE l.current_song_id = sp.id
  AND tp.text IN ('Deutschrap-Songs', 'Internationale Pop-Charts');

DELETE FROM public.song_pool sp
USING public.topic_pool tp
WHERE sp.topic_pool_id = tp.id
  AND tp.text IN ('Deutschrap-Songs', 'Internationale Pop-Charts');

INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Deutschrap-Songs', 'Issa', 'Sido'),
    ('Deutschrap-Songs', 'Gut Genug', 'KITSCHKRIEG, Blumengarten & Shirin David'),
    ('Deutschrap-Songs', 'Killy Manjaro', 'Summer Cem & Billa Joe'),
    ('Deutschrap-Songs', 'Woke', 'Sido'),
    ('Deutschrap-Songs', 'Mo'' Money Mo'' Haters', 'Summer Cem & Shirin David'),
    ('Deutschrap-Songs', 'War nie weg', 'Ufo361 feat. Souly & Blumengarten'),
    ('Deutschrap-Songs', 'Chaos', 'Apache 207'),
    ('Deutschrap-Songs', 'Biertornado', 'PA69'),
    ('Deutschrap-Songs', 'Der Sonne immer näher', 'Tream x Bausa'),
    ('Deutschrap-Songs', 'Böse Jungs', 'Capital Bra, Samra & Lacazette'),
    ('Deutschrap-Songs', 'Allein', 'Juju'),
    ('Deutschrap-Songs', 'Wer bist du denn?', 'Jazeek & Luciano'),
    ('Deutschrap-Songs', 'Augenblick', 'Pashanim'),
    ('Deutschrap-Songs', 'Sonne über Berlin', 'Capital Bra & Samra'),
    ('Deutschrap-Songs', 'Verschwommen', 'Ski Aggu'),
    ('Deutschrap-Songs', 'Geile Sau trotzdem', 'badmómzjay & IKKIMEL'),
    ('Deutschrap-Songs', 'Ghetto Superstars', 'Samra & Capital Bra'),
    ('Deutschrap-Songs', 'BLN', 'Lacazette, Gangsta Ralph & Sido feat. DJ Desue'),
    ('Deutschrap-Songs', 'Pablo', 'Dardan & Azet'),
    ('Deutschrap-Songs', 'Berlin Calling', 'Pashanim'),

    ('Internationale Pop-Charts', 'Choosin'' Texas', 'Ella Langley'),
    ('Internationale Pop-Charts', 'Boston', 'Stella Lefty'),
    ('Internationale Pop-Charts', 'Been By Now', 'Morgan Wallen'),
    ('Internationale Pop-Charts', 'The Fate of Ophelia', 'Taylor Swift'),
    ('Internationale Pop-Charts', 'I Just Might', 'Bruno Mars'),
    ('Internationale Pop-Charts', 'Aperture', 'Harry Styles'),
    ('Internationale Pop-Charts', 'DTMF', 'Bad Bunny'),
    ('Internationale Pop-Charts', 'Opalite', 'Taylor Swift'),
    ('Internationale Pop-Charts', 'Swim', 'BTS'),
    ('Internationale Pop-Charts', 'Drop Dead', 'Olivia Rodrigo'),
    ('Internationale Pop-Charts', 'Janice STFU', 'Drake'),
    ('Internationale Pop-Charts', 'Hate That I Made You Love Me', 'Ariana Grande'),
    ('Internationale Pop-Charts', 'I Knew It, I Knew You', 'Taylor Swift')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

COMMIT;
