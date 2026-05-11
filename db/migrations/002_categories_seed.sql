-- ============================================================
-- Migration 002: Topic-Kategorien (Seed in EXISTIERENDE topic_pool)
-- ============================================================
-- Deine DB hat schon eine `topic_pool`-Tabelle. Wir nutzen diese
-- statt eine neue topic_categories anzulegen. Wenn du sie noch leer
-- hast, wird sie hier mit 49 deutschen Kategorien gefüllt.
--
-- Idempotent: kann erneut ausgeführt werden, ohne Duplikate.
--
-- 🔎 Hinweis: Es gibt in deiner DB AUCH eine zweite Tabelle `topics`
--    (mit `name` statt `text`). Sobald du mir die Funktions-Definitionen
--    schickst (Query 2 aus HOW_TO_DUMP.md), klären wir welche der beiden
--    von rpc_begin_topic_vote genutzt wird, und die andere kann weg.
-- ============================================================

BEGIN;

-- Beispiel-Spalte ergänzen, falls noch nicht vorhanden
ALTER TABLE public.topic_pool
    ADD COLUMN IF NOT EXISTS example TEXT;


-- Idempotenter Seed: nur einfügen, wenn die Kategorie noch nicht da ist
-- (LOWER-Vergleich, damit "Automarken" nicht zweimal landet).
INSERT INTO public.topic_pool (text, example, active)
SELECT v.text, v.example, TRUE
FROM (VALUES
    ('Automarken',             'BMW'),
    ('Tiere in Afrika',        'Löwe'),
    ('Haustiere',              'Hund'),
    ('Fußball-Vereine',        'Bayern München'),
    ('Länder in Europa',       'Frankreich'),
    ('Hauptstädte',            'Berlin'),
    ('Obst',                   'Apfel'),
    ('Gemüse',                 'Karotte'),
    ('Farben',                 'Blau'),
    ('Filme',                  'Inception'),
    ('Serien',                 'Breaking Bad'),
    ('Musiker/Bands',          'Coldplay'),
    ('Schauspieler',           'Tom Hanks'),
    ('Berufe',                 'Arzt'),
    ('Körperteile',            'Knie'),
    ('Dinge in der Küche',     'Messer'),
    ('Dinge im Supermarkt',    'Brot'),
    ('Getränke',               'Cola'),
    ('Alkoholische Getränke',  'Bier'),
    ('Fast Food',              'Pizza'),
    ('Schulfächer',            'Mathe'),
    ('Sportarten',             'Tennis'),
    ('Musikinstrumente',       'Gitarre'),
    ('Bundesländer',           'Bayern'),
    ('Deutsche Städte',        'Hamburg'),
    ('Großstädte weltweit',    'Tokio'),
    ('Flüsse',                 'Rhein'),
    ('Berge',                  'Mount Everest'),
    ('Meere und Ozeane',       'Atlantik'),
    ('Comic-Helden',           'Spider-Man'),
    ('Disney-Filme',           'Frozen'),
    ('Videospiele',            'Mario Kart'),
    ('Fast-Food-Ketten',       'McDonalds'),
    ('Kleidungsstücke',        'Hose'),
    ('Schuh-Arten',            'Sneaker'),
    ('Wetter-Phänomene',       'Regen'),
    ('Blumen',                 'Rose'),
    ('Bäume',                  'Eiche'),
    ('Fahrzeuge',              'Bus'),
    ('Möbelstücke',            'Sofa'),
    ('Elektrogeräte',          'Toaster'),
    ('Smartphone-Hersteller',  'Samsung'),
    ('Soziale Medien',         'Instagram'),
    ('Bekannte YouTuber',      'MrBeast'),
    ('Kleidungsmarken',        'Nike'),
    ('Elektronik-Marken',      'Apple'),
    ('Deutsche Rapper',        'Capital Bra'),
    ('Kinderspiele',           'Verstecken'),
    ('Brettspiele',            'Monopoly'),
    ('Handwerks-Berufe',       'Tischler')
) AS v(text, example)
WHERE NOT EXISTS (
    SELECT 1 FROM public.topic_pool tp
    WHERE LOWER(tp.text) = LOWER(v.text)
);


-- Beispiel von bestehenden Reihen ohne example nachpflegen
UPDATE public.topic_pool tp
SET example = v.example
FROM (VALUES
    ('Automarken',             'BMW'),
    ('Tiere in Afrika',        'Löwe'),
    ('Haustiere',              'Hund')
    -- … (Liste oben kann der User bei Bedarf erweitern)
) AS v(text, example)
WHERE LOWER(tp.text) = LOWER(v.text)
  AND tp.example IS NULL;


-- ============================================================
-- Beispiel-Patch für rpc_begin_topic_vote
-- ============================================================
-- Zwei verschiedene aktive Kategorien zufällig wählen:
--
--   WITH picks AS (
--     SELECT text FROM public.topic_pool
--      WHERE active = TRUE
--      ORDER BY random()
--      LIMIT 2
--   )
--   SELECT
--     (array_agg(text))[1] AS topic_a,
--     (array_agg(text))[2] AS topic_b
--   INTO v_a, v_b
--   FROM picks;
--
--   UPDATE lobbies
--   SET topic_a = v_a,
--       topic_b = v_b,
--       phase = 'topic_vote',
--       topic_vote_started_at = NOW(),
--       topic_vote_ends_at = NOW() + interval '15 seconds'
--   WHERE id = p_lobby_id;
-- ============================================================


COMMIT;
