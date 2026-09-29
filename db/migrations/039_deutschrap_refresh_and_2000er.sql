-- ============================================================
-- Migration 039: "Deutschrap-Songs" komplett ersetzt (Spotify
-- "German Hip Hop Mix", 20 -> 50) + neue Kategorie "2000er Old
-- School" (Spotify "2000s Hip Hop R&B", 50 Songs)
-- ============================================================
-- Quelle: vom User per Spotify-Link geschickt und Titel/Interpret 1:1
-- aus der Web-Player-Tracklist übernommen (wie schon in Migration 033).
-- "2000er Old School": 2 offensichtlich fehlplatzierte, nicht-2000er
-- Tracks der (laut Playlist-Titel automatisch aktualisierten) Quelle
-- ausgelassen ("High Hopes 3000" von ROLE MODEL, "POP DAT THANG -
-- David Guetta Mix" von DaBaby -- beide klar 2020er-Künstler).
--
-- current_song_id zeigt per FK auf song_pool -- vor dem Löschen der
-- alten Deutschrap-Songs müssen eventuell noch darauf zeigende Lobbys
-- erst genullt werden (siehe Migration 033).
-- ============================================================

BEGIN;

-- Neue Kategorie anlegen, falls noch nicht vorhanden.
INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT '2000er Old School', true, true
WHERE NOT EXISTS (
    SELECT 1 FROM public.topic_pool WHERE text = '2000er Old School'
);

-- Alte "Deutschrap-Songs"-Zeilen ersetzen.
UPDATE public.lobbies l
SET current_song_id = NULL
FROM public.song_pool sp
JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id
WHERE l.current_song_id = sp.id
  AND tp.text = 'Deutschrap-Songs';

DELETE FROM public.song_pool sp
USING public.topic_pool tp
WHERE sp.topic_pool_id = tp.id
  AND tp.text = 'Deutschrap-Songs';

INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Deutschrap-Songs', 'Original', 'XATAR'),
    ('Deutschrap-Songs', 'M A S S I V 2026', 'Massiv, Basstard'),
    ('Deutschrap-Songs', 'Vollautomatik', 'Nimo, Hanybal'),
    ('Deutschrap-Songs', 'ACHRAF FREESTYLE', 'QZENG'),
    ('Deutschrap-Songs', 'Paralympics', 'JACE, Haiyti'),
    ('Deutschrap-Songs', 'Chabos wissen wer der Babo ist', 'Haftbefehl'),
    ('Deutschrap-Songs', 'Cage Fighter', 'Asche'),
    ('Deutschrap-Songs', 'HACIS (SHEIKHS)', 'BANGWHITE, X WAVE'),
    ('Deutschrap-Songs', 'Piatella', 'Yuyu19, Lucio101'),
    ('Deutschrap-Songs', 'BIS ES KLAPPT', 'Eurothug'),
    ('Deutschrap-Songs', '@#!', 'LACAZETTE, JR.'),
    ('Deutschrap-Songs', 'Lieb & Gefährlich', 'Brudi030'),
    ('Deutschrap-Songs', 'Pateks', 'Aymen, Eno'),
    ('Deutschrap-Songs', 'Arbeitsamt (feat. Abdï)', 'Amo, Celo & Abdi'),
    ('Deutschrap-Songs', 'Wieder erreichbar', 'XATAR, KALIM, SSIO'),
    ('Deutschrap-Songs', 'Click Clack', 'MP FRESHLY, Olli Banjo, the Kii'),
    ('Deutschrap-Songs', 'Generation Kanack', 'Manuellsen, Haftbefehl'),
    ('Deutschrap-Songs', 'Northside', 'Sosa La M'),
    ('Deutschrap-Songs', 'DopeGame', 'Sa4'),
    ('Deutschrap-Songs', 'Hasskick', 'OG LU, Wa22ermann'),
    ('Deutschrap-Songs', 'Kopfsache', 'Hoti'),
    ('Deutschrap-Songs', '385 aufm Tacho', 'Olexesh'),
    ('Deutschrap-Songs', 'Sternstunde', 'Anonym'),
    ('Deutschrap-Songs', 'Probleme', 'Aymen, Nimo'),
    ('Deutschrap-Songs', 'Begeistert', 'Tom Hengst'),
    ('Deutschrap-Songs', 'Nichts Gesehen', 'AchtVier, Vato'),
    ('Deutschrap-Songs', 'Kein Bereket', 'SIL3A, CAPO'),
    ('Deutschrap-Songs', 'Ich ficke dich', 'Haftbefehl, XATAR'),
    ('Deutschrap-Songs', 'Einbürgerungstest für schwererziehbare Migrantenkinder', 'SSIO, KALIM'),
    ('Deutschrap-Songs', 'SABR', 'Kolja Goldstein'),
    ('Deutschrap-Songs', 'PLAYBOY (ME GUSTA)', 'GOTTI, X WAVE'),
    ('Deutschrap-Songs', 'HASH COWBOYS', 'BABA BLANCA, Gio1neun, Big Keen19, CleanUp'),
    ('Deutschrap-Songs', 'City Gangs', 'Olexesh, Celo & Abdi'),
    ('Deutschrap-Songs', 'Independent', 'Keko-G, AK AUSSERKONTROLLE'),
    ('Deutschrap-Songs', 'Wolke 7', 'Gzuz'),
    ('Deutschrap-Songs', '2 Etagen', 'OG LU, Tom Hengst'),
    ('Deutschrap-Songs', 'RS7', 'Amo, Soufian'),
    ('Deutschrap-Songs', 'STILL STANDING', 'AZAD, BOJAN, Vega, CALO'),
    ('Deutschrap-Songs', '500', 'Coup, Haftbefehl, XATAR'),
    ('Deutschrap-Songs', 'Stadtrundfahrt', 'KALIM'),
    ('Deutschrap-Songs', 'Alles kaputt', 'Capital Bra'),
    ('Deutschrap-Songs', 'MEHR LV (ALS LV)', 'KARDO, X WAVE'),
    ('Deutschrap-Songs', 'Hass im Bauch', 'O.G., Bora'),
    ('Deutschrap-Songs', 'MARBELLA', 'PAPKE'),
    ('Deutschrap-Songs', 'Jeden Tag - A COLORS SHOW', 'THIZZY52, COLORS'),
    ('Deutschrap-Songs', 'Plantage', 'Mustihussle, DeeVoe'),
    ('Deutschrap-Songs', 'AMG', 'NGEE'),
    ('Deutschrap-Songs', 'Keiner', 'Soufian, SOTT'),
    ('Deutschrap-Songs', 'A.S.S.N.', 'AK AUSSERKONTROLLE'),
    ('Deutschrap-Songs', 'Depressionen im Ghetto', 'Haftbefehl, Bazzazian'),

    ('2000er Old School', 'In Da Club', '50 Cent'),
    ('2000er Old School', 'Mockingbird', 'Eminem'),
    ('2000er Old School', 'Family Affair', 'Mary J. Blige'),
    ('2000er Old School', 'Without Me', 'Eminem'),
    ('2000er Old School', 'Smack That', 'Akon, Eminem'),
    ('2000er Old School', 'Lose Yourself', 'Eminem'),
    ('2000er Old School', 'Low (feat. T-Pain)', 'Flo Rida, T-Pain'),
    ('2000er Old School', 'Where Is The Love?', 'Black Eyed Peas'),
    ('2000er Old School', 'Empire State Of Mind', 'JAY-Z, Alicia Keys'),
    ('2000er Old School', 'You', 'Lloyd, Lil Wayne'),
    ('2000er Old School', 'Don''t Matter', 'Akon'),
    ('2000er Old School', 'Yeah! (feat. Lil Jon & Ludacris)', 'Usher, Lil Jon, Ludacris'),
    ('2000er Old School', 'Crazy In Love (feat. JAY-Z)', 'Beyoncé, JAY-Z'),
    ('2000er Old School', 'Take A Bow', 'Rihanna'),
    ('2000er Old School', 'Dilemma', 'Nelly, Kelly Rowland'),
    ('2000er Old School', 'You Like That', 'Chris Brown'),
    ('2000er Old School', 'Candy Shop', '50 Cent, Olivia'),
    ('2000er Old School', '(When You Gonna) Give It Up to Me', 'Sean Paul, Keyshia Cole'),
    ('2000er Old School', 'Hey Daddy (Daddy''s Home)', 'Usher'),
    ('2000er Old School', 'I Wanna Love You', 'Akon, Snoop Dogg'),
    ('2000er Old School', 'The Real Slim Shady', 'Eminem'),
    ('2000er Old School', 'So Sick', 'Ne-Yo'),
    ('2000er Old School', 'Let Me Love You', 'Mario'),
    ('2000er Old School', 'No One', 'Alicia Keys'),
    ('2000er Old School', 'Ayo Technology', '50 Cent, Justin Timberlake, Timbaland'),
    ('2000er Old School', 'Superman', 'Eminem, Dina Rae'),
    ('2000er Old School', 'Lollipop', 'Lil Wayne, Static Major'),
    ('2000er Old School', 'When I See U', 'Fantasia'),
    ('2000er Old School', 'I Know What You Want', 'Busta Rhymes, Mariah Carey, Flipmode Squad'),
    ('2000er Old School', 'Miss Independent', 'Ne-Yo'),
    ('2000er Old School', 'We Belong Together', 'Mariah Carey'),
    ('2000er Old School', 'Stan', 'Eminem, Dido'),
    ('2000er Old School', 'Move Ya Body', 'Nina Sky, Jabba'),
    ('2000er Old School', 'Many Men (Wish Death)', '50 Cent'),
    ('2000er Old School', 'Always On Time', 'Ja Rule, Ashanti'),
    ('2000er Old School', 'Stickwitu', 'The Pussycat Dolls'),
    ('2000er Old School', '21 Questions', '50 Cent, Nate Dogg'),
    ('2000er Old School', 'I Wonder', 'Kanye West'),
    ('2000er Old School', 'Love', 'Keyshia Cole'),
    ('2000er Old School', 'Obsessed', 'Mariah Carey'),
    ('2000er Old School', 'Hate It Or Love It', 'The Game, 50 Cent'),
    ('2000er Old School', '''Till I Collapse', 'Eminem, Nate Dogg'),
    ('2000er Old School', 'What''s Luv? (feat. Ashanti)', 'Fat Joe, Ashanti'),
    ('2000er Old School', 'Right Round (feat. Ke$ha)', 'Flo Rida, Kesha'),
    ('2000er Old School', 'P.I.M.P.', '50 Cent, Snoop Dogg'),
    ('2000er Old School', 'Dangerous', 'Kardinal Offishall, Akon'),
    ('2000er Old School', 'Best Friend', '50 Cent, Olivia'),
    ('2000er Old School', 'Shut Up', 'Black Eyed Peas'),
    ('2000er Old School', 'Kiss Me Thru The Phone', 'Soulja Boy, Sammie'),
    ('2000er Old School', 'Bartender (feat. Akon)', 'T-Pain, Akon')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

COMMIT;
