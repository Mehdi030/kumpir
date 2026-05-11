-- ============================================================
-- Migration 002: Topic-Kategorien (Seed)
-- ============================================================
-- Legt die Tabelle `topic_categories` an und füllt sie mit dem
-- Inhalt aus `game-logic/content/questions_de.json`.
--
-- `rpc_begin_topic_vote` muss angepasst werden, damit topic_a und
-- topic_b zufällig aus dieser Tabelle gezogen werden:
--
--   SELECT label INTO v_a FROM topic_categories ORDER BY random() LIMIT 1;
--   SELECT label INTO v_b FROM topic_categories
--     WHERE label <> v_a ORDER BY random() LIMIT 1;
--
-- Wenn `questions_de.json` aktualisiert wird, muss diese Migration
-- als eigene Folge-Migration neu geseedet werden (UPSERT siehe unten).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Tabelle: topic_categories
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.topic_categories (
    id          TEXT PRIMARY KEY,            -- z.B. 'automarken'
    label       TEXT NOT NULL,               -- z.B. 'Automarken'
    example     TEXT,                        -- z.B. 'BMW'
    locale      TEXT NOT NULL DEFAULT 'de',
    enabled     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_topic_categories_enabled
    ON public.topic_categories (enabled, locale);


-- ------------------------------------------------------------
-- Seed (UPSERT — idempotent, kann sicher erneut ausgeführt werden)
-- ------------------------------------------------------------
INSERT INTO public.topic_categories (id, label, example, locale, enabled) VALUES
    ('automarken',           'Automarken',                'BMW',             'de', TRUE),
    ('tiere_afrika',         'Tiere in Afrika',           'Löwe',            'de', TRUE),
    ('haustiere',            'Haustiere',                 'Hund',            'de', TRUE),
    ('fussball_vereine',     'Fußball-Vereine',           'Bayern München',  'de', TRUE),
    ('laender_europa',       'Länder in Europa',          'Frankreich',      'de', TRUE),
    ('hauptstaedte',         'Hauptstädte',               'Berlin',          'de', TRUE),
    ('obst',                 'Obst',                      'Apfel',           'de', TRUE),
    ('gemuese',              'Gemüse',                    'Karotte',         'de', TRUE),
    ('farben',               'Farben',                    'Blau',            'de', TRUE),
    ('filme',                'Filme',                     'Inception',       'de', TRUE),
    ('serien',               'Serien',                    'Breaking Bad',    'de', TRUE),
    ('musiker',              'Musiker/Bands',             'Coldplay',        'de', TRUE),
    ('schauspieler',         'Schauspieler',              'Tom Hanks',       'de', TRUE),
    ('berufe',               'Berufe',                    'Arzt',            'de', TRUE),
    ('koerperteile',         'Körperteile',               'Knie',            'de', TRUE),
    ('kueche',               'Dinge in der Küche',        'Messer',          'de', TRUE),
    ('supermarkt',           'Dinge im Supermarkt',       'Brot',            'de', TRUE),
    ('getraenke',            'Getränke',                  'Cola',            'de', TRUE),
    ('alkohol',              'Alkoholische Getränke',     'Bier',            'de', TRUE),
    ('fastfood',             'Fast Food',                 'Pizza',           'de', TRUE),
    ('schule',               'Schulfächer',               'Mathe',           'de', TRUE),
    ('sportarten',           'Sportarten',                'Tennis',          'de', TRUE),
    ('instrumente',          'Musikinstrumente',          'Gitarre',         'de', TRUE),
    ('bundeslaender',        'Bundesländer',              'Bayern',          'de', TRUE),
    ('deutsche_staedte',     'Deutsche Städte',           'Hamburg',         'de', TRUE),
    ('weltstaedte',          'Großstädte weltweit',       'Tokio',           'de', TRUE),
    ('fluesse',              'Flüsse',                    'Rhein',           'de', TRUE),
    ('berge',                'Berge',                     'Mount Everest',   'de', TRUE),
    ('meere',                'Meere und Ozeane',          'Atlantik',        'de', TRUE),
    ('comic_helden',         'Comic-Helden',              'Spider-Man',      'de', TRUE),
    ('disney_filme',         'Disney-Filme',              'Frozen',          'de', TRUE),
    ('videospiele',          'Videospiele',               'Mario Kart',      'de', TRUE),
    ('fast_food_ketten',     'Fast-Food-Ketten',          'McDonalds',       'de', TRUE),
    ('kleidung',             'Kleidungsstücke',           'Hose',            'de', TRUE),
    ('schuhe',               'Schuh-Arten',               'Sneaker',         'de', TRUE),
    ('wetter',               'Wetter-Phänomene',          'Regen',           'de', TRUE),
    ('blumen',               'Blumen',                    'Rose',            'de', TRUE),
    ('baeume',               'Bäume',                     'Eiche',           'de', TRUE),
    ('fahrzeuge',            'Fahrzeuge',                 'Bus',             'de', TRUE),
    ('moebel',               'Möbelstücke',               'Sofa',            'de', TRUE),
    ('elektrogeraete',       'Elektrogeräte',             'Toaster',         'de', TRUE),
    ('smartphones',          'Smartphone-Hersteller',     'Samsung',         'de', TRUE),
    ('soziale_medien',       'Soziale Medien',            'Instagram',       'de', TRUE),
    ('bekannte_youtuber',    'Bekannte YouTuber',         'MrBeast',         'de', TRUE),
    ('marken_kleidung',      'Kleidungsmarken',           'Nike',            'de', TRUE),
    ('marken_elektronik',    'Elektronik-Marken',         'Apple',           'de', TRUE),
    ('deutsche_rapper',      'Deutsche Rapper',           'Capital Bra',     'de', TRUE),
    ('kinder_spiele',        'Kinderspiele',              'Verstecken',      'de', TRUE),
    ('brettspiele',          'Brettspiele',               'Monopoly',        'de', TRUE),
    ('berufe_handwerk',      'Handwerks-Berufe',          'Tischler',        'de', TRUE)
ON CONFLICT (id) DO UPDATE
    SET label = EXCLUDED.label,
        example = EXCLUDED.example,
        enabled = EXCLUDED.enabled;


-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------
ALTER TABLE public.topic_categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "topic_categories_read_all"
    ON public.topic_categories
    FOR SELECT
    USING (TRUE);


COMMIT;
