-- ============================================================
-- Migration 040: Neue Musik-Kategorie "Shisha Club" (50 Songs)
-- ============================================================
-- Quelle: vom User per Spotify-Link geschickt ("Shisha Club", Cover
-- Shirin David/Summer Cem), Titel/Interpret 1:1 aus der Web-Player-
-- Tracklist übernommen (wie schon in Migration 033/039).
-- ============================================================

BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Shisha Club', true, true
WHERE NOT EXISTS (
    SELECT 1 FROM public.topic_pool WHERE text = 'Shisha Club'
);

INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Shisha Club', 'KILLY MANJARO', 'Summer Cem, BILLA JOE'),
    ('Shisha Club', 'BALOTELLI', 'THIZZY52'),
    ('Shisha Club', 'MO'' MONEY MO'' HATERS', 'Summer Cem, Shirin David'),
    ('Shisha Club', 'Sous la lune', 'Jul'),
    ('Shisha Club', 'STRASSE', 'Cave, Amo, Soufian'),
    ('Shisha Club', 'CDY', 'LACAZETTE, Jazeek'),
    ('Shisha Club', 'gimme luv <3', 'Luciano, Jazeek'),
    ('Shisha Club', 'Tränen', 'Makar'),
    ('Shisha Club', 'Berlin calling', 'Pashanim'),
    ('Shisha Club', 'GYALDEM', 'Jazeek, Luciano'),
    ('Shisha Club', 'Erinnerung', 'Dardan'),
    ('Shisha Club', 'GALLARDO', 'CANEY030'),
    ('Shisha Club', 'THUG LIFE', 'Luciano, Jazeek'),
    ('Shisha Club', 'Prada Sport', 'Pashanim, AK AUSSERKONTROLLE, Selim61'),
    ('Shisha Club', 'GEH VON HIER', 'Jamal'),
    ('Shisha Club', 'Sonne über Berlin', 'Capital Bra, Samra'),
    ('Shisha Club', 'Coupe', 'Coldyaa'),
    ('Shisha Club', 'Alors (feat. CAPO)', 'Kurdo, CAPO'),
    ('Shisha Club', 'Augenblick', 'Pashanim'),
    ('Shisha Club', 'WER BIST DU DENN?', 'Jazeek, Luciano'),
    ('Shisha Club', 'Ghetto Superstars', 'Samra, Capital Bra'),
    ('Shisha Club', 'Tonight', 'Mucco'),
    ('Shisha Club', 'GHETTOGIRL', 'CAPO'),
    ('Shisha Club', 'hotels & skylines', 'Lyno Nine8'),
    ('Shisha Club', 'Meine Welt', 'Eddin'),
    ('Shisha Club', 'LOVESICK', '6PM RECORDS, Sosa La M'),
    ('Shisha Club', 'Ballon d''Or', 'Sosa La M'),
    ('Shisha Club', 'Vermisse', 'Dardan, Azet'),
    ('Shisha Club', 'Que pasa', 'Aymo, Aymen, Amo'),
    ('Shisha Club', 'BANGBANGBANG', 'CANEY030'),
    ('Shisha Club', 'Xalaz', 'Yc'),
    ('Shisha Club', 'Lounge City', 'Pashanim'),
    ('Shisha Club', 'PARFUM', 'Jazeek, Shindy'),
    ('Shisha Club', 'Bleib stark', 'Aymo, Aymen, Amo'),
    ('Shisha Club', 'Love all night', 'Amo, Aymen'),
    ('Shisha Club', 'Glastisch', 'Makar'),
    ('Shisha Club', 'DRINNE', 'Summer Cem, CANEY030, JURI'),
    ('Shisha Club', 'Miami', 'Jazeek, reezy'),
    ('Shisha Club', 'COMEBACCC', 'reezy'),
    ('Shisha Club', 'Gold & Eis', 'Dorian'),
    ('Shisha Club', 'MON FRÈRE', 'THIZZY52'),
    ('Shisha Club', 'RMB (Ring My Bell) - German Remix', 'Aitch, BILLA JOE'),
    ('Shisha Club', 'KOMM NÄHER', 'Juju, RAF Camora'),
    ('Shisha Club', 'Nightmare', 'FXNN'),
    ('Shisha Club', 'Blackberry', 'RIN'),
    ('Shisha Club', 'Red Bull Weiss', 'Amo'),
    ('Shisha Club', 'FUXWAVE', 'Eno, KARDO'),
    ('Shisha Club', 'Mein Cutie <3', 'YUNG SAINT PAUL'),
    ('Shisha Club', 'BLN', 'AK AUSSERKONTROLLE, Pashanim'),
    ('Shisha Club', 'Sommernacht', 'Lucry & Suena, Azet')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

COMMIT;
