-- ============================================================
-- KUMPIR — Alle 35 Migrationen in einem File
-- ============================================================
-- Einmal komplett kopieren, in Supabase SQL Editor einfügen, Run.
-- Jede Sub-Migration ist idempotent — du kannst das File mehrfach laufen lassen.
-- ============================================================


-- ============================================================
-- 001_topic_validation.sql
-- ============================================================
-- ============================================================
-- Migration 001: Topic-Mechanik B (Validierung)
-- ============================================================
-- Erweitert das Gameplay um:
--   - Halter muss eine ANTWORT zum Thema sagen, bevor er passt
--   - Andere Spieler validieren per "✅ gilt" / "❌ gilt nicht" Button
--   - Bei Mehrheit gilt-nicht → Pass wird BLOCKIERT (Halter muss neu sagen)
--   - Antwort wird im Server gespeichert (Anti-Doppelnennung)
--
-- Strategie:
--   - Neue Tabelle `pass_attempts` für laufende Antwort-Versuche
--   - Neue Spalte `lobbies.current_attempt_id` zeigt auf aktiven Versuch
--   - Neue Tabelle `pass_attempt_votes` für die "gilt / gilt nicht" Stimmen
--   - rpc_pass_potato bekommt einen optionalen `p_answer` Parameter
--   - Neue RPCs: rpc_vote_answer, rpc_finalize_answer
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Tabelle: pass_attempts
-- ------------------------------------------------------------
-- Repräsentiert "Spieler X versucht zu passen mit Antwort Y".
-- Bleibt offen bis: Mehrheit hat abgestimmt ODER Zeit-Cutoff.
CREATE TABLE IF NOT EXISTS public.pass_attempts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lobby_id            UUID NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
    round_number        INTEGER NOT NULL,
    holder_player_id    UUID NOT NULL,
    answer              TEXT NOT NULL,
    topic               TEXT NOT NULL,        -- selected topic at time of attempt

    -- Validierungs-Status
    status              TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'accepted' | 'rejected' | 'timeout'
    accept_count        INTEGER NOT NULL DEFAULT 0,
    reject_count        INTEGER NOT NULL DEFAULT 0,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_pass_attempts_lobby
    ON public.pass_attempts (lobby_id, status);


-- ------------------------------------------------------------
-- Tabelle: pass_attempt_votes
-- ------------------------------------------------------------
-- Jeder lebende Spieler (außer Halter) stimmt einmal mit accept=true/false.
CREATE TABLE IF NOT EXISTS public.pass_attempt_votes (
    attempt_id  UUID NOT NULL REFERENCES public.pass_attempts(id) ON DELETE CASCADE,
    voter_id    UUID NOT NULL,
    accept      BOOLEAN NOT NULL,
    voted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (attempt_id, voter_id)
);


-- ------------------------------------------------------------
-- Spalte: lobbies.current_attempt_id
-- ------------------------------------------------------------
-- Zeigt auf den aktuell offenen pass_attempt (NULL = keiner offen).
ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS current_attempt_id UUID
        REFERENCES public.pass_attempts(id) ON DELETE SET NULL;


-- ------------------------------------------------------------
-- Spalte: lobbies.used_answers (verhindert Doppelnennungen pro Runde)
-- ------------------------------------------------------------
-- Beispiel: ["BMW", "Audi", "Mercedes"] — alle bereits genannten Antworten
-- der aktuellen Runde. Wird beim Rundenstart geleert.
ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS used_answers TEXT[] NOT NULL DEFAULT '{}';


-- ============================================================
-- RPC: rpc_attempt_pass
-- ============================================================
-- Statt direkt rpc_pass_potato aufzurufen, ruft der Halter erst diese RPC
-- mit seiner Antwort auf. Sie:
--   - Prüft: phase = running, holder = caller, kein offener Attempt
--   - Prüft: Antwort noch nicht in used_answers
--   - Erzeugt pass_attempt mit status = 'pending'
--   - Setzt lobbies.current_attempt_id
--
-- Returns: attempt_id UUID
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT,
    p_player_id UUID,
    p_answer TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_lobby     public.lobbies%ROWTYPE;
    v_attempt   UUID;
    v_clean     TEXT;
BEGIN
    -- Lobby holen
    SELECT * INTO v_lobby FROM public.lobbies WHERE code = UPPER(p_code) FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'lobby_not_found';
    END IF;

    IF v_lobby.phase <> 'running' THEN
        RAISE EXCEPTION 'lobby_not_running';
    END IF;

    IF v_lobby.holder_player_id <> p_player_id THEN
        RAISE EXCEPTION 'not_holder';
    END IF;

    IF v_lobby.current_attempt_id IS NOT NULL THEN
        RAISE EXCEPTION 'attempt_already_open';
    END IF;

    -- Antwort normalisieren (trim, lowercase für Vergleich, aber Original behalten)
    v_clean := TRIM(p_answer);
    IF LENGTH(v_clean) = 0 THEN
        RAISE EXCEPTION 'empty_answer';
    END IF;
    IF LENGTH(v_clean) > 60 THEN
        RAISE EXCEPTION 'answer_too_long';
    END IF;

    -- Doppelnennung prüfen (case-insensitive)
    IF EXISTS (
        SELECT 1 FROM unnest(v_lobby.used_answers) AS used
        WHERE LOWER(used) = LOWER(v_clean)
    ) THEN
        RAISE EXCEPTION 'answer_already_used';
    END IF;

    -- Attempt anlegen
    INSERT INTO public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
        VALUES (v_lobby.id, COALESCE(v_lobby.round_number, 0), p_player_id, v_clean, COALESCE(v_lobby.topic_selected, v_lobby.topic, ''))
        RETURNING id INTO v_attempt;

    UPDATE public.lobbies SET current_attempt_id = v_attempt WHERE id = v_lobby.id;

    RETURN v_attempt;
END;
$$;


-- ============================================================
-- RPC: rpc_vote_answer
-- ============================================================
-- Jeder lebende Spieler (außer Halter) gibt sein Urteil ab.
-- Bei Mehrheit von >50% accept → status = 'accepted', triggers rpc_pass_potato
-- intern und fügt Antwort zu used_answers.
-- Bei Mehrheit von >=50% reject → status = 'rejected', current_attempt_id = NULL.
CREATE OR REPLACE FUNCTION public.rpc_vote_answer(
    p_attempt_id UUID,
    p_voter_id UUID,
    p_accept BOOLEAN
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_attempt   public.pass_attempts%ROWTYPE;
    v_alive     INTEGER;
    v_needed    INTEGER;
BEGIN
    SELECT * INTO v_attempt FROM public.pass_attempts WHERE id = p_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'attempt_not_found';
    END IF;

    IF v_attempt.status <> 'pending' THEN
        RAISE EXCEPTION 'attempt_closed';
    END IF;

    IF v_attempt.holder_player_id = p_voter_id THEN
        RAISE EXCEPTION 'holder_cannot_vote';
    END IF;

    -- Vote einfügen (idempotent: kann nicht zweimal)
    INSERT INTO public.pass_attempt_votes (attempt_id, voter_id, accept)
        VALUES (p_attempt_id, p_voter_id, p_accept)
        ON CONFLICT (attempt_id, voter_id) DO NOTHING;

    -- Counts aktualisieren
    UPDATE public.pass_attempts
    SET accept_count = (SELECT COUNT(*) FROM public.pass_attempt_votes WHERE attempt_id = p_attempt_id AND accept = TRUE),
        reject_count = (SELECT COUNT(*) FROM public.pass_attempt_votes WHERE attempt_id = p_attempt_id AND accept = FALSE)
    WHERE id = p_attempt_id
    RETURNING * INTO v_attempt;

    -- Wieviele lebende Spieler außer Halter gibt es?
    SELECT COUNT(*) INTO v_alive
    FROM public.players
    WHERE lobby_id = v_attempt.lobby_id
      AND status = 'active'
      AND is_alive = TRUE
      AND player_id <> v_attempt.holder_player_id;

    -- Mehrheit (mehr als die Hälfte aller Voter)
    v_needed := (v_alive / 2) + 1;

    IF v_attempt.accept_count >= v_needed THEN
        -- Akzeptiert: pass durchführen
        PERFORM public._finalize_attempt_accept(v_attempt.id);
    ELSIF v_attempt.reject_count >= v_needed THEN
        -- Abgelehnt: attempt schließen, Halter muss neu sagen
        PERFORM public._finalize_attempt_reject(v_attempt.id);
    END IF;
END;
$$;


-- ============================================================
-- Helper: Attempt akzeptieren → Pass ausführen
-- ============================================================
CREATE OR REPLACE FUNCTION public._finalize_attempt_accept(p_attempt_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_attempt   public.pass_attempts%ROWTYPE;
    v_lobby     public.lobbies%ROWTYPE;
    v_code      TEXT;
BEGIN
    SELECT * INTO v_attempt FROM public.pass_attempts WHERE id = p_attempt_id;
    SELECT * INTO v_lobby FROM public.lobbies WHERE id = v_attempt.lobby_id;
    v_code := v_lobby.code;

    UPDATE public.pass_attempts
    SET status = 'accepted', decided_at = NOW()
    WHERE id = p_attempt_id;

    UPDATE public.lobbies
    SET current_attempt_id = NULL,
        used_answers = array_append(used_answers, v_attempt.answer)
    WHERE id = v_lobby.id;

    -- Bestehende rpc_pass_potato hält die Logik (next holder, stats etc.)
    PERFORM public.rpc_pass_potato(v_code, v_attempt.holder_player_id);
END;
$$;


-- ============================================================
-- Helper: Attempt ablehnen
-- ============================================================
CREATE OR REPLACE FUNCTION public._finalize_attempt_reject(p_attempt_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.pass_attempts SET status = 'rejected', decided_at = NOW() WHERE id = p_attempt_id;

    UPDATE public.lobbies
    SET current_attempt_id = NULL
    WHERE current_attempt_id = p_attempt_id;
END;
$$;


-- ============================================================
-- Wichtig: Bestehende rpc_pass_potato + rpc_advance_from_countdown
-- müssen angepasst werden, damit used_answers gecleart wird bei Rundenstart.
-- Beispiel:
--
--   UPDATE lobbies
--   SET used_answers = '{}',
--       current_attempt_id = NULL
--   WHERE id = p_lobby_id;
--
-- Sowie: rpc_pass_potato muss von _finalize_attempt_accept aus aufgerufen
-- werden können — wenn deine bestehende Version den Halter validiert, kann
-- das fehlschlagen. Ggf. einen internen Helper extrahieren.
-- ============================================================


-- ------------------------------------------------------------
-- RLS für die neuen Tabellen
-- ------------------------------------------------------------
ALTER TABLE public.pass_attempts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pass_attempts_read_all" ON public.pass_attempts;
CREATE POLICY "pass_attempts_read_all" ON public.pass_attempts FOR SELECT USING (TRUE);

ALTER TABLE public.pass_attempt_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pass_attempt_votes_read_all" ON public.pass_attempt_votes;
CREATE POLICY "pass_attempt_votes_read_all" ON public.pass_attempt_votes FOR SELECT USING (TRUE);


COMMIT;


-- ============================================================
-- 002_categories_seed.sql
-- ============================================================
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


-- ============================================================
-- 003_fix_rematch_topic_source.sql
-- ============================================================
-- ============================================================
-- Migration 003: Bug-Fix — rpc_start_rematch_if_ready nutzt topics statt topic_pool
-- ============================================================
-- Aktueller Zustand: zwei Funktionen ziehen Topics aus VERSCHIEDENEN Tabellen:
--   - rpc_begin_topic_vote → topic_pool (text-Spalte)
--   - rpc_start_rematch_if_ready → topics (name-Spalte)
--
-- Wenn topics leer ist (was bei dir vermutlich der Fall ist, weil dein
-- Frontend nur topic_pool nutzt), schmeißt der Rematch eine Exception:
--   "Nicht genug aktive Themen vorhanden"
--
-- Diese Migration richtet rpc_start_rematch_if_ready darauf aus, ebenfalls
-- topic_pool zu nutzen — damit ist nur eine Quelle der Wahrheit.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_ready_count int;
  v_active_count int;
  v_topic_a text;
  v_topic_b text;
begin
  select id into v_lobby_id
  from public.lobbies
  where code = upper(trim(p_code))
  limit 1;

  if v_lobby_id is null then
    raise exception 'Lobby nicht gefunden';
  end if;

  select count(*) into v_active_count
  from public.players
  where lobby_id = v_lobby_id
    and status = 'active';

  select count(*) into v_ready_count
  from public.players
  where lobby_id = v_lobby_id
    and status = 'active'
    and coalesce(ready, false) = true;

  if v_active_count < 2 then
    raise exception 'Mindestens 2 aktive Spieler nötig';
  end if;

  if v_ready_count <> v_active_count then
    return;
  end if;

  -- ✅ FIX: nutze topic_pool (gleiche Quelle wie rpc_begin_topic_vote)
  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true
  order by random()
  limit 1;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true
    and t.text <> v_topic_a
  order by random()
  limit 1;

  if v_topic_a is null or v_topic_b is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  delete from public.topic_votes
  where lobby_id = v_lobby_id;

  update public.players
  set ready = false
  where lobby_id = v_lobby_id
    and status = 'active';

  update public.lobbies
  set
    phase = 'topic_vote',
    topic_a = v_topic_a,
    topic_b = v_topic_b,
    topic_selected = null,
    topic_vote_started_at = now(),
    topic_vote_ends_at = now() + interval '10 seconds',
    countdown_started_at = null,
    countdown_ends_at = null,
    topic_tie_choices = null,
    topic_tie_pick = null,
    holder_player_id = null,
    explode_at = null,
    run_started_at = null,
    last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Optional: alte `topics`-Tabelle löschen, wenn sie nicht mehr genutzt wird.
-- Bitte ERST prüfen, dass keine andere Funktion topics referenziert:
--
--   SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND pg_get_functiondef(p.oid) LIKE '%public.topics%';
--
-- Wenn nur rpc_start_rematch_if_ready in der Liste war (und du diese Migration
-- angewendet hast), kannst du gefahrlos:
--
--   DROP TABLE IF EXISTS public.topics;
-- ============================================================


-- ============================================================
-- 004_auth_link_optional.sql
-- ============================================================
-- ============================================================
-- Migration 004: Auth opt-in — user_id mit Lobby/Player verknüpfen
-- ============================================================
-- Erweitert rpc_create_lobby + rpc_join_lobby um optionalen p_user_id Parameter.
-- Wenn übergeben, wird er an lobbies.host_user_id bzw. players.user_id gehängt.
-- Wenn weggelassen (Gast-Modus, alter Aufruf), bleibt es bei NULL — kein Breaking Change.
--
-- Idempotent: CREATE OR REPLACE.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- rpc_create_lobby (mit optionalem p_user_id)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_lobby(
    p_host_name TEXT,
    p_privacy TEXT,
    p_max_players INTEGER,
    p_round_seconds INTEGER,
    p_user_id UUID DEFAULT NULL
) RETURNS TABLE(code TEXT, host_player_id UUID)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_lobby_id UUID := gen_random_uuid();
    v_code TEXT;
    v_host_player_id UUID := gen_random_uuid();
BEGIN
    v_code := public.generate_lobby_code(4);

    INSERT INTO public.lobbies (
        id, code, host_player_id, status, privacy, max_players, round_seconds,
        created_at, last_activity_at, host_user_id
    )
    VALUES (
        v_lobby_id,
        UPPER(v_code),
        v_host_player_id,
        'waiting',
        p_privacy,
        GREATEST(2, LEAST(p_max_players, 12)),
        COALESCE(p_round_seconds, 25),
        NOW(),
        NOW(),
        p_user_id
    );

    INSERT INTO public.players (
        id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id
    )
    VALUES (
        gen_random_uuid(),
        v_lobby_id,
        v_host_player_id,
        LEFT(TRIM(p_host_name), 24),
        false,
        NOW(),
        NOW(),
        p_user_id
    );

    RETURN QUERY SELECT UPPER(v_code), v_host_player_id;
END;
$$;


-- ------------------------------------------------------------
-- rpc_join_lobby (mit optionalem p_user_id)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_join_lobby(
    p_code TEXT,
    p_player_id UUID,
    p_name TEXT,
    p_user_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_lobby_id UUID;
    v_locked BOOLEAN;
    v_max_players INT;
    v_active_count INT;
    v_next_seat INT;
BEGIN
    SELECT id, locked, max_players
        INTO v_lobby_id, v_locked, v_max_players
    FROM public.lobbies
    WHERE UPPER(code) = UPPER(p_code)
    LIMIT 1;

    IF v_lobby_id IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
    IF v_locked THEN RAISE EXCEPTION 'lobby_locked'; END IF;

    SELECT COUNT(*) INTO v_active_count
    FROM public.players
    WHERE lobby_id = v_lobby_id AND status = 'active';

    IF v_active_count >= v_max_players THEN RAISE EXCEPTION 'lobby_full'; END IF;

    -- Wenn dieser user_id schon mit anderem player_id in der Lobby ist,
    -- diesen Spieler reaktivieren statt neuen anlegen (Cross-Device-Sync).
    IF p_user_id IS NOT NULL THEN
        UPDATE public.players
        SET name = LEFT(TRIM(p_name), 24),
            status = 'active',
            left_at = NULL,
            kicked_at = NULL,
            last_seen_at = NOW()
        WHERE lobby_id = v_lobby_id
          AND user_id = p_user_id;

        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    -- Next seat
    SELECT COALESCE(MIN(s.i), 0) INTO v_next_seat
    FROM generate_series(0, v_max_players - 1) AS s(i)
    LEFT JOIN public.players p
        ON p.lobby_id = v_lobby_id
       AND p.seat_index = s.i
       AND p.status = 'active'
    WHERE p.id IS NULL;

    INSERT INTO public.players (
        lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at, user_id
    )
    VALUES (
        v_lobby_id,
        p_player_id,
        LEFT(TRIM(p_name), 24),
        'active',
        v_next_seat,
        NOW(),
        NOW(),
        p_user_id
    )
    ON CONFLICT (lobby_id, player_id)
    DO UPDATE SET
        name = EXCLUDED.name,
        status = 'active',
        left_at = NULL,
        kicked_at = NULL,
        last_seen_at = NOW(),
        seat_index = COALESCE(public.players.seat_index, EXCLUDED.seat_index),
        user_id = COALESCE(public.players.user_id, EXCLUDED.user_id);
END;
$$;

COMMIT;


-- ============================================================
-- 005_achievements.sql
-- ============================================================
-- ============================================================
-- Migration 005: Achievements + Lifetime-Stats
-- ============================================================
-- Was wir bauen:
--   - Tabelle `achievements` (Definition der Erfolge)
--   - Tabelle `player_achievements` (welcher User welches Achievement hat)
--   - Tabelle `player_lifetime_stats` (aggregierte Werte pro User über alle Partien)
--   - Funktion `aggregate_player_stats(p_lobby_id)` läuft am Spiel-Ende:
--       1) addiert players-Stats auf player_lifetime_stats (per user_id)
--       2) prüft alle Achievement-Kriterien und schreibt neue Unlocks
--   - Trigger auf lobbies UPDATE: ruft aggregate auf wenn phase → 'finished'
--
-- Gäste (ohne user_id) bekommen KEINE Lifetime-Stats und KEINE Achievements.
-- Wer eingeloggt ist, bekommt sie automatisch.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Tabelle: achievements (Katalog)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.achievements (
    code            TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    description     TEXT NOT NULL,
    icon            TEXT NOT NULL,
    tier            TEXT NOT NULL DEFAULT 'bronze',  -- bronze | silver | gold
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.achievements (code, title, description, icon, tier) VALUES
    ('first_win',         'Erstgeborener',        'Gewinne deine erste Partie.',                                       '🥇', 'bronze'),
    ('wins_5',            'Gewinner-Typ',         'Gewinne 5 Partien.',                                                '🏆', 'bronze'),
    ('wins_25',           'Champion',             'Gewinne 25 Partien.',                                               '🏅', 'silver'),
    ('wins_100',          'Legende',              'Gewinne 100 Partien.',                                              '👑', 'gold'),
    ('first_pass',        'Erster Wurf',          'Reiche die Kartoffel zum ersten Mal weiter.',                       '🥔', 'bronze'),
    ('passes_100',        'Hot-Potato-Routinier', 'Mache insgesamt 100 Pässe.',                                        '🔥', 'silver'),
    ('passes_500',        'Pass-Maschine',        'Mache insgesamt 500 Pässe.',                                        '⚡', 'gold'),
    ('clutch_10',         'Clutch-Master',        'Mache 10 Pässe weniger als 2 Sek. vor der Explosion.',              '⏱️', 'silver'),
    ('clutch_50',         'Eiskalt',              'Mache 50 Clutch-Pässe.',                                            '🧊', 'gold'),
    ('speed_demon',       'Schnell wie der Blitz','Pass die Kartoffel in unter 500 ms weiter.',                        '⚡', 'silver'),
    ('iron_lung',         'Mineralwasser',        'Halte die Kartoffel insgesamt 10 Minuten (kumuliert).',             '💪', 'silver'),
    ('survivor_3',        'Überlebenskünstler',   '3 Runden hintereinander am Leben bleiben.',                         '🛡️', 'bronze'),
    ('survivor_10',       'Unzerstörbar',         '10 Runden hintereinander am Leben bleiben.',                        '🪖', 'gold'),
    ('games_10',          'Stammgast',            'Spiele 10 Partien zu Ende.',                                        '🎟️', 'bronze'),
    ('games_50',          'Veteran',              'Spiele 50 Partien zu Ende.',                                        '🎖️', 'silver')
ON CONFLICT (code) DO UPDATE
    SET title = EXCLUDED.title,
        description = EXCLUDED.description,
        icon = EXCLUDED.icon,
        tier = EXCLUDED.tier;


-- ------------------------------------------------------------
-- Tabelle: player_lifetime_stats
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_lifetime_stats (
    user_id                 UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    games_played            INTEGER NOT NULL DEFAULT 0,
    wins                    INTEGER NOT NULL DEFAULT 0,
    total_passes            INTEGER NOT NULL DEFAULT 0,
    total_clutch_passes     INTEGER NOT NULL DEFAULT 0,
    fastest_pass_ms         INTEGER,
    total_hold_ms           BIGINT NOT NULL DEFAULT 0,
    best_survival_streak    INTEGER NOT NULL DEFAULT 0,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ------------------------------------------------------------
-- Tabelle: player_achievements
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_achievements (
    user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    achievement_code TEXT NOT NULL REFERENCES public.achievements(code) ON DELETE CASCADE,
    unlocked_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    lobby_id        UUID REFERENCES public.lobbies(id) ON DELETE SET NULL,
    PRIMARY KEY (user_id, achievement_code)
);

CREATE INDEX IF NOT EXISTS idx_player_achievements_user
    ON public.player_achievements (user_id, unlocked_at DESC);


-- ============================================================
-- Funktion: aggregate_player_stats(p_lobby_id)
-- Wird am Spiel-Ende aufgerufen. Aggregiert alle players-Stats
-- der Lobby auf player_lifetime_stats (pro user_id).
-- Prüft danach alle Achievement-Kriterien.
-- ============================================================
CREATE OR REPLACE FUNCTION public.aggregate_player_stats(p_lobby_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_winner_user_id UUID;
BEGIN
    -- Winner ist der letzte alive Spieler
    SELECT p.user_id INTO v_winner_user_id
    FROM public.players p
    JOIN public.lobbies l ON l.id = p_lobby_id
    WHERE p.lobby_id = p_lobby_id
      AND p.player_id = l.holder_player_id
      AND p.is_alive = TRUE
      AND p.user_id IS NOT NULL
    LIMIT 1;

    -- Lifetime-Stats für alle eingeloggten Spieler in der Lobby aktualisieren
    INSERT INTO public.player_lifetime_stats (
        user_id, games_played, wins, total_passes, total_clutch_passes,
        fastest_pass_ms, total_hold_ms, best_survival_streak, updated_at
    )
    SELECT
        p.user_id,
        1,
        CASE WHEN p.user_id = v_winner_user_id THEN 1 ELSE 0 END,
        COALESCE(p.pass_count, 0),
        COALESCE(p.clutch_pass_count, 0),
        p.fastest_pass_ms,
        COALESCE(p.total_hold_ms, 0),
        COALESCE(p.survival_streak, 0),
        NOW()
    FROM public.players p
    WHERE p.lobby_id = p_lobby_id
      AND p.user_id IS NOT NULL
      AND p.status = 'active'
    ON CONFLICT (user_id) DO UPDATE
    SET games_played          = public.player_lifetime_stats.games_played + 1,
        wins                  = public.player_lifetime_stats.wins + EXCLUDED.wins,
        total_passes          = public.player_lifetime_stats.total_passes + EXCLUDED.total_passes,
        total_clutch_passes   = public.player_lifetime_stats.total_clutch_passes + EXCLUDED.total_clutch_passes,
        fastest_pass_ms       = LEAST(
                                    COALESCE(public.player_lifetime_stats.fastest_pass_ms, 999999),
                                    COALESCE(EXCLUDED.fastest_pass_ms, 999999)
                                ),
        total_hold_ms         = public.player_lifetime_stats.total_hold_ms + EXCLUDED.total_hold_ms,
        best_survival_streak  = GREATEST(
                                    public.player_lifetime_stats.best_survival_streak,
                                    EXCLUDED.best_survival_streak
                                ),
        updated_at            = NOW();

    -- Achievements vergeben (idempotent über ON CONFLICT DO NOTHING)
    INSERT INTO public.player_achievements (user_id, achievement_code, lobby_id)
    SELECT s.user_id, ach.code, p_lobby_id
    FROM public.player_lifetime_stats s
    JOIN public.achievements ach ON TRUE
    JOIN public.players p ON p.lobby_id = p_lobby_id AND p.user_id = s.user_id
    WHERE s.user_id IN (
        SELECT user_id FROM public.players
        WHERE lobby_id = p_lobby_id AND user_id IS NOT NULL
    )
    AND (
        (ach.code = 'first_win'  AND s.wins >= 1) OR
        (ach.code = 'wins_5'     AND s.wins >= 5) OR
        (ach.code = 'wins_25'    AND s.wins >= 25) OR
        (ach.code = 'wins_100'   AND s.wins >= 100) OR
        (ach.code = 'first_pass' AND s.total_passes >= 1) OR
        (ach.code = 'passes_100' AND s.total_passes >= 100) OR
        (ach.code = 'passes_500' AND s.total_passes >= 500) OR
        (ach.code = 'clutch_10'  AND s.total_clutch_passes >= 10) OR
        (ach.code = 'clutch_50'  AND s.total_clutch_passes >= 50) OR
        (ach.code = 'speed_demon' AND s.fastest_pass_ms IS NOT NULL AND s.fastest_pass_ms < 500) OR
        (ach.code = 'iron_lung'  AND s.total_hold_ms >= 600000) OR
        (ach.code = 'survivor_3' AND s.best_survival_streak >= 3) OR
        (ach.code = 'survivor_10' AND s.best_survival_streak >= 10) OR
        (ach.code = 'games_10'   AND s.games_played >= 10) OR
        (ach.code = 'games_50'   AND s.games_played >= 50)
    )
    ON CONFLICT (user_id, achievement_code) DO NOTHING;
END;
$$;


-- ============================================================
-- Trigger: auf lobbies UPDATE → wenn phase auf 'finished' wechselt
-- ============================================================
CREATE OR REPLACE FUNCTION public.trg_aggregate_on_finished()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF NEW.phase = 'finished' AND (OLD.phase IS DISTINCT FROM NEW.phase) THEN
        PERFORM public.aggregate_player_stats(NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS lobbies_aggregate_on_finished ON public.lobbies;
CREATE TRIGGER lobbies_aggregate_on_finished
    AFTER UPDATE OF phase ON public.lobbies
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_aggregate_on_finished();


-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "achievements_read_all" ON public.achievements;
CREATE POLICY "achievements_read_all" ON public.achievements FOR SELECT USING (TRUE);

ALTER TABLE public.player_lifetime_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "player_lifetime_stats_read_all" ON public.player_lifetime_stats;
CREATE POLICY "player_lifetime_stats_read_all" ON public.player_lifetime_stats FOR SELECT USING (TRUE);

ALTER TABLE public.player_achievements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "player_achievements_read_all" ON public.player_achievements;
CREATE POLICY "player_achievements_read_all" ON public.player_achievements FOR SELECT USING (TRUE);


COMMIT;


-- ============================================================
-- 006_leaderboards.sql
-- ============================================================
-- ============================================================
-- Migration 006: Leaderboard-View
-- ============================================================
-- Eine VIEW über player_lifetime_stats + profiles.username, die nur
-- die für Leaderboards relevanten Felder + den Username exponiert
-- (keine Email, keine Auth-Internals).
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW public.leaderboard_view AS
SELECT
    p.username,
    s.user_id,
    s.games_played,
    s.wins,
    CASE
        WHEN s.games_played > 0 THEN ROUND((s.wins::numeric / s.games_played) * 100, 1)
        ELSE 0
    END AS win_rate_pct,
    s.total_passes,
    s.total_clutch_passes,
    s.fastest_pass_ms,
    s.total_hold_ms,
    s.best_survival_streak,
    s.updated_at
FROM public.player_lifetime_stats s
JOIN public.profiles p ON p.id = s.user_id
WHERE p.username IS NOT NULL
  AND s.games_played >= 1;


-- Make sure anon-role can read the view
GRANT SELECT ON public.leaderboard_view TO anon, authenticated;


COMMIT;


-- ============================================================
-- 007_bots.sql
-- ============================================================
-- ============================================================
-- Migration 007: Bot-Spieler (Practice-Mode)
-- ============================================================
-- Erlaubt dem Host, KI-gesteuerte Bots zur Lobby hinzuzufügen.
-- Bots werden im Host-Browser gesteuert (siehe Frontend useBotEngine).
--
-- Was hier passiert:
--   - Neue Spalte `players.is_bot BOOLEAN DEFAULT false`
--   - RPC `rpc_add_bot(p_lobby_id, p_me_player_id, p_bot_name)` legt einen
--     Bot-Spieler an. Nur Host darf.
--   - RPC `rpc_remove_bot(p_lobby_id, p_me_player_id, p_bot_player_id)`
--     entfernt einen Bot. Nur Host darf.
-- ============================================================

BEGIN;

ALTER TABLE public.players
    ADD COLUMN IF NOT EXISTS is_bot BOOLEAN NOT NULL DEFAULT FALSE;


CREATE OR REPLACE FUNCTION public.rpc_add_bot(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_bot_name TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_host UUID;
    v_max_players INT;
    v_active_count INT;
    v_next_seat INT;
    v_bot_id UUID := gen_random_uuid();
BEGIN
    SELECT host_player_id, max_players INTO v_host, v_max_players
    FROM public.lobbies WHERE id = p_lobby_id;

    IF v_host IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
    IF v_host IS DISTINCT FROM p_me_player_id THEN RAISE EXCEPTION 'not_host'; END IF;

    SELECT COUNT(*) INTO v_active_count
    FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active';

    IF v_active_count >= v_max_players THEN RAISE EXCEPTION 'lobby_full'; END IF;

    -- next free seat
    SELECT COALESCE(MIN(s.i), 0) INTO v_next_seat
    FROM generate_series(0, v_max_players - 1) AS s(i)
    LEFT JOIN public.players p
        ON p.lobby_id = p_lobby_id
       AND p.seat_index = s.i
       AND p.status = 'active'
    WHERE p.id IS NULL;

    INSERT INTO public.players (
        lobby_id, player_id, name, status, seat_index,
        joined_at, last_seen_at, is_bot, ready
    )
    VALUES (
        p_lobby_id, v_bot_id, LEFT(TRIM(p_bot_name), 24), 'active', v_next_seat,
        NOW(), NOW(), TRUE, TRUE  -- Bots sind automatisch ready
    );

    UPDATE public.lobbies SET last_activity_at = NOW() WHERE id = p_lobby_id;

    RETURN v_bot_id;
END;
$$;


CREATE OR REPLACE FUNCTION public.rpc_remove_bot(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_bot_player_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_host UUID;
BEGIN
    SELECT host_player_id INTO v_host
    FROM public.lobbies WHERE id = p_lobby_id;

    IF v_host IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
    IF v_host IS DISTINCT FROM p_me_player_id THEN RAISE EXCEPTION 'not_host'; END IF;

    DELETE FROM public.players
    WHERE lobby_id = p_lobby_id
      AND player_id = p_bot_player_id
      AND is_bot = TRUE;
END;
$$;

COMMIT;


-- ============================================================
-- 008_friends_and_saved_lobbies.sql
-- ============================================================
-- ============================================================
-- Migration 008: Freundeslisten + gespeicherte Lobbies
-- ============================================================
-- friendships: bidirektionale Freundschaft mit pending/accepted Status.
--   - Wer schickt eine Anfrage? → user_id = Anfragender, friend_user_id = Empfänger, status='pending'
--   - Wer akzeptiert? → setzt status='accepted', spiegelt die Zeile.
--   - Zwei Zeilen pro Freundschaft (User A → B + User B → A) für einfache Queries.
--
-- saved_lobbies: ein User merkt sich eine Lobby (z.B. "die feste Donnerstags-Gruppe").
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- friendships
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.friendships (
    user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    friend_user_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status          TEXT NOT NULL DEFAULT 'pending',   -- 'pending' | 'accepted' | 'blocked'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accepted_at     TIMESTAMPTZ,
    PRIMARY KEY (user_id, friend_user_id),
    CHECK (user_id <> friend_user_id)
);

CREATE INDEX IF NOT EXISTS idx_friendships_user_status
    ON public.friendships (user_id, status);


-- ------------------------------------------------------------
-- saved_lobbies
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.saved_lobbies (
    user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    lobby_code  TEXT NOT NULL,
    nickname    TEXT NOT NULL,
    last_used   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, lobby_code)
);

CREATE INDEX IF NOT EXISTS idx_saved_lobbies_user
    ON public.saved_lobbies (user_id, last_used DESC);


-- ============================================================
-- RPC: rpc_send_friend_request
-- Anfrage per Username — wir schauen die ID intern raus.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_send_friend_request(
    p_from_user_id UUID,
    p_to_username TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_to_id UUID;
BEGIN
    IF p_from_user_id IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;

    SELECT id INTO v_to_id
    FROM public.profiles
    WHERE LOWER(username) = LOWER(TRIM(p_to_username))
    LIMIT 1;

    IF v_to_id IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
    IF v_to_id = p_from_user_id THEN RAISE EXCEPTION 'cannot_befriend_self'; END IF;

    INSERT INTO public.friendships (user_id, friend_user_id, status)
    VALUES (p_from_user_id, v_to_id, 'pending')
    ON CONFLICT (user_id, friend_user_id) DO NOTHING;
END;
$$;


-- ============================================================
-- RPC: rpc_accept_friend_request
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_accept_friend_request(
    p_me_user_id UUID,
    p_from_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF p_me_user_id IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;

    -- Akzeptiere die eingegangene Anfrage
    UPDATE public.friendships
    SET status = 'accepted', accepted_at = NOW()
    WHERE user_id = p_from_user_id
      AND friend_user_id = p_me_user_id
      AND status = 'pending';

    IF NOT FOUND THEN RAISE EXCEPTION 'request_not_found'; END IF;

    -- Spiegel-Zeile anlegen (sodass beide Seiten den Freund in ihrer Liste haben)
    INSERT INTO public.friendships (user_id, friend_user_id, status, accepted_at)
    VALUES (p_me_user_id, p_from_user_id, 'accepted', NOW())
    ON CONFLICT (user_id, friend_user_id)
    DO UPDATE SET status = 'accepted', accepted_at = NOW();
END;
$$;


-- ============================================================
-- RPC: rpc_remove_friend
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_remove_friend(
    p_me_user_id UUID,
    p_friend_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF p_me_user_id IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;

    -- Beide Richtungen löschen
    DELETE FROM public.friendships
    WHERE (user_id = p_me_user_id AND friend_user_id = p_friend_user_id)
       OR (user_id = p_friend_user_id AND friend_user_id = p_me_user_id);
END;
$$;


-- ============================================================
-- RPC: rpc_save_lobby — die aktuelle Lobby ins „Gespeichert" merken
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_save_lobby(
    p_user_id UUID,
    p_lobby_code TEXT,
    p_nickname TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF p_user_id IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;

    INSERT INTO public.saved_lobbies (user_id, lobby_code, nickname, last_used)
    VALUES (p_user_id, UPPER(TRIM(p_lobby_code)), LEFT(TRIM(p_nickname), 40), NOW())
    ON CONFLICT (user_id, lobby_code)
    DO UPDATE SET nickname = EXCLUDED.nickname, last_used = NOW();
END;
$$;


CREATE OR REPLACE FUNCTION public.rpc_unsave_lobby(
    p_user_id UUID,
    p_lobby_code TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF p_user_id IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;
    DELETE FROM public.saved_lobbies
    WHERE user_id = p_user_id AND lobby_code = UPPER(TRIM(p_lobby_code));
END;
$$;


-- ============================================================
-- View: friends_view — Freunde-Liste mit Username
-- ============================================================
CREATE OR REPLACE VIEW public.friends_view AS
SELECT
    f.user_id,
    f.friend_user_id,
    p.username AS friend_username,
    f.status,
    f.created_at,
    f.accepted_at
FROM public.friendships f
JOIN public.profiles p ON p.id = f.friend_user_id;

GRANT SELECT ON public.friends_view TO anon, authenticated;


-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "friendships_read_own" ON public.friendships;
CREATE POLICY "friendships_read_own"
    ON public.friendships
    FOR SELECT
    USING (TRUE);  -- vereinfacht; in echtem Multi-User-Setup auf auth.uid() einschränken

ALTER TABLE public.saved_lobbies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "saved_lobbies_read_own" ON public.saved_lobbies;
CREATE POLICY "saved_lobbies_read_own"
    ON public.saved_lobbies
    FOR SELECT
    USING (TRUE);


COMMIT;


-- ============================================================
-- 009_reset_lobby.sql
-- ============================================================
-- ============================================================
-- Migration 009: rpc_reset_lobby fehlte komplett
-- ============================================================
-- apps/web/src/app/game/[code]/page.tsx ruft "rpc_reset_lobby" auf
-- (Button "Zurück zur Lobby" auf dem Finished-Screen), aber diese
-- Funktion war in keiner db/-Datei definiert -> Klick endete in
-- einem Fehler-Toast.
--
-- Zweck (aus Button-Kontext abgeleitet): Lobby nach Spielende
-- komplett auf den Zustand direkt nach rpc_create_lobby zurücksetzen
-- (phase='waiting'), OHNE wie rpc_rematch direkt in topic_vote zu
-- starten. Spieler bleiben in der Lobby (im Gegensatz zu einem
-- "Lobby löschen"), aber alle Runden-Daten werden geleert.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT)
 RETURNS VOID
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
    v_lobby_id UUID;
BEGIN
    SELECT id INTO v_lobby_id
    FROM public.lobbies
    WHERE code = UPPER(TRIM(p_code))
    LIMIT 1;

    IF v_lobby_id IS NULL THEN
        RAISE EXCEPTION 'Lobby nicht gefunden';
    END IF;

    DELETE FROM public.topic_votes WHERE lobby_id = v_lobby_id;

    -- Wie rpc_rematch: alle aktiven Spieler (inkl. Bots) auf Anfangszustand.
    UPDATE public.players
    SET ready = false,
        is_alive = true,
        pass_count = 0,
        clutch_pass_count = 0,
        fastest_pass_ms = NULL,
        total_hold_ms = 0,
        survival_streak = 0,
        last_pass_at = NULL
    WHERE lobby_id = v_lobby_id
      AND status = 'active';

    UPDATE public.lobbies
    SET phase = 'waiting',
        locked = false,
        holder_player_id = NULL,
        explode_at = NULL,
        run_started_at = NULL,
        last_loser_player_id = NULL,
        topic_a = NULL,
        topic_b = NULL,
        topic_selected = NULL,
        topic_vote_started_at = NULL,
        topic_vote_ends_at = NULL,
        countdown_started_at = NULL,
        countdown_ends_at = NULL,
        topic_tie_choices = NULL,
        topic_tie_pick = NULL,
        current_attempt_id = NULL,
        used_answers = '{}',
        round_number = 0,
        pass_direction = 1,
        last_activity_at = now()
    WHERE id = v_lobby_id;
END;
$$;

COMMIT;


-- ============================================================
-- 010_used_answers_reset.sql
-- ============================================================
-- ============================================================
-- Migration 010: used_answers wird nie zurückgesetzt
-- ============================================================
-- lobbies.used_answers (Anti-Doppelnennung, siehe Migration 001)
-- sammelte sich über Runden und Rematches hinweg an, weil weder
-- rpc_advance_from_countdown (Rundenstart) noch rpc_rematch das Feld
-- je geleert haben -- Migration 001 hat das per Kommentar sogar
-- explizit als offenes TODO markiert.
--
-- Fix: current_attempt_id + used_answers werden jetzt geleert in:
--   - rpc_advance_from_countdown (jeder neue Rundenstart, inkl. Rematch)
--   - rpc_rematch (zur Sicherheit zusätzlich, falls irgendwo direkt
--     wieder in 'running' gesprungen werden sollte)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_holder uuid;
begin
  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + interval '25 seconds',
      countdown_started_at = null,
      countdown_ends_at = null,
      used_answers = '{}',
      current_attempt_id = null,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = false, is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 011_round_speed_wiring.sql
-- ============================================================
-- ============================================================
-- Migration 011: round_speed hatte keine Wirkung
-- ============================================================
-- Problem:
--   - lobbies.round_speed existiert (default 'normal'), wurde aber nie
--     von rpc_create_lobby gesetzt -- der Host-Screen wählt einen
--     RoundSpeed-Key ('fast'/'normal'/'calm'), rechnet ihn aber in
--     apps/web/src/app/host/page.tsx lokal in eine feste Sekundenzahl
--     um und schickt nur p_round_seconds (-> lobbies.round_seconds,
--     eine reine Anzeige-Spalte, die von keiner RPC gelesen wird).
--   - calc_explode_seconds(round_speed, alive_count, round_number)
--     existiert bereits fertig in der DB, wurde aber von keiner RPC
--     aufgerufen. rpc_advance_from_countdown nutzte hartcodiert
--     interval '25 seconds', rpc_tick_game hartcodiert interval '15
--     seconds'.
--
-- Fix (kein neues Balancing -- nutzt exakt die bereits vorhandene
-- calc_explode_seconds Funktion mit ihren bestehenden Defaults):
--   1) rpc_create_lobby bekommt einen neuen optionalen Parameter
--      p_round_speed (Default 'normal', validiert gegen fast/normal/
--      calm) und schreibt ihn nach lobbies.round_speed.
--   2) rpc_advance_from_countdown berechnet explode_at jetzt über
--      calc_explode_seconds(round_speed, alive_count, 1) statt fix 25s.
--   3) rpc_tick_game berechnet die nächste explode_at über
--      calc_explode_seconds(round_speed, alive_count, round_number)
--      statt fix 15s.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- rpc_create_lobby: + p_round_speed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_lobby(
    p_host_name TEXT,
    p_privacy TEXT,
    p_max_players INTEGER,
    p_round_seconds INTEGER,
    p_user_id UUID DEFAULT NULL,
    p_round_speed TEXT DEFAULT 'normal'
) RETURNS TABLE(code TEXT, host_player_id UUID)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_lobby_id UUID := gen_random_uuid();
    v_code TEXT;
    v_host_player_id UUID := gen_random_uuid();
    v_round_speed TEXT := btrim(coalesce(p_round_speed, 'normal'));
BEGIN
    IF v_round_speed NOT IN ('fast', 'normal', 'calm') THEN
        v_round_speed := 'normal';
    END IF;

    v_code := public.generate_lobby_code(4);

    INSERT INTO public.lobbies (
        id, code, host_player_id, status, privacy, max_players, round_seconds, round_speed,
        created_at, last_activity_at, host_user_id
    )
    VALUES (
        v_lobby_id,
        UPPER(v_code),
        v_host_player_id,
        'waiting',
        p_privacy,
        GREATEST(2, LEAST(p_max_players, 12)),
        COALESCE(p_round_seconds, 25),
        v_round_speed,
        NOW(),
        NOW(),
        p_user_id
    );

    INSERT INTO public.players (
        id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id
    )
    VALUES (
        gen_random_uuid(),
        v_lobby_id,
        v_host_player_id,
        LEFT(TRIM(p_host_name), 24),
        false,
        NOW(),
        NOW(),
        p_user_id
    );

    RETURN QUERY SELECT UPPER(v_code), v_host_player_id;
END;
$$;


-- ------------------------------------------------------------
-- rpc_advance_from_countdown: dynamische Startzeit
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
begin
  select round_speed, coalesce(round_number, 0)
    into v_round_speed, v_round_number
  from public.lobbies where id = p_lobby_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  v_explode_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    greatest(1, v_alive_count),
    greatest(1, v_round_number)
  );

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + (v_explode_seconds * interval '1 second'),
      countdown_started_at = null,
      countdown_ends_at = null,
      used_answers = '{}',
      current_attempt_id = null,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';
end;
$function$;


-- ------------------------------------------------------------
-- rpc_tick_game: dynamische nächste Rundenzeit
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  if v_now < v_explode_at then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby_id and player_id = v_loser;

  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  update public.lobbies
  set round_number = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at = v_now
  where id = v_lobby_id
  returning round_number into v_round_number;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true and player_id != v_loser
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = v_now + v_round_duration,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 012_rls_core_tables.sql
-- ============================================================
-- ============================================================
-- Migration 012: RLS auf Kern-Tabellen fehlte komplett
-- ============================================================
-- Der Supabase Anon-Key liegt öffentlich im Frontend-Bundle. Ohne RLS
-- kann JEDER über die PostgREST-API direkt lesen/schreiben/löschen --
-- unabhängig davon, was der offizielle Frontend-Code tatsächlich tut.
--
-- Teil A (aus dem Audit-Auftrag, "mindestens sicherstellen"):
--   lobbies, players, topic_pool, topic_votes, game_runs bekommen
--   RLS + eine SELECT-für-alle-Policy (wird für Realtime-Subscriptions
--   und den Polling-Fallback gebraucht), aber KEINE INSERT/UPDATE/
--   DELETE-Policy -- alle Schreiboperationen laufen ausschließlich
--   über die SECURITY DEFINER RPCs (rpc_create_lobby, rpc_join_lobby,
--   rpc_pass_potato, ...), die RLS als Tabellenbesitzer umgehen.
--
-- Teil B (zusätzlich beim Audit gefunden, nicht in der ursprünglichen
-- Bug-Liste, aber derselbe Risiko-Klasse):
--   - game_run_players / game_run_eliminations / round_stats werden
--     von keiner Frontend-Route gelesen -> RLS an, KEINE Policy
--     (kompletter Lockout für anon/authenticated; nur die SECURITY
--     DEFINER Trigger/RPCs dürfen noch schreiben).
--   - lobby_admin_sessions / lobby_admin_logs / staff_roles: enthalten
--     Rollen-/Moderationsdaten, werden von keiner Frontend-Route
--     direkt gelesen -> RLS an, KEINE Policy (kompletter Lockout).
--   - kv_store_8e1b0e4b: unbenutzte Altlast (vermutlich Scaffolding-
--     Rest), wird nirgends referenziert -> RLS an, KEINE Policy.
--   - profiles: enthält email/phone (PII). Es gibt noch KEINE Policy
--     dafür, und apps/web/src/hooks/useFriends.ts liest per Anon-Key
--     direkt "profiles.username" für die Freundesliste. Statt RLS
--     (zeilenbasiert, kann keine Spalten filtern) nutzen wir
--     Column-Level-Privileges: anon/authenticated dürfen per REST nur
--     noch (id, username) sehen, nie email/phone/*verified_at. Alle
--     SECURITY DEFINER Funktionen (get_email_for_username, handle_new_user,
--     sync_profile_verification, ...) sind Owner der Tabelle und bleiben
--     davon unberührt.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Teil A: öffentlich lesbare Kern-Tabellen
-- ------------------------------------------------------------
ALTER TABLE public.lobbies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "lobbies_read_all" ON public.lobbies;
CREATE POLICY "lobbies_read_all" ON public.lobbies FOR SELECT USING (TRUE);

ALTER TABLE public.players ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "players_read_all" ON public.players;
CREATE POLICY "players_read_all" ON public.players FOR SELECT USING (TRUE);

ALTER TABLE public.topic_pool ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "topic_pool_read_all" ON public.topic_pool;
CREATE POLICY "topic_pool_read_all" ON public.topic_pool FOR SELECT USING (TRUE);

ALTER TABLE public.topic_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "topic_votes_read_all" ON public.topic_votes;
CREATE POLICY "topic_votes_read_all" ON public.topic_votes FOR SELECT USING (TRUE);

ALTER TABLE public.game_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "game_runs_read_all" ON public.game_runs;
CREATE POLICY "game_runs_read_all" ON public.game_runs FOR SELECT USING (TRUE);


-- ------------------------------------------------------------
-- Teil B: komplett sperren (kein Frontend-Zugriff nötig)
-- ------------------------------------------------------------
ALTER TABLE public.game_run_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_run_eliminations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.round_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lobby_admin_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lobby_admin_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kv_store_8e1b0e4b ENABLE ROW LEVEL SECURITY;
-- Bewusst keine Policies -> Default-Deny für anon/authenticated.


-- ------------------------------------------------------------
-- profiles: RLS an (Zeilen-Ebene) + Column-Level-Grants (Spalten-Ebene)
-- ------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profiles_read_all" ON public.profiles;
CREATE POLICY "profiles_read_all" ON public.profiles FOR SELECT USING (TRUE);

REVOKE SELECT ON public.profiles FROM anon, authenticated;
GRANT SELECT (id, username) ON public.profiles TO anon, authenticated;

COMMIT;


-- ============================================================
-- 013_legacy_cleanup.sql
-- ============================================================
-- ============================================================
-- Migration 013: Tote Legacy-Strukturen aufräumen
-- ============================================================
-- Geprüft per Grep über apps/web/src UND über alle db/-Dateien
-- (functions.sql + migrations 001-012), bevor irgendetwas gelöscht
-- wird:
--
--   - public.lobby_players: taucht NUR in der eigenen CREATE TABLE
--     Zeile in schema.sql auf. Kein Frontend-Query, keine RPC, kein
--     Trigger nutzt sie. Ersetzt durch public.players seit jeher.
--     -> sicher zum Löschen.
--
--   - public.topics: wurde nur von der ALTEN Version von
--     rpc_start_rematch_if_ready genutzt (Bug, siehe Kommentar in
--     Migration 003). Migration 003 hat die Funktion bereits auf
--     topic_pool umgestellt; seitdem referenziert keine einzige
--     Funktion mehr public.topics. Migration 003 hat das Löschen
--     bereits als sicheren Schritt dokumentiert.
--     -> sicher zum Löschen.
--
--   - public.game_state: taucht NUR in der eigenen CREATE TABLE Zeile
--     in schema.sql auf. Die aktiven Felder (phase, holder_player_id,
--     explode_at, round_number) leben stattdessen alle in
--     public.lobbies. Kein Frontend-Query, keine RPC referenziert sie.
--     -> sicher zum Löschen.
--
-- NICHT gelöscht (bewusste Entscheidung, siehe Auftrag "bei
-- Unsicherheit lieber stehen lassen"):
--
--   Die in db/functions.sql (Zeilen 930-951) als Legacy dokumentierten
--   Funktionen (begin_round, boom, pass_potato x2, start_game x3,
--   start_lobby, start_round, start_game_by_code, leave_lobby x2,
--   kick_player(p_lobby_id, p_target_player_id), end_lobby, reset_lobby,
--   sowie die Trigger/Helper-Liste darunter) sind in KEINER Datei in
--   db/ mit vollständiger Signatur definiert -- sie existieren
--   offenbar nur (noch) live in Supabase aus einer älteren Iteration,
--   wurden aber nie in dieses Repo gedumpt. Postgres braucht für
--   DROP FUNCTION die exakte Parameter-Signatur; ohne sie riskiert ein
--   blindes DROP entweder einen Fehler oder (schlimmer, falls mehrere
--   Overloads existieren) das Löschen der falschen Variante.
--
--   Vor einem echten Cleanup bitte im Supabase SQL-Editor ausführen
--   und die exakten Signaturen einsammeln:
--
--     SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
--     FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace
--     WHERE n.nspname = 'public'
--       AND p.proname IN (
--         'begin_round','boom','pass_potato','start_game','start_lobby',
--         'start_round','start_game_by_code','leave_lobby','end_lobby',
--         'reset_lobby','rls_auto_enable','set_lobby_timestamps','set_ready',
--         'set_updated_at','tg_set_updated_at','touch_lobby_activity_by_code',
--         'trg_clear_lobby_on_player_leave','trg_reconcile_after_exit',
--         'trg_reconcile_on_player_change','cleanup_lobby_if_empty',
--         'end_lobby_if_host_left','reconcile_lobby_after_exit',
--         'rpc_reconcile_lobby','rpc_eliminate_player','rpc_clear_lobby_to_waiting',
--         'rpc_restart_game','rpc_ready_up','rpc_rematch_1v1','rpc_reset_lobby',
--         'rpc_schedule_next_explosion','cleanup_expired_lobbies'
--       );
--
--   ACHTUNG: rpc_reset_lobby steht in dieser Altlast-Liste, ist aber
--   seit Migration 009 eine ECHTE, aktiv genutzte Funktion -- die
--   obige Abfrage würde also (falls in Supabase noch eine alte Version
--   mit anderer Signatur existierte) einen Konflikt aufdecken, den man
--   vor dem nächsten Deploy manuell prüfen sollte.
-- ============================================================

BEGIN;

DROP TABLE IF EXISTS public.lobby_players;
DROP TABLE IF EXISTS public.topics;
DROP TABLE IF EXISTS public.game_state;

COMMIT;


-- ============================================================
-- 014_bots_stay_ready.sql
-- ============================================================
-- ============================================================
-- Migration 014: Bots bleiben nach Reset/Rematch bereit
-- ============================================================
-- Live-Playtest-Fund (fix/clean-base): rpc_reset_lobby, rpc_rematch und
-- rpc_start_rematch_if_ready setzen ready = false für ALLE aktiven
-- Spieler -- auch für Bots. Bots haben aber keine eigene Möglichkeit,
-- sich wieder bereit zu melden: die Bot-Engine (useBotEngine.ts) greift
-- nur in den Phasen topic_vote/running ein, nie im Lobby-Ready-Screen.
-- Ergebnis: Sobald ein Bot in der Lobby war und eine Runde zu Ende
-- ging, blieb er für IMMER auf "nicht bereit" hängen -- weder
-- "Zurück zur Lobby" noch "Rematch" ließen sich danach je wieder
-- starten, weil "alle bereit" nie mehr erreicht wurde.
--
-- Fix: Bots werden beim Reset/Rematch auf ready = true gesetzt (nicht
-- false) -- genau wie schon bei rpc_add_bot (Migration 007). Menschliche
-- Spieler verhalten sich unverändert (ready = false, müssen aktiv
-- wieder auf "Bereit" klicken).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_ready_count int; v_active_count int;
  v_topic_a text; v_topic_b text;
begin
  select id into v_lobby_id from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  select count(*) into v_ready_count from public.players
  where lobby_id = v_lobby_id and status = 'active' and coalesce(ready, false) = true;

  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;
  if v_ready_count <> v_active_count then return; end if;

  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true
  order by random() limit 1;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a
  order by random() limit 1;

  if v_topic_a is null or v_topic_b is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 015_security_definer_views.sql
-- ============================================================
-- ============================================================
-- Migration 015: Security-Definer-Views entschärft
-- ============================================================
-- Supabase Advisor (Security, CRITICAL) meldete:
--   "View public.leaderboard_view is defined with the SECURITY
--    DEFINER property"
--   "View public.friends_view is defined with the SECURITY
--    DEFINER property"
--
-- Hintergrund: Eine normale Postgres-VIEW wertet RLS/Grants standard-
-- mäßig mit den Rechten des VIEW-BESITZERS aus (i.d.R. der Migrations-
-- Rolle), nicht mit denen des tatsächlich abfragenden Users. Damit
-- umgeht die View RLS-Policies auf den referenzierten Tabellen
-- komplett -- unabhängig davon, ob das heute schon ausgenutzt werden
-- kann (aktuell sind die Policies auf player_lifetime_stats/
-- friendships ohnehin "USING (TRUE)", siehe Migration 005/008), ist
-- es ein Foundational-Risiko: Sobald diese Policies mal enger gezogen
-- werden, würde die View das RLS trotzdem weiter umgehen, ohne dass
-- es auffällt.
--
-- Fix: `security_invoker = true` (Postgres 15+, von Supabase
-- unterstützt) lässt die View stattdessen mit den Rechten des
-- ABFRAGENDEN Users laufen -- RLS-Policies + Column-Grants (z.B. die
-- profiles-Einschränkung auf nur id/username aus Migration 012)
-- greifen dann auch innerhalb der View korrekt.
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW public.leaderboard_view
WITH (security_invoker = true) AS
SELECT
    p.username,
    s.user_id,
    s.games_played,
    s.wins,
    CASE
        WHEN s.games_played > 0 THEN ROUND((s.wins::numeric / s.games_played) * 100, 1)
        ELSE 0
    END AS win_rate_pct,
    s.total_passes,
    s.total_clutch_passes,
    s.fastest_pass_ms,
    s.total_hold_ms,
    s.best_survival_streak,
    s.updated_at
FROM public.player_lifetime_stats s
JOIN public.profiles p ON p.id = s.user_id
WHERE p.username IS NOT NULL
  AND s.games_played >= 1;

GRANT SELECT ON public.leaderboard_view TO anon, authenticated;


CREATE OR REPLACE VIEW public.friends_view
WITH (security_invoker = true) AS
SELECT
    f.user_id,
    f.friend_user_id,
    p.username AS friend_username,
    f.status,
    f.created_at,
    f.accepted_at
FROM public.friendships f
JOIN public.profiles p ON p.id = f.friend_user_id;

GRANT SELECT ON public.friends_view TO anon, authenticated;

COMMIT;


-- ============================================================
-- 016_function_search_path_hardening.sql
-- ============================================================
-- ============================================================
-- Migration 016: Fehlenden search_path bei SECURITY DEFINER-Funktionen ergänzt
-- ============================================================
-- Beim Sicherheits-Audit gefunden (nicht vom Advisor-Screenshot
-- gemeldet, aber dieselbe Fund-Klasse "Function Search Path Mutable",
-- die Supabase separat unter Security lintet): 15 SECURITY DEFINER
-- Funktionen hatten kein `SET search_path`, obwohl praktisch alle
-- anderen SECURITY DEFINER Funktionen im Projekt das bereits haben.
--
-- Risiko: Eine SECURITY DEFINER Funktion ohne fest verdrahteten
-- search_path lässt sich potenziell kapern, wenn ein Aufrufer (mit
-- Schema-Create-Rechten) ein gleichnamiges Objekt in einem Schema
-- anlegt, das vor `public` im search_path des Funktions-Besitzers
-- steht -- die Funktion würde dann unbemerkt das falsche Objekt
-- verwenden, mit den erhöhten Rechten des Funktions-Besitzers.
-- Da hier alle Tabellen-/Funktionsreferenzen im Code bereits mit
-- `public.` qualifiziert sind, ist die praktische Ausnutzbarkeit
-- gering -- trotzdem harte Absicherung nach Postgres/Supabase
-- Best-Practice, ohne jegliche Verhaltensänderung.
--
-- ALTER FUNCTION statt CREATE OR REPLACE: ändert nur die Config,
-- fasst den Funktionskörper nicht an -- risikofrei.
-- ============================================================

BEGIN;

ALTER FUNCTION public.cleanup_lobby(uuid, integer) SET search_path TO 'public';
ALTER FUNCTION public.kick_player(uuid, uuid, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_pass_potato(text, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_begin_topic_vote(uuid, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_create_lobby(text, text, integer, integer, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.rpc_heartbeat(uuid, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_tick_game(text) SET search_path TO 'public';
ALTER FUNCTION public.rpc_vote_topic(uuid, uuid, integer) SET search_path TO 'public';
ALTER FUNCTION public.set_lobby_mode(uuid, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.set_lobby_topic(uuid, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.set_max_players(uuid, uuid, integer) SET search_path TO 'public';
ALTER FUNCTION public.rpc_attempt_pass(text, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.rpc_vote_answer(uuid, uuid, boolean) SET search_path TO 'public';
ALTER FUNCTION public._finalize_attempt_accept(uuid) SET search_path TO 'public';
ALTER FUNCTION public._finalize_attempt_reject(uuid) SET search_path TO 'public';

COMMIT;


-- ============================================================
-- 017_restrict_email_lookup.sql
-- ============================================================
-- ============================================================
-- Migration 017: get_email_for_username nicht mehr öffentlich aufrufbar
-- ============================================================
-- Beim Sicherheits-Audit gefunden (nicht vom Advisor gemeldet, aber
-- schwerwiegender als die beiden View-Funde): get_email_for_username(
-- p_username text) RETURNS text war als normale RPC für anon/
-- authenticated aufrufbar UND gab die Klartext-Email direkt zurück.
--
-- apps/web/src/app/login/page.tsx rief sie bisher direkt vom Browser
-- aus auf, um Username-Login zu ermöglichen ("kein @ im Feld -> Email
-- per RPC holen, dann signInWithPassword"). Das Problem: der Anon-Key
-- liegt öffentlich im Frontend-Bundle -- JEDER kann die RPC direkt per
-- REST aufrufen (unabhängig vom eigentlichen Frontend-Code) und damit
-- für JEDEN bekannten Username (Usernames sind über leaderboard_view/
-- friends_view ohnehin öffentlich sichtbar) die zugehörige Email
-- abgreifen. Das ist ein klassisches Username->Email-Harvesting für
-- Phishing/Spam/Credential-Stuffing-Listen -- schwerwiegender als die
-- beiden Advisor-Funde, weil hier tatsächlich PII (Email) mit einem
-- einzigen, für jeden möglichen Aufruf abfließt.
--
-- Fix: EXECUTE-Recht für anon/authenticated entzogen. Die Funktion
-- bleibt für den Owner (postgres) bzw. den service_role (umgeht
-- Grants ohnehin) nutzbar. Der Login-Flow wird im selben Zug auf
-- einen Server Action umgestellt (siehe apps/web/src/actions/login.ts),
-- der die Email serverseitig mit dem Service-Role-Key auflöst und NIE
-- an den Browser zurückgibt.
--
-- WICHTIG: Ohne SUPABASE_SERVICE_ROLE_KEY in der Server-Umgebung
-- funktioniert Username-Login danach nicht mehr (Email-Login bleibt
-- unberührt) -- siehe apps/web/.env.example.
-- ============================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.get_email_for_username(text) FROM PUBLIC, anon, authenticated;

COMMIT;


-- ============================================================
-- 018_resolve_stale_attempts.sql
-- ============================================================
-- ============================================================
-- Migration 018: Timeout für hängende Pass-Versuche
-- ============================================================
-- Live-Simulation (BALANCE_REPORT.md, Fund #2): rpc_vote_answer
-- verlangt bei genau 2 verbleibenden Wählern (v_alive = 2, also 3
-- lebende Spieler insgesamt) Einstimmigkeit -- es gab aber KEINEN
-- Timeout. Ein einzelner Spieler, der nicht (oder gegensätzlich)
-- abstimmt, konnte einen pass_attempt für immer auf 'pending' halten.
-- Der zugehörige Freeze-Bug (rpc_tick_game wurde nur vom Browser des
-- aktuellen Halters ausgelöst) ist bereits gefixt -- die Runde endet
-- also inzwischen zuverlässig durch Explosion. Damit ein ehrlich
-- antwortender Halter aber überhaupt eine faire Chance hat, statt
-- durch einen einzelnen Non-Voter/Ablehner automatisch zu verlieren,
-- wird ein hängender Versuch nach 8 Sekunden aufgelöst:
--   - Mehrheit der bis dahin abgegebenen Stimmen entscheidet
--   - Bei Gleichstand (inkl. 0:0, niemand hat abgestimmt) -> im
--     Zweifel für den Halter (angenommen), damit ein einzelner
--     AFK/Troll-Spieler nicht jeden Pass permanent blockieren kann
--
-- Aufrufbar von jedem verbundenen Client (siehe game/[code]/page.tsx),
-- analog zum bereits bestehenden Muster für topic_vote/countdown.
-- Idempotent: wirkt nur auf status='pending' UND älter als 8s.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_resolve_stale_attempt(p_attempt_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_attempt public.pass_attempts%ROWTYPE;
begin
  select * into v_attempt from public.pass_attempts where id = p_attempt_id for update;
  if not found then return; end if;
  if v_attempt.status <> 'pending' then return; end if;
  if v_attempt.created_at > now() - interval '8 seconds' then return; end if;

  if v_attempt.accept_count >= v_attempt.reject_count then
    perform public._finalize_attempt_accept(v_attempt.id);
  else
    perform public._finalize_attempt_reject(v_attempt.id);
  end if;
end;
$function$;

COMMIT;


-- ============================================================
-- 019_guard_reset_rematch.sql
-- ============================================================
-- ============================================================
-- Migration 019: rpc_reset_lobby + rpc_rematch abgesichert
-- ============================================================
-- Beim Vollständigkeits-Audit gefunden (schwerwiegender als die
-- bekannte Player-Impersonation-Problematik, weil hier nicht einmal
-- eine Spieler-ID nötig war): rpc_reset_lobby(p_code) und
-- rpc_rematch(p_code) nahmen NUR den 4-stelligen Lobby-Code entgegen
-- -- keinerlei Prüfung, ob der Aufrufer überhaupt Mitglied dieser
-- Lobby ist, geschweige denn in welcher Phase sie gerade ist. Der Code
-- steht im Join-Link, den man mit jedem teilt -- jeder, der ihn je
-- gesehen hat (auch nach dem Verlassen), konnte damit JEDE laufende
-- Partie jederzeit zurücksetzen oder in den Rematch zwingen.
--
-- Fix: beide verlangen jetzt zusätzlich p_player_id und prüfen, dass
-- diese Person aktiv Mitglied der Lobby ist (nicht nur Host --
-- "Zurück zur Lobby" und "Rematch" sind im UI bewusst für alle
-- Spieler verfügbar, nicht nur den Host). Zusätzlich: beide wirken
-- nur noch aus phase='finished' -- vorher ließ sich damit auch eine
-- laufende Partie mitten im Spiel abwürgen.
--
-- rpc_start_rematch_if_ready bleibt unverändert: sie prüft die
-- Ready-Zahlen server-seitig und ist ohne echte Mehrheit ein No-Op,
-- also schon von sich aus ungefährlich für Fremdaufrufe.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.rpc_reset_lobby(text);
DROP FUNCTION IF EXISTS public.rpc_rematch(text);

CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code TEXT, p_player_id UUID)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 020_validate_privacy.sql
-- ============================================================
-- ============================================================
-- Migration 020: p_privacy in rpc_create_lobby validiert
-- ============================================================
-- Beim Vollständigkeits-Audit gefunden: anders als p_round_speed
-- (bereits per Allow-List auf 'fast'/'normal'/'calm' geprüft) landete
-- p_privacy ungeprüft in lobbies.privacy -- kein CHECK-Constraint,
-- jeder beliebige String wäre durchgegangen. Aktuell nicht ausnutzbar
-- (die "Public"-Option ist im Frontend noch deaktiviert, "Kommt
-- später"), aber dieselbe Inkonsistenz wie beim runden_speed-Fund
-- (Migration 011) -- jetzt einheitlich behandelt.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_create_lobby(
    p_host_name TEXT,
    p_privacy TEXT,
    p_max_players INTEGER,
    p_round_seconds INTEGER,
    p_user_id UUID DEFAULT NULL,
    p_round_speed TEXT DEFAULT 'normal'
) RETURNS TABLE(code TEXT, host_player_id UUID)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid := gen_random_uuid();
  v_code text;
  v_host_player_id uuid := gen_random_uuid();
  v_round_speed text := btrim(coalesce(p_round_speed, 'normal'));
  v_privacy text := btrim(coalesce(p_privacy, 'private'));
begin
  if v_round_speed not in ('fast', 'normal', 'calm') then
    v_round_speed := 'normal';
  end if;
  if v_privacy not in ('private', 'public') then
    v_privacy := 'private';
  end if;

  v_code := public.generate_lobby_code(4);

  insert into public.lobbies (
    id, code, host_player_id, status, privacy, max_players, round_seconds, round_speed,
    created_at, last_activity_at, host_user_id
  ) values (
    v_lobby_id, upper(v_code), v_host_player_id, 'waiting', v_privacy,
    greatest(2, least(p_max_players, 12)),
    coalesce(p_round_seconds, 25),
    v_round_speed,
    now(), now(), p_user_id
  );

  insert into public.players (id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id)
  values (gen_random_uuid(), v_lobby_id, v_host_player_id, left(trim(p_host_name), 24), false, now(), now(), p_user_id);

  return query select upper(v_code), v_host_player_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 021_enable_realtime_publication.sql
-- ============================================================
-- ============================================================
-- Migration 021: Tabellen der supabase_realtime-Publication hinzugefügt
-- ============================================================
-- Live-Test gefunden: Ready-Toggle "zögert" / reagiert verzögert.
-- Ursache: KEINE einzige Migration hat jemals eine der Tabellen, auf
-- die useLobbyRealtime.ts (lobbies, players, topic_votes) und
-- usePassAttempt.ts (pass_attempts, pass_attempt_votes) per
-- `postgres_changes` hören, der supabase_realtime-Publication
-- hinzugefügt. Der WebSocket verbindet zwar erfolgreich (der Client
-- zeigt "🟢 Live"), aber Postgres schickt für diese Tabellen NIE ein
-- Change-Event -- die App lief die ganze Zeit ausschließlich über den
-- Polling-Fallback (alle 650ms-4s, je nach Seite), nie über echtes
-- Realtime. Das erklärt die spürbare Verzögerung bei Ready-Toggle,
-- Topic-Voting, Pass-Validierung etc., die im Live-Test auffiel.
--
-- Fix: alle fünf Tabellen der Publication hinzufügen. Idempotent via
-- Check gegen pg_publication_tables (ALTER PUBLICATION ... ADD TABLE
-- kennt kein natives IF NOT EXISTS).
-- ============================================================

BEGIN;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lobbies', 'players', 'topic_votes', 'pass_attempts', 'pass_attempt_votes']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END;
$$;

COMMIT;


-- ============================================================
-- 022_fix_kick_and_leave.sql
-- ============================================================
-- ============================================================
-- Migration 022: kick_player repariert + rpc_leave_lobby ergänzt
-- ============================================================
-- Zwei Regressionen, beide durch frühere Migrationen dieser Reihe
-- verursacht und erst durch die Cheat-Probe
-- (apps/web/scripts/probe-cheats.mjs) sichtbar geworden:
--
-- 1) kick_player ist komplett kaputt:
--    Fehler "function public.rpc_reset_lobby(text) does not exist".
--    In der LIVE-Datenbank existiert ein nie ins Repo gedumpter
--    Legacy-Trigger auf public.players, der beim Statuswechsel
--    (left/kicked) rpc_reset_lobby(p_code) mit der ALTEN einarmigen
--    Signatur aufruft. Migration 019 hat genau diese Signatur
--    gedroppt -> jeder Kick schlägt seitdem fehl.
--    Fix: einarmige Variante wiederherstellen, aber für anon/
--    authenticated gesperrt. Der Legacy-Trigger läuft im
--    SECURITY-DEFINER-Kontext (Owner) und darf sie weiterhin
--    aufrufen; von außen ist sie nicht mehr erreichbar, die
--    Absicherung aus Migration 019 bleibt also wirksam.
--
-- 2) "Lobby verlassen" funktioniert seit Migration 012 nicht mehr:
--    lobby/[code]/page.tsx schreibt per
--    supabase.from("players").update({status:'left'}) direkt in die
--    Tabelle. Migration 012 hat RLS aktiviert und bewusst KEINE
--    UPDATE-Policy vergeben -> der Schreibzugriff wird mit 42501
--    abgelehnt, der Fehler im Client verschluckt (leerer catch).
--    Der Spieler bleibt als Geist "active" in der Lobby zurück.
--    Fix: rpc_leave_lobby als regulärer, geprüfter Schreibpfad.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Legacy-Kompatibilität für den Trigger: rpc_reset_lobby(text)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then return; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

-- Nur für interne Aufrufer (Legacy-Trigger laufen als Owner).
REVOKE EXECUTE ON FUNCTION public.rpc_reset_lobby(text) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- 2) Sauberer Austritts-Pfad statt direktem Tabellen-UPDATE
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_leave_lobby(p_lobby_id UUID, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_phase text;
  v_new_host uuid;
begin
  select host_player_id, phase into v_host, v_phase
  from public.lobbies where id = p_lobby_id;

  if v_host is null then raise exception 'lobby_not_found'; end if;

  update public.players
  set status = 'left', left_at = now(), ready = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';

  if not found then return; end if;

  -- Host verlässt die Lobby -> Rolle an den nächsten aktiven Spieler
  if v_host = p_player_id then
    select player_id into v_new_host
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and coalesce(is_bot, false) = false
    order by seat_index asc nulls last, joined_at asc
    limit 1;

    if v_new_host is not null then
      update public.lobbies
      set host_player_id = v_new_host, last_activity_at = now()
      where id = p_lobby_id;
    end if;
  end if;

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 023_session_tokens.sql
-- ============================================================
-- ============================================================
-- Migration 023: Session-Token gegen Identitäts-Spoofing
-- ============================================================
-- Die Cheat-Probe (apps/web/scripts/probe-cheats.mjs) hat 5 Exploits
-- nachgewiesen, alle mit derselben Wurzel: players.player_id ist für
-- jeden in der Lobby lesbar (nötig fürs UI), und JEDE RPC hat der
-- mitgeschickten ID blind vertraut. Damit konnte ein einzelner Client:
--   - den Ready-Status fremder Spieler umschalten
--   - im Namen anderer beim Topic abstimmen
--   - im Namen des Halters eine Antwort einreichen
--   - als ALLE Mitspieler gleichzeitig abstimmen (Vote-Stuffing)
--     -> Mehrheit im Alleingang erzwingen, das Kernstück der
--        Topic-Mechanik B komplett ausgehebelt
--
-- Lösung: pro Spieler ein geheimes Session-Token.
--   - Der Client erzeugt es einmal (crypto.randomUUID) und legt es
--     lokal ab; beim Join/Create wird es an die eigene Spieler-Zeile
--     gebunden.
--   - Es wird bei JEDEM Supabase-Request als Header
--     "x-kumpir-session" mitgeschickt (siehe supabaseClient.ts).
--   - Die Spalte ist per Column-Grant für anon/authenticated NICHT
--     lesbar -- Mitspieler sehen weiterhin alle anderen Felder, aber
--     niemals fremde Tokens.
--
-- Bewusst über Header statt zusätzlichem Funktionsparameter: so
-- bleibt JEDE Signatur unverändert, es muss nichts gedroppt werden.
-- Genau ein DROP hat in Migration 019 einen nicht dokumentierten
-- Legacy-Trigger zerschossen (kick_player, siehe Migration 022) --
-- dieses Risiko wird hier gar nicht erst eingegangen.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Spalte + Sichtbarkeit
-- ------------------------------------------------------------
ALTER TABLE public.players
    ADD COLUMN IF NOT EXISTS session_token UUID;

-- anon/authenticated dürfen alles sehen AUSSER session_token.
REVOKE SELECT ON public.players FROM anon, authenticated;
GRANT SELECT (
    id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id,
    seat_index, is_alive, kicked_at, is_online, status, left_at, last_pass_at,
    survival_streak, pass_count, clutch_pass_count, fastest_pass_ms,
    total_hold_ms, is_bot
) ON public.players TO anon, authenticated;


-- ------------------------------------------------------------
-- Helfer: Session prüfen
-- ------------------------------------------------------------
-- Gibt TRUE zurück, wenn der Aufrufer wirklich dieser Spieler ist.
-- Sonderfälle:
--   - Kein request.headers-Kontext (interner Aufruf aus Trigger,
--     psql, cron): erlaubt -- hier gibt es keinen Client, dem man
--     misstrauen müsste.
--   - Bots: haben keinen eigenen Browser. Die Bot-Engine läuft im
--     Host-Client (useBotEngine.ts), daher darf der Host mit seinem
--     Token stellvertretend für is_bot-Spieler handeln.
--   - Zeilen ohne Token (Altbestand vor dieser Migration): erlaubt,
--     damit laufende Partien beim Deploy nicht hart brechen. Neue
--     Joins setzen immer ein Token.
CREATE OR REPLACE FUNCTION public._verify_session(p_lobby_id UUID, p_player_id UUID)
 RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_headers text;
  v_token uuid;
  v_stored uuid;
  v_is_bot boolean;
  v_host uuid;
begin
  v_headers := current_setting('request.headers', true);
  if v_headers is null or v_headers = '' then
    return true;  -- interner Aufruf, kein Client im Spiel
  end if;

  begin
    v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
  exception when others then
    v_token := null;
  end;

  select session_token, coalesce(is_bot, false)
    into v_stored, v_is_bot
  from public.players
  where lobby_id = p_lobby_id and player_id = p_player_id;

  if not found then return false; end if;

  -- Altbestand ohne Token: nicht aussperren.
  if v_stored is null then return true; end if;

  if v_token is not null and v_token = v_stored then return true; end if;

  -- Host handelt stellvertretend für Bots.
  if v_is_bot then
    select host_player_id into v_host from public.lobbies where id = p_lobby_id;
    if v_host is not null and v_token is not null and exists (
      select 1 from public.players
      where lobby_id = p_lobby_id and player_id = v_host and session_token = v_token
    ) then
      return true;
    end if;
  end if;

  return false;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public._verify_session(uuid, uuid) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Token beim Beitreten binden
-- ------------------------------------------------------------
-- Wichtig: ein bereits gesetztes Token darf NICHT von einem fremden
-- Client überschrieben werden -- sonst könnte man einen Sitzplatz per
-- rpc_join_lobby mit bekannter player_id einfach übernehmen.
CREATE OR REPLACE FUNCTION public.rpc_join_lobby(
    p_code TEXT,
    p_player_id UUID,
    p_name TEXT,
    p_user_id UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_locked boolean;
  v_max_players int;
  v_active_count int;
  v_next_seat int;
  v_headers text;
  v_token uuid;
  v_existing uuid;
begin
  select id, locked, max_players into v_lobby_id, v_locked, v_max_players
  from public.lobbies where upper(code) = upper(p_code) limit 1;

  if v_lobby_id is null then raise exception 'lobby_not_found'; end if;
  if v_locked then raise exception 'lobby_locked'; end if;

  v_headers := current_setting('request.headers', true);
  if v_headers is not null and v_headers <> '' then
    begin
      v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
    exception when others then
      v_token := null;
    end;
  end if;

  -- Fremdübernahme eines belegten Platzes verhindern
  select session_token into v_existing
  from public.players where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_existing is not null and v_token is distinct from v_existing then
    raise exception 'identity_taken';
  end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  if v_active_count >= v_max_players then raise exception 'lobby_full'; end if;

  if p_user_id is not null then
    update public.players
    set name = left(trim(p_name), 24),
        status = 'active',
        left_at = null,
        kicked_at = null,
        last_seen_at = now(),
        session_token = coalesce(v_token, session_token)
    where lobby_id = v_lobby_id and user_id = p_user_id;

    if found then return; end if;
  end if;

  select coalesce(min(s.i), 0) into v_next_seat
  from generate_series(0, v_max_players - 1) as s(i)
  left join public.players p
    on p.lobby_id = v_lobby_id and p.seat_index = s.i and p.status = 'active'
  where p.id is null;

  insert into public.players (lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at, user_id, session_token)
  values (v_lobby_id, p_player_id, left(trim(p_name), 24), 'active', v_next_seat, now(), now(), p_user_id, v_token)
  on conflict (lobby_id, player_id) do update set
    name = excluded.name,
    status = 'active',
    left_at = null,
    kicked_at = null,
    last_seen_at = now(),
    seat_index = coalesce(public.players.seat_index, excluded.seat_index),
    user_id = coalesce(public.players.user_id, excluded.user_id),
    session_token = coalesce(public.players.session_token, excluded.session_token);
end;
$function$;


-- Host bekommt sein Token direkt beim Erstellen gebunden.
CREATE OR REPLACE FUNCTION public.rpc_create_lobby(
    p_host_name TEXT,
    p_privacy TEXT,
    p_max_players INTEGER,
    p_round_seconds INTEGER,
    p_user_id UUID DEFAULT NULL,
    p_round_speed TEXT DEFAULT 'normal'
) RETURNS TABLE(code TEXT, host_player_id UUID)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid := gen_random_uuid();
  v_code text;
  v_host_player_id uuid := gen_random_uuid();
  v_round_speed text := btrim(coalesce(p_round_speed, 'normal'));
  v_privacy text := btrim(coalesce(p_privacy, 'private'));
  v_headers text;
  v_token uuid;
begin
  if v_round_speed not in ('fast', 'normal', 'calm') then
    v_round_speed := 'normal';
  end if;
  if v_privacy not in ('private', 'public') then
    v_privacy := 'private';
  end if;

  v_headers := current_setting('request.headers', true);
  if v_headers is not null and v_headers <> '' then
    begin
      v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
    exception when others then
      v_token := null;
    end;
  end if;

  v_code := public.generate_lobby_code(4);

  insert into public.lobbies (
    id, code, host_player_id, status, privacy, max_players, round_seconds, round_speed,
    created_at, last_activity_at, host_user_id
  ) values (
    v_lobby_id, upper(v_code), v_host_player_id, 'waiting', v_privacy,
    greatest(2, least(p_max_players, 12)),
    coalesce(p_round_seconds, 25),
    v_round_speed,
    now(), now(), p_user_id
  );

  insert into public.players (id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id, session_token)
  values (gen_random_uuid(), v_lobby_id, v_host_player_id, left(trim(p_host_name), 24), false, now(), now(), p_user_id, v_token);

  return query select upper(v_code), v_host_player_id;
end;
$function$;


-- Bots erben das Token des Hosts NICHT -- _verify_session erlaubt dem
-- Host stellvertretendes Handeln über die is_bot-Sonderregel.


-- ------------------------------------------------------------
-- Geschützte Spiel-Aktionen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_toggle_ready(p_lobby_id uuid, p_player_id uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_new boolean;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  update public.players
  set ready = not coalesce(ready,false), last_seen_at = now()
  where lobby_id = p_lobby_id and player_id = p_player_id
  returning ready into v_new;

  if v_new is null then raise exception 'Player not found in lobby'; end if;

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
  return v_new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_vote_topic(p_lobby_id uuid, p_player_id uuid, p_choice integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if p_choice not in (1,2,3) then raise exception 'Invalid choice %', p_choice; end if;

  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  insert into public.topic_votes (lobby_id, player_id, choice)
  values (p_lobby_id, p_player_id, p_choice)
  on conflict (lobby_id, player_id)
  do update set choice = excluded.choice;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, coalesce(v_lobby.topic_selected, v_lobby.topic, ''))
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;
  return v_attempt;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_vote_answer(
    p_attempt_id UUID, p_voter_id UUID, p_accept BOOLEAN
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_attempt public.pass_attempts%ROWTYPE;
  v_alive int; v_needed int;
begin
  select * into v_attempt from public.pass_attempts where id = p_attempt_id for update;
  if not found then raise exception 'attempt_not_found'; end if;

  if not public._verify_session(v_attempt.lobby_id, p_voter_id) then
    raise exception 'invalid_session';
  end if;

  if v_attempt.status <> 'pending' then raise exception 'attempt_closed'; end if;
  if v_attempt.holder_player_id = p_voter_id then raise exception 'holder_cannot_vote'; end if;

  insert into public.pass_attempt_votes (attempt_id, voter_id, accept)
    values (p_attempt_id, p_voter_id, p_accept)
    on conflict (attempt_id, voter_id) do nothing;

  update public.pass_attempts
  set accept_count = (select count(*) from public.pass_attempt_votes where attempt_id = p_attempt_id and accept = true),
      reject_count = (select count(*) from public.pass_attempt_votes where attempt_id = p_attempt_id and accept = false)
  where id = p_attempt_id
  returning * into v_attempt;

  select count(*) into v_alive
  from public.players
  where lobby_id = v_attempt.lobby_id and status = 'active' and is_alive = true
    and player_id <> v_attempt.holder_player_id;

  v_needed := (v_alive / 2) + 1;

  if v_attempt.accept_count >= v_needed then
    perform public._finalize_attempt_accept(v_attempt.id);
  elsif v_attempt.reject_count >= v_needed then
    perform public._finalize_attempt_reject(v_attempt.id);
  end if;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_leave_lobby(p_lobby_id UUID, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_new_host uuid;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;

  update public.players
  set status = 'left', left_at = now(), ready = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';

  if not found then return; end if;

  if v_host = p_player_id then
    select player_id into v_new_host
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and coalesce(is_bot, false) = false
    order by seat_index asc nulls last, joined_at asc
    limit 1;

    if v_new_host is not null then
      update public.lobbies
      set host_player_id = v_new_host, last_activity_at = now()
      where id = p_lobby_id;
    end if;
  end if;

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 024_session_tokens_host_actions.sql
-- ============================================================
-- ============================================================
-- Migration 024: Session-Prüfung für Host-Aktionen
-- ============================================================
-- Migration 023 hat die Spiel-Aktionen abgesichert. Hier folgen die
-- Host-Aktionen. Sie prüfen zwar alle bereits host_player_id =
-- p_me_player_id -- aber genau diese ID ist für jeden in der Lobby
-- lesbar, das reichte also nicht: wer die Host-ID kannte, konnte
-- kicken, Host übertragen, Einstellungen ändern oder das Spiel
-- starten. Mit dem Session-Token muss man jetzt zusätzlich wirklich
-- der Host sein.
--
-- Alle Signaturen bleiben unverändert (CREATE OR REPLACE, kein DROP)
-- -- siehe Begründung in Migration 023.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.kick_player(p_lobby_id uuid, p_me_player_id uuid, p_target_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  if p_target_player_id = v_host then raise exception 'cannot_kick_host'; end if;

  update public.players
  set status = 'kicked', kicked_at = now()
  where lobby_id = p_lobby_id and player_id = p_target_player_id and status = 'active';
end;
$function$;


CREATE OR REPLACE FUNCTION public.transfer_host(p_lobby_id uuid, p_me_player_id uuid, p_new_host_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_ok boolean;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select l.host_player_id into v_host from public.lobbies l where l.id = p_lobby_id;
  if v_host is null or v_host <> p_me_player_id then raise exception 'not_host'; end if;

  select exists (
    select 1 from public.players p
    where p.lobby_id = p_lobby_id and p.player_id = p_new_host_player_id and p.status = 'active'
  ) into v_ok;

  if not v_ok then raise exception 'new_host_not_active'; end if;

  update public.lobbies set host_player_id = p_new_host_player_id where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_lobby_lock(p_lobby_id uuid, p_me_player_id uuid, p_locked boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select l.host_player_id into v_host from public.lobbies l where l.id = p_lobby_id;
  if v_host is null or v_host <> p_me_player_id then raise exception 'not_host'; end if;
  update public.lobbies set locked = p_locked where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_lobby_mode(p_lobby_id uuid, p_me_player_id uuid, p_mode text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_mode text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  v_mode := btrim(coalesce(p_mode, ''));
  if v_mode not in ('original','teleport','reverse') then raise exception 'invalid_mode'; end if;

  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_lobby_topic(p_lobby_id uuid, p_me_player_id uuid, p_topic text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_topic text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  v_topic := btrim(coalesce(p_topic, ''));
  if length(v_topic) > 60 then raise exception 'topic_too_long'; end if;

  update public.lobbies
  set topic = nullif(v_topic, ''),
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_max_players(p_lobby_id uuid, p_me_player_id uuid, p_max_players integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_active_count int;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  if p_max_players < 2 or p_max_players > 12 then raise exception 'invalid_max_players'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = p_lobby_id and status = 'active';

  if p_max_players < v_active_count then raise exception 'too_small_for_current_players'; end if;

  update public.lobbies
  set max_players = p_max_players,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host
  from public.lobbies where id = p_lobby_id for update;

  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select t.text into v_a from public.topic_pool t where t.active is true
  order by random() limit 1;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a
  order by random() limit 1;

  if v_a is null or v_b is null then raise exception 'Not enough topics in topic_pool'; end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_add_bot(
    p_lobby_id UUID, p_me_player_id UUID, p_bot_name TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_host uuid; v_max_players int; v_active_count int; v_next_seat int;
  v_bot_id uuid := gen_random_uuid();
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, max_players into v_host, v_max_players
  from public.lobbies where id = p_lobby_id;

  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  select count(*) into v_active_count from public.players where lobby_id = p_lobby_id and status = 'active';
  if v_active_count >= v_max_players then raise exception 'lobby_full'; end if;

  select coalesce(min(s.i), 0) into v_next_seat
  from generate_series(0, v_max_players - 1) as s(i)
  left join public.players p on p.lobby_id = p_lobby_id and p.seat_index = s.i and p.status = 'active'
  where p.id is null;

  insert into public.players (lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at, is_bot, ready)
  values (p_lobby_id, v_bot_id, left(trim(p_bot_name), 24), 'active', v_next_seat, now(), now(), true, true);

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
  return v_bot_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_remove_bot(
    p_lobby_id UUID, p_me_player_id UUID, p_bot_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  delete from public.players where lobby_id = p_lobby_id and player_id = p_bot_player_id and is_bot = true;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not public._verify_session(v_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code TEXT, p_player_id UUID)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_lobby_id uuid; v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not public._verify_session(v_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 025_song_category.sql
-- ============================================================
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


-- ============================================================
-- 026_music_genres.sql
-- ============================================================
-- ============================================================
-- Migration 026: Musik-Genres als wählbarer Themen-Filter
-- ============================================================
-- Drei weitere Songs-Kategorien (alle mit echten, per oEmbed
-- verifizierten Spotify-Playlists, keine erfundenen IDs):
--   - "Deutschrap Klassiker"        -> offizielle Spotify-Playlist
--     "Deutschrap: Die Klassiker" (37i9dQZF1DWSzguhfGl55y)
--   - "Englische All-Time-Hits"     -> offizielle Playlist
--     "Hit Rewind" (37i9dQZF1DX0s5kDXi1oC5)
--   - "Internationale Pop-Charts"   -> offizielle Playlist
--     "Today's Top Hits" (37i9dQZF1DXcBWIGoYBM5M)
-- ("Deutschrap-Songs" aus Migration 025 bleibt als "Deutschrap
-- Aktuell"-Pendant bestehen, verlinkt auf "Deutschrap Charts 2026".)
--
-- Damit der Host eine Lobby gezielt auf einen oder mehrere dieser
-- Genres festlegen kann (statt zufällig aus ALLEN aktiven Kategorien
-- zu ziehen), bekommt lobbies eine optionale Filter-Spalte:
--   NULL / leeres Array = wie bisher, alle aktiven Kategorien möglich
--   sonst = nur die gelisteten Kategorien kommen in die Themen-Wahl
--
-- rpc_begin_topic_vote und rpc_start_rematch_if_ready respektieren
-- den Filter beim Ziehen der zwei Zufalls-Themen. Bleibt der Filter
-- leer, ändert sich am bestehenden Verhalten nichts.
-- ============================================================

BEGIN;

INSERT INTO public.topic_pool (text, example, active)
SELECT v.text, v.example, TRUE
FROM (VALUES
    ('Deutschrap Klassiker',      'Halt dich fest'),
    ('Englische All-Time-Hits',   'Bohemian Rhapsody'),
    ('Internationale Pop-Charts', 'Espresso')
) AS v(text, example)
WHERE NOT EXISTS (
    SELECT 1 FROM public.topic_pool WHERE lower(text) = lower(v.text)
);

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS topic_filter TEXT[];

CREATE OR REPLACE FUNCTION public.set_lobby_topic_filter(
    p_lobby_id UUID, p_me_player_id UUID, p_categories TEXT[]
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_clean text[];
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  -- Nur Kategorien übernehmen, die es wirklich (aktiv) gibt.
  select coalesce(array_agg(distinct tp.text), '{}')
    into v_clean
  from public.topic_pool tp
  where tp.active is true and tp.text = any(coalesce(p_categories, '{}'));

  update public.lobbies
  set topic_filter = nullif(v_clean, '{}'),
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text; v_filter text[];
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, topic_filter into v_host, v_filter
  from public.lobbies where id = p_lobby_id for update;

  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select t.text into v_a from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_a is null or v_b is null then raise exception 'Not enough topics in topic_pool'; end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_ready_count int; v_active_count int; v_filter text[];
  v_topic_a text; v_topic_b text;
begin
  select id, topic_filter into v_lobby_id, v_filter
  from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  select count(*) into v_ready_count from public.players
  where lobby_id = v_lobby_id and status = 'active' and coalesce(ready, false) = true;

  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;
  if v_ready_count <> v_active_count then return; end if;

  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_a is null or v_topic_b is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 027_topic_answer_database.sql
-- ============================================================
-- ============================================================
-- Migration 027: Antwort-Datenbank statt Pflicht-Abstimmung für jede Antwort
-- ============================================================
-- Bisher musste JEDE Antwort per Mehrheitsvotum von den Mitspielern
-- bestätigt werden (Topic-Mechanik B) -- das bremst das Spiel aus und
-- ist bei bekannten, klar richtigen Antworten unnötig ("Eiche" bei
-- "Bäume" braucht keine Abstimmung). Jetzt gibt es pro Kategorie eine
-- Referenzliste bekannter Antworten (topic_answers): trifft die
-- eingereichte Antwort (case-insensitive) einen Eintrag, wird sie
-- SOFORT automatisch angenommen -- keine Wartezeit, kein Voting.
--
-- Antworten, die NICHT in der Liste stehen, fallen weiterhin auf das
-- bestehende Mehrheits-Voting zurück (Migration 001/018) -- das bleibt
-- die Auffang-Lösung für kreative, aber gültige Antworten, die (noch)
-- nicht in der Referenzliste stehen. Die Liste wächst mit jeder neuen
-- Kategorie/Erweiterung, ersetzt das Voting aber nicht komplett.
--
-- Seed: ~1100 Antworten über alle 54 bestehenden Kategorien (siehe
-- gen_topic_answers.py im Repo-Root), portiert aus den bisherigen
-- Bot-Antwortlisten (botAnswers.ts) und für "Bäume" (Nutzer-Beispiel)
-- deutlich auf ~50 bekannte Baumarten erweitert.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.topic_answers (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic_pool_id  UUID NOT NULL REFERENCES public.topic_pool(id) ON DELETE CASCADE,
    answer         TEXT NOT NULL,
    lower_answer   TEXT GENERATED ALWAYS AS (lower(answer)) STORED,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (topic_pool_id, lower_answer)
);

CREATE INDEX IF NOT EXISTS idx_topic_answers_topic ON public.topic_answers (topic_pool_id);

ALTER TABLE public.topic_answers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "topic_answers_read_all" ON public.topic_answers;
CREATE POLICY "topic_answers_read_all" ON public.topic_answers FOR SELECT USING (TRUE);


CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_known boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  -- Antwort-Datenbank: bekannte, korrekte Antwort -> sofort annehmen,
  -- kein Voting nötig. _finalize_attempt_accept setzt current_attempt_id
  -- selbst wieder auf null und stößt rpc_pass_potato an.
  select exists (
    select 1
    from public.topic_answers ta
    join public.topic_pool tp on tp.id = ta.topic_pool_id
    where lower(tp.text) = lower(v_topic)
      and ta.lower_answer = lower(v_clean)
  ) into v_known;

  if v_known then
    perform public._finalize_attempt_accept(v_attempt);
  end if;

  return v_attempt;
end;
$function$;

COMMIT;

BEGIN;

-- Auto-generiert aus botAnswers.ts + Erweiterungen, siehe gen_topic_answers.py im Repo-Root (kann geloescht werden)
INSERT INTO public.topic_answers (topic_pool_id, answer)
SELECT tp.id, v.answer
FROM public.topic_pool tp
JOIN (VALUES
    ('Automarken', 'BMW'),
    ('Automarken', 'Audi'),
    ('Automarken', 'Mercedes'),
    ('Automarken', 'VW'),
    ('Automarken', 'Porsche'),
    ('Automarken', 'Ferrari'),
    ('Automarken', 'Toyota'),
    ('Automarken', 'Ford'),
    ('Automarken', 'Opel'),
    ('Automarken', 'Honda'),
    ('Automarken', 'Tesla'),
    ('Automarken', 'Mazda'),
    ('Automarken', 'Nissan'),
    ('Automarken', 'Hyundai'),
    ('Automarken', 'Kia'),
    ('Automarken', 'Skoda'),
    ('Automarken', 'Seat'),
    ('Automarken', 'Renault'),
    ('Automarken', 'Peugeot'),
    ('Automarken', 'Citroen'),
    ('Automarken', 'Fiat'),
    ('Automarken', 'Volvo'),
    ('Automarken', 'Jaguar'),
    ('Automarken', 'Land Rover'),
    ('Automarken', 'Mini'),
    ('Automarken', 'Bentley'),
    ('Automarken', 'Rolls-Royce'),
    ('Automarken', 'Lamborghini'),
    ('Automarken', 'Maserati'),
    ('Automarken', 'Alfa Romeo'),
    ('Automarken', 'Subaru'),
    ('Automarken', 'Mitsubishi'),
    ('Automarken', 'Suzuki'),
    ('Automarken', 'Dacia'),
    ('Automarken', 'Chevrolet'),
    ('Automarken', 'Jeep'),
    ('Automarken', 'Chrysler'),
    ('Automarken', 'Cadillac'),
    ('Automarken', 'Lexus'),
    ('Automarken', 'Infiniti'),
    ('Automarken', 'Bugatti'),
    ('Automarken', 'Aston Martin'),
    ('Automarken', 'McLaren'),
    ('Automarken', 'Smart'),
    ('Tiere in Afrika', 'Löwe'),
    ('Tiere in Afrika', 'Elefant'),
    ('Tiere in Afrika', 'Giraffe'),
    ('Tiere in Afrika', 'Zebra'),
    ('Tiere in Afrika', 'Nashorn'),
    ('Tiere in Afrika', 'Gepard'),
    ('Tiere in Afrika', 'Hyäne'),
    ('Tiere in Afrika', 'Flusspferd'),
    ('Tiere in Afrika', 'Krokodil'),
    ('Tiere in Afrika', 'Affe'),
    ('Tiere in Afrika', 'Strauß'),
    ('Tiere in Afrika', 'Antilope'),
    ('Tiere in Afrika', 'Leopard'),
    ('Tiere in Afrika', 'Büffel'),
    ('Tiere in Afrika', 'Warzenschwein'),
    ('Tiere in Afrika', 'Gnu'),
    ('Tiere in Afrika', 'Springbock'),
    ('Tiere in Afrika', 'Schakal'),
    ('Tiere in Afrika', 'Manguste'),
    ('Tiere in Afrika', 'Pavian'),
    ('Tiere in Afrika', 'Impala'),
    ('Tiere in Afrika', 'Kudu'),
    ('Tiere in Afrika', 'Wildhund'),
    ('Tiere in Afrika', 'Erdmännchen'),
    ('Haustiere', 'Hund'),
    ('Haustiere', 'Katze'),
    ('Haustiere', 'Hamster'),
    ('Haustiere', 'Meerschweinchen'),
    ('Haustiere', 'Kaninchen'),
    ('Haustiere', 'Wellensittich'),
    ('Haustiere', 'Goldfisch'),
    ('Haustiere', 'Schildkröte'),
    ('Haustiere', 'Papagei'),
    ('Haustiere', 'Frettchen'),
    ('Haustiere', 'Chinchilla'),
    ('Haustiere', 'Ratte'),
    ('Haustiere', 'Maus'),
    ('Haustiere', 'Degu'),
    ('Haustiere', 'Kanarienvogel'),
    ('Haustiere', 'Nymphensittich'),
    ('Haustiere', 'Zwerghamster'),
    ('Haustiere', 'Gecko'),
    ('Haustiere', 'Schlange'),
    ('Fußball-Vereine', 'Bayern München'),
    ('Fußball-Vereine', 'Dortmund'),
    ('Fußball-Vereine', 'Schalke'),
    ('Fußball-Vereine', 'Real Madrid'),
    ('Fußball-Vereine', 'Barcelona'),
    ('Fußball-Vereine', 'Manchester United'),
    ('Fußball-Vereine', 'Liverpool'),
    ('Fußball-Vereine', 'Arsenal'),
    ('Fußball-Vereine', 'PSG'),
    ('Fußball-Vereine', 'Juventus'),
    ('Fußball-Vereine', 'Inter'),
    ('Fußball-Vereine', 'Köln'),
    ('Fußball-Vereine', 'Bayer Leverkusen'),
    ('Fußball-Vereine', 'RB Leipzig'),
    ('Fußball-Vereine', 'Eintracht Frankfurt'),
    ('Fußball-Vereine', 'Werder Bremen'),
    ('Fußball-Vereine', 'Hamburger SV'),
    ('Fußball-Vereine', 'Hertha BSC'),
    ('Fußball-Vereine', 'VfB Stuttgart'),
    ('Fußball-Vereine', 'Manchester City'),
    ('Fußball-Vereine', 'Chelsea'),
    ('Fußball-Vereine', 'Tottenham'),
    ('Fußball-Vereine', 'AC Milan'),
    ('Fußball-Vereine', 'Atletico Madrid'),
    ('Fußball-Vereine', 'Ajax'),
    ('Fußball-Vereine', 'Benfica'),
    ('Fußball-Vereine', 'Porto'),
    ('Länder in Europa', 'Deutschland'),
    ('Länder in Europa', 'Frankreich'),
    ('Länder in Europa', 'Italien'),
    ('Länder in Europa', 'Spanien'),
    ('Länder in Europa', 'Portugal'),
    ('Länder in Europa', 'Österreich'),
    ('Länder in Europa', 'Schweiz'),
    ('Länder in Europa', 'Polen'),
    ('Länder in Europa', 'Niederlande'),
    ('Länder in Europa', 'Belgien'),
    ('Länder in Europa', 'Schweden'),
    ('Länder in Europa', 'Norwegen'),
    ('Länder in Europa', 'Dänemark'),
    ('Länder in Europa', 'Finnland'),
    ('Länder in Europa', 'Griechenland'),
    ('Länder in Europa', 'Irland'),
    ('Länder in Europa', 'Island'),
    ('Länder in Europa', 'Kroatien'),
    ('Länder in Europa', 'Serbien'),
    ('Länder in Europa', 'Ungarn'),
    ('Länder in Europa', 'Tschechien'),
    ('Länder in Europa', 'Slowakei'),
    ('Länder in Europa', 'Slowenien'),
    ('Länder in Europa', 'Rumänien'),
    ('Länder in Europa', 'Bulgarien'),
    ('Länder in Europa', 'Litauen'),
    ('Länder in Europa', 'Lettland'),
    ('Länder in Europa', 'Estland'),
    ('Länder in Europa', 'Luxemburg'),
    ('Länder in Europa', 'Malta'),
    ('Länder in Europa', 'Zypern'),
    ('Länder in Europa', 'Albanien'),
    ('Länder in Europa', 'Montenegro'),
    ('Länder in Europa', 'Bosnien'),
    ('Länder in Europa', 'Nordmazedonien'),
    ('Länder in Europa', 'Moldau'),
    ('Länder in Europa', 'Ukraine'),
    ('Länder in Europa', 'Weißrussland'),
    ('Länder in Europa', 'Russland'),
    ('Länder in Europa', 'Türkei'),
    ('Länder in Europa', 'Monaco'),
    ('Länder in Europa', 'Liechtenstein'),
    ('Länder in Europa', 'Andorra'),
    ('Länder in Europa', 'San Marino'),
    ('Länder in Europa', 'Vatikanstadt'),
    ('Länder in Europa', 'Kosovo'),
    ('Länder in Europa', 'Großbritannien'),
    ('Hauptstädte', 'Berlin'),
    ('Hauptstädte', 'Paris'),
    ('Hauptstädte', 'Madrid'),
    ('Hauptstädte', 'Rom'),
    ('Hauptstädte', 'Wien'),
    ('Hauptstädte', 'Bern'),
    ('Hauptstädte', 'Warschau'),
    ('Hauptstädte', 'Amsterdam'),
    ('Hauptstädte', 'Brüssel'),
    ('Hauptstädte', 'Stockholm'),
    ('Hauptstädte', 'Oslo'),
    ('Hauptstädte', 'London'),
    ('Hauptstädte', 'Kopenhagen'),
    ('Hauptstädte', 'Helsinki'),
    ('Hauptstädte', 'Athen'),
    ('Hauptstädte', 'Dublin'),
    ('Hauptstädte', 'Reykjavik'),
    ('Hauptstädte', 'Zagreb'),
    ('Hauptstädte', 'Belgrad'),
    ('Hauptstädte', 'Budapest'),
    ('Hauptstädte', 'Prag'),
    ('Hauptstädte', 'Bratislava'),
    ('Hauptstädte', 'Ljubljana'),
    ('Hauptstädte', 'Bukarest'),
    ('Hauptstädte', 'Sofia'),
    ('Hauptstädte', 'Vilnius'),
    ('Hauptstädte', 'Riga'),
    ('Hauptstädte', 'Tallinn'),
    ('Hauptstädte', 'Luxemburg'),
    ('Hauptstädte', 'Valletta'),
    ('Hauptstädte', 'Nikosia'),
    ('Hauptstädte', 'Tirana'),
    ('Hauptstädte', 'Podgorica'),
    ('Hauptstädte', 'Sarajevo'),
    ('Hauptstädte', 'Skopje'),
    ('Hauptstädte', 'Chisinau'),
    ('Hauptstädte', 'Kiew'),
    ('Hauptstädte', 'Minsk'),
    ('Hauptstädte', 'Moskau'),
    ('Hauptstädte', 'Ankara'),
    ('Obst', 'Apfel'),
    ('Obst', 'Birne'),
    ('Obst', 'Banane'),
    ('Obst', 'Orange'),
    ('Obst', 'Erdbeere'),
    ('Obst', 'Kirsche'),
    ('Obst', 'Pfirsich'),
    ('Obst', 'Mango'),
    ('Obst', 'Ananas'),
    ('Obst', 'Traube'),
    ('Obst', 'Wassermelone'),
    ('Obst', 'Kiwi'),
    ('Obst', 'Zitrone'),
    ('Obst', 'Limette'),
    ('Obst', 'Grapefruit'),
    ('Obst', 'Mandarine'),
    ('Obst', 'Pflaume'),
    ('Obst', 'Aprikose'),
    ('Obst', 'Feige'),
    ('Obst', 'Granatapfel'),
    ('Obst', 'Papaya'),
    ('Obst', 'Litschi'),
    ('Obst', 'Physalis'),
    ('Obst', 'Heidelbeere'),
    ('Obst', 'Himbeere'),
    ('Obst', 'Brombeere'),
    ('Obst', 'Johannisbeere'),
    ('Obst', 'Stachelbeere'),
    ('Obst', 'Quitte'),
    ('Obst', 'Nektarine'),
    ('Obst', 'Maracuja'),
    ('Obst', 'Guave'),
    ('Obst', 'Dattel'),
    ('Obst', 'Kaki'),
    ('Gemüse', 'Karotte'),
    ('Gemüse', 'Tomate'),
    ('Gemüse', 'Gurke'),
    ('Gemüse', 'Salat'),
    ('Gemüse', 'Paprika'),
    ('Gemüse', 'Brokkoli'),
    ('Gemüse', 'Spinat'),
    ('Gemüse', 'Zwiebel'),
    ('Gemüse', 'Kartoffel'),
    ('Gemüse', 'Aubergine'),
    ('Gemüse', 'Zucchini'),
    ('Gemüse', 'Kohl'),
    ('Gemüse', 'Blumenkohl'),
    ('Gemüse', 'Rosenkohl'),
    ('Gemüse', 'Lauch'),
    ('Gemüse', 'Sellerie'),
    ('Gemüse', 'Radieschen'),
    ('Gemüse', 'Rote Bete'),
    ('Gemüse', 'Kürbis'),
    ('Gemüse', 'Mais'),
    ('Gemüse', 'Erbsen'),
    ('Gemüse', 'Bohnen'),
    ('Gemüse', 'Fenchel'),
    ('Gemüse', 'Rettich'),
    ('Gemüse', 'Spargel'),
    ('Farben', 'Rot'),
    ('Farben', 'Blau'),
    ('Farben', 'Grün'),
    ('Farben', 'Gelb'),
    ('Farben', 'Schwarz'),
    ('Farben', 'Weiß'),
    ('Farben', 'Orange'),
    ('Farben', 'Lila'),
    ('Farben', 'Rosa'),
    ('Farben', 'Braun'),
    ('Farben', 'Grau'),
    ('Farben', 'Türkis'),
    ('Farben', 'Violett'),
    ('Farben', 'Pink'),
    ('Farben', 'Beige'),
    ('Farben', 'Gold'),
    ('Farben', 'Silber'),
    ('Farben', 'Bronze'),
    ('Farben', 'Magenta'),
    ('Farben', 'Cyan'),
    ('Farben', 'Lindgrün'),
    ('Farben', 'Bordeaux'),
    ('Farben', 'Petrol'),
    ('Farben', 'Khaki'),
    ('Filme', 'Inception'),
    ('Filme', 'Titanic'),
    ('Filme', 'Avatar'),
    ('Filme', 'Matrix'),
    ('Filme', 'Joker'),
    ('Filme', 'Gladiator'),
    ('Filme', 'Interstellar'),
    ('Filme', 'Forrest Gump'),
    ('Filme', 'Pulp Fiction'),
    ('Filme', 'Sieben'),
    ('Filme', 'Der Pate'),
    ('Filme', 'Fight Club'),
    ('Filme', 'Herr der Ringe'),
    ('Filme', 'Star Wars'),
    ('Filme', 'Jurassic Park'),
    ('Filme', 'Die Verurteilten'),
    ('Filme', 'Schindlers Liste'),
    ('Filme', 'Die Dunkle Ritter'),
    ('Filme', 'Fluch der Karibik'),
    ('Filme', 'Harry Potter'),
    ('Serien', 'Breaking Bad'),
    ('Serien', 'Game of Thrones'),
    ('Serien', 'Friends'),
    ('Serien', 'Stranger Things'),
    ('Serien', 'The Office'),
    ('Serien', 'Lost'),
    ('Serien', 'Money Heist'),
    ('Serien', 'Dark'),
    ('Serien', 'Witcher'),
    ('Serien', 'Vikings'),
    ('Serien', 'Better Call Saul'),
    ('Serien', 'The Crown'),
    ('Serien', 'Suits'),
    ('Serien', 'Peaky Blinders'),
    ('Serien', 'How I Met Your Mother'),
    ('Serien', 'The Big Bang Theory'),
    ('Serien', 'Narcos'),
    ('Serien', 'Sherlock'),
    ('Musiker/Bands', 'Coldplay'),
    ('Musiker/Bands', 'Beatles'),
    ('Musiker/Bands', 'Queen'),
    ('Musiker/Bands', 'Eminem'),
    ('Musiker/Bands', 'Drake'),
    ('Musiker/Bands', 'Adele'),
    ('Musiker/Bands', 'Ed Sheeran'),
    ('Musiker/Bands', 'Rammstein'),
    ('Musiker/Bands', 'Metallica'),
    ('Musiker/Bands', 'AC/DC'),
    ('Musiker/Bands', 'Linkin Park'),
    ('Musiker/Bands', 'Nirvana'),
    ('Musiker/Bands', 'Pink Floyd'),
    ('Musiker/Bands', 'Rolling Stones'),
    ('Musiker/Bands', 'U2'),
    ('Musiker/Bands', 'Guns N'' Roses'),
    ('Musiker/Bands', 'Red Hot Chili Peppers'),
    ('Musiker/Bands', 'Green Day'),
    ('Musiker/Bands', 'Foo Fighters'),
    ('Musiker/Bands', 'Muse'),
    ('Schauspieler', 'Tom Hanks'),
    ('Schauspieler', 'Brad Pitt'),
    ('Schauspieler', 'Leonardo DiCaprio'),
    ('Schauspieler', 'Will Smith'),
    ('Schauspieler', 'Morgan Freeman'),
    ('Schauspieler', 'Denzel Washington'),
    ('Schauspieler', 'Robert De Niro'),
    ('Schauspieler', 'Al Pacino'),
    ('Schauspieler', 'Johnny Depp'),
    ('Schauspieler', 'Tom Cruise'),
    ('Schauspieler', 'Matt Damon'),
    ('Schauspieler', 'Christian Bale'),
    ('Schauspieler', 'Ryan Gosling'),
    ('Schauspieler', 'Scarlett Johansson'),
    ('Schauspieler', 'Angelina Jolie'),
    ('Schauspieler', 'Meryl Streep'),
    ('Berufe', 'Arzt'),
    ('Berufe', 'Lehrer'),
    ('Berufe', 'Anwalt'),
    ('Berufe', 'Ingenieur'),
    ('Berufe', 'Bäcker'),
    ('Berufe', 'Koch'),
    ('Berufe', 'Polizist'),
    ('Berufe', 'Feuerwehrmann'),
    ('Berufe', 'Pilot'),
    ('Berufe', 'Friseur'),
    ('Berufe', 'Mechaniker'),
    ('Berufe', 'Krankenschwester'),
    ('Berufe', 'Elektriker'),
    ('Berufe', 'Klempner'),
    ('Berufe', 'Architekt'),
    ('Berufe', 'Journalist'),
    ('Berufe', 'Programmierer'),
    ('Berufe', 'Buchhalter'),
    ('Berufe', 'Verkäufer'),
    ('Berufe', 'Gärtner'),
    ('Körperteile', 'Knie'),
    ('Körperteile', 'Arm'),
    ('Körperteile', 'Bein'),
    ('Körperteile', 'Hand'),
    ('Körperteile', 'Fuß'),
    ('Körperteile', 'Kopf'),
    ('Körperteile', 'Nase'),
    ('Körperteile', 'Auge'),
    ('Körperteile', 'Ohr'),
    ('Körperteile', 'Mund'),
    ('Körperteile', 'Finger'),
    ('Körperteile', 'Ellenbogen'),
    ('Körperteile', 'Schulter'),
    ('Körperteile', 'Rücken'),
    ('Körperteile', 'Bauch'),
    ('Körperteile', 'Hüfte'),
    ('Körperteile', 'Knöchel'),
    ('Körperteile', 'Zehe'),
    ('Körperteile', 'Kinn'),
    ('Körperteile', 'Stirn'),
    ('Körperteile', 'Wange'),
    ('Körperteile', 'Hals'),
    ('Körperteile', 'Handgelenk'),
    ('Dinge in der Küche', 'Messer'),
    ('Dinge in der Küche', 'Gabel'),
    ('Dinge in der Küche', 'Löffel'),
    ('Dinge in der Küche', 'Teller'),
    ('Dinge in der Küche', 'Topf'),
    ('Dinge in der Küche', 'Pfanne'),
    ('Dinge in der Küche', 'Herd'),
    ('Dinge in der Küche', 'Kühlschrank'),
    ('Dinge in der Küche', 'Mikrowelle'),
    ('Dinge in der Küche', 'Tasse'),
    ('Dinge in der Küche', 'Glas'),
    ('Dinge in der Küche', 'Schneidebrett'),
    ('Dinge in der Küche', 'Sieb'),
    ('Dinge in der Küche', 'Schüssel'),
    ('Dinge in der Küche', 'Backofen'),
    ('Dinge in der Küche', 'Toaster'),
    ('Dinge in der Küche', 'Wasserkocher'),
    ('Dinge in der Küche', 'Reibe'),
    ('Dinge in der Küche', 'Schöpfkelle'),
    ('Dinge in der Küche', 'Spülmaschine'),
    ('Dinge im Supermarkt', 'Brot'),
    ('Dinge im Supermarkt', 'Milch'),
    ('Dinge im Supermarkt', 'Käse'),
    ('Dinge im Supermarkt', 'Butter'),
    ('Dinge im Supermarkt', 'Joghurt'),
    ('Dinge im Supermarkt', 'Eier'),
    ('Dinge im Supermarkt', 'Reis'),
    ('Dinge im Supermarkt', 'Nudeln'),
    ('Dinge im Supermarkt', 'Mehl'),
    ('Dinge im Supermarkt', 'Zucker'),
    ('Dinge im Supermarkt', 'Salz'),
    ('Dinge im Supermarkt', 'Öl'),
    ('Dinge im Supermarkt', 'Kaffee'),
    ('Dinge im Supermarkt', 'Tee'),
    ('Dinge im Supermarkt', 'Gemüse'),
    ('Dinge im Supermarkt', 'Obst'),
    ('Dinge im Supermarkt', 'Fleisch'),
    ('Dinge im Supermarkt', 'Fisch'),
    ('Dinge im Supermarkt', 'Konserven'),
    ('Dinge im Supermarkt', 'Süßigkeiten'),
    ('Dinge im Supermarkt', 'Tiefkühlkost'),
    ('Dinge im Supermarkt', 'Waschmittel'),
    ('Getränke', 'Cola'),
    ('Getränke', 'Wasser'),
    ('Getränke', 'Saft'),
    ('Getränke', 'Tee'),
    ('Getränke', 'Kaffee'),
    ('Getränke', 'Limonade'),
    ('Getränke', 'Eistee'),
    ('Getränke', 'Smoothie'),
    ('Getränke', 'Milch'),
    ('Getränke', 'Bier'),
    ('Getränke', 'Wein'),
    ('Getränke', 'Sekt'),
    ('Getränke', 'Whisky'),
    ('Getränke', 'Wodka'),
    ('Getränke', 'Rum'),
    ('Getränke', 'Gin'),
    ('Getränke', 'Energy Drink'),
    ('Getränke', 'Mineralwasser'),
    ('Getränke', 'Kakao'),
    ('Getränke', 'Buttermilch'),
    ('Alkoholische Getränke', 'Bier'),
    ('Alkoholische Getränke', 'Wein'),
    ('Alkoholische Getränke', 'Wodka'),
    ('Alkoholische Getränke', 'Whisky'),
    ('Alkoholische Getränke', 'Rum'),
    ('Alkoholische Getränke', 'Gin'),
    ('Alkoholische Getränke', 'Tequila'),
    ('Alkoholische Getränke', 'Sekt'),
    ('Alkoholische Getränke', 'Schnaps'),
    ('Alkoholische Getränke', 'Likör'),
    ('Alkoholische Getränke', 'Cocktail'),
    ('Alkoholische Getränke', 'Cognac'),
    ('Alkoholische Getränke', 'Brandy'),
    ('Alkoholische Getränke', 'Grappa'),
    ('Alkoholische Getränke', 'Absinth'),
    ('Alkoholische Getränke', 'Aperol'),
    ('Alkoholische Getränke', 'Prosecco'),
    ('Alkoholische Getränke', 'Jägermeister'),
    ('Alkoholische Getränke', 'Baileys'),
    ('Fast Food', 'Pizza'),
    ('Fast Food', 'Burger'),
    ('Fast Food', 'Pommes'),
    ('Fast Food', 'Döner'),
    ('Fast Food', 'Hotdog'),
    ('Fast Food', 'Sandwich'),
    ('Fast Food', 'Wrap'),
    ('Fast Food', 'Nuggets'),
    ('Fast Food', 'Salat'),
    ('Fast Food', 'Sushi'),
    ('Fast Food', 'Kebab'),
    ('Fast Food', 'Currywurst'),
    ('Fast Food', 'Falafel'),
    ('Fast Food', 'Burrito'),
    ('Fast Food', 'Taco'),
    ('Fast Food', 'Nachos'),
    ('Fast Food', 'Chicken Wings'),
    ('Schulfächer', 'Mathe'),
    ('Schulfächer', 'Deutsch'),
    ('Schulfächer', 'Englisch'),
    ('Schulfächer', 'Geschichte'),
    ('Schulfächer', 'Geographie'),
    ('Schulfächer', 'Biologie'),
    ('Schulfächer', 'Chemie'),
    ('Schulfächer', 'Physik'),
    ('Schulfächer', 'Sport'),
    ('Schulfächer', 'Kunst'),
    ('Schulfächer', 'Musik'),
    ('Schulfächer', 'Religion'),
    ('Schulfächer', 'Ethik'),
    ('Schulfächer', 'Informatik'),
    ('Schulfächer', 'Französisch'),
    ('Schulfächer', 'Spanisch'),
    ('Schulfächer', 'Latein'),
    ('Schulfächer', 'Politik'),
    ('Schulfächer', 'Sozialkunde'),
    ('Schulfächer', 'Wirtschaft'),
    ('Sportarten', 'Tennis'),
    ('Sportarten', 'Fußball'),
    ('Sportarten', 'Basketball'),
    ('Sportarten', 'Volleyball'),
    ('Sportarten', 'Schwimmen'),
    ('Sportarten', 'Boxen'),
    ('Sportarten', 'Golf'),
    ('Sportarten', 'Schach'),
    ('Sportarten', 'Skifahren'),
    ('Sportarten', 'Surfen'),
    ('Sportarten', 'Klettern'),
    ('Sportarten', 'Handball'),
    ('Sportarten', 'Leichtathletik'),
    ('Sportarten', 'Turnen'),
    ('Sportarten', 'Radfahren'),
    ('Sportarten', 'Judo'),
    ('Sportarten', 'Karate'),
    ('Sportarten', 'Eishockey'),
    ('Sportarten', 'Rudern'),
    ('Sportarten', 'Reiten'),
    ('Sportarten', 'Segeln'),
    ('Musikinstrumente', 'Gitarre'),
    ('Musikinstrumente', 'Klavier'),
    ('Musikinstrumente', 'Geige'),
    ('Musikinstrumente', 'Trommel'),
    ('Musikinstrumente', 'Flöte'),
    ('Musikinstrumente', 'Saxophon'),
    ('Musikinstrumente', 'Trompete'),
    ('Musikinstrumente', 'Bass'),
    ('Musikinstrumente', 'Cello'),
    ('Musikinstrumente', 'Harmonika'),
    ('Musikinstrumente', 'Klarinette'),
    ('Musikinstrumente', 'Posaune'),
    ('Musikinstrumente', 'Harfe'),
    ('Musikinstrumente', 'Ukulele'),
    ('Musikinstrumente', 'Akkordeon'),
    ('Musikinstrumente', 'Orgel'),
    ('Musikinstrumente', 'Schlagzeug'),
    ('Musikinstrumente', 'Tuba'),
    ('Musikinstrumente', 'Oboe'),
    ('Bundesländer', 'Bayern'),
    ('Bundesländer', 'Berlin'),
    ('Bundesländer', 'Hamburg'),
    ('Bundesländer', 'Hessen'),
    ('Bundesländer', 'Sachsen'),
    ('Bundesländer', 'Thüringen'),
    ('Bundesländer', 'Bremen'),
    ('Bundesländer', 'Saarland'),
    ('Bundesländer', 'Brandenburg'),
    ('Bundesländer', 'Schleswig-Holstein'),
    ('Bundesländer', 'Niedersachsen'),
    ('Bundesländer', 'Baden-Württemberg'),
    ('Bundesländer', 'Nordrhein-Westfalen'),
    ('Bundesländer', 'Rheinland-Pfalz'),
    ('Bundesländer', 'Mecklenburg-Vorpommern'),
    ('Bundesländer', 'Sachsen-Anhalt'),
    ('Deutsche Städte', 'Hamburg'),
    ('Deutsche Städte', 'München'),
    ('Deutsche Städte', 'Köln'),
    ('Deutsche Städte', 'Frankfurt'),
    ('Deutsche Städte', 'Stuttgart'),
    ('Deutsche Städte', 'Düsseldorf'),
    ('Deutsche Städte', 'Leipzig'),
    ('Deutsche Städte', 'Dortmund'),
    ('Deutsche Städte', 'Essen'),
    ('Deutsche Städte', 'Bremen'),
    ('Deutsche Städte', 'Hannover'),
    ('Deutsche Städte', 'Nürnberg'),
    ('Deutsche Städte', 'Duisburg'),
    ('Deutsche Städte', 'Bochum'),
    ('Deutsche Städte', 'Wuppertal'),
    ('Deutsche Städte', 'Bielefeld'),
    ('Deutsche Städte', 'Bonn'),
    ('Deutsche Städte', 'Mannheim'),
    ('Deutsche Städte', 'Karlsruhe'),
    ('Deutsche Städte', 'Wiesbaden'),
    ('Deutsche Städte', 'Münster'),
    ('Deutsche Städte', 'Augsburg'),
    ('Deutsche Städte', 'Kiel'),
    ('Deutsche Städte', 'Dresden'),
    ('Großstädte weltweit', 'Tokio'),
    ('Großstädte weltweit', 'New York'),
    ('Großstädte weltweit', 'London'),
    ('Großstädte weltweit', 'Paris'),
    ('Großstädte weltweit', 'Istanbul'),
    ('Großstädte weltweit', 'Moskau'),
    ('Großstädte weltweit', 'Dubai'),
    ('Großstädte weltweit', 'Sydney'),
    ('Großstädte weltweit', 'Rio'),
    ('Großstädte weltweit', 'Kairo'),
    ('Großstädte weltweit', 'Bangkok'),
    ('Großstädte weltweit', 'Mumbai'),
    ('Großstädte weltweit', 'Los Angeles'),
    ('Großstädte weltweit', 'Chicago'),
    ('Großstädte weltweit', 'Toronto'),
    ('Großstädte weltweit', 'Mexiko-Stadt'),
    ('Großstädte weltweit', 'Sao Paulo'),
    ('Großstädte weltweit', 'Buenos Aires'),
    ('Großstädte weltweit', 'Shanghai'),
    ('Großstädte weltweit', 'Peking'),
    ('Großstädte weltweit', 'Seoul'),
    ('Großstädte weltweit', 'Singapur'),
    ('Großstädte weltweit', 'Hongkong'),
    ('Flüsse', 'Rhein'),
    ('Flüsse', 'Elbe'),
    ('Flüsse', 'Donau'),
    ('Flüsse', 'Main'),
    ('Flüsse', 'Mosel'),
    ('Flüsse', 'Nil'),
    ('Flüsse', 'Amazonas'),
    ('Flüsse', 'Mississippi'),
    ('Flüsse', 'Themse'),
    ('Flüsse', 'Seine'),
    ('Flüsse', 'Weser'),
    ('Flüsse', 'Oder'),
    ('Flüsse', 'Spree'),
    ('Flüsse', 'Neckar'),
    ('Flüsse', 'Isar'),
    ('Flüsse', 'Po'),
    ('Flüsse', 'Rhone'),
    ('Flüsse', 'Wolga'),
    ('Flüsse', 'Jangtse'),
    ('Flüsse', 'Ganges'),
    ('Berge', 'Mount Everest'),
    ('Berge', 'K2'),
    ('Berge', 'Matterhorn'),
    ('Berge', 'Zugspitze'),
    ('Berge', 'Brocken'),
    ('Berge', 'Kilimanjaro'),
    ('Berge', 'Mont Blanc'),
    ('Berge', 'Eiger'),
    ('Berge', 'Watzmann'),
    ('Berge', 'Großglockner'),
    ('Berge', 'Vesuv'),
    ('Berge', 'Ätna'),
    ('Berge', 'Feldberg'),
    ('Berge', 'Wank'),
    ('Berge', 'Nanga Parbat'),
    ('Berge', 'Annapurna'),
    ('Berge', 'Elbrus'),
    ('Meere und Ozeane', 'Atlantik'),
    ('Meere und Ozeane', 'Pazifik'),
    ('Meere und Ozeane', 'Mittelmeer'),
    ('Meere und Ozeane', 'Nordsee'),
    ('Meere und Ozeane', 'Ostsee'),
    ('Meere und Ozeane', 'Indischer Ozean'),
    ('Meere und Ozeane', 'Karibik'),
    ('Meere und Ozeane', 'Rotes Meer'),
    ('Meere und Ozeane', 'Schwarzes Meer'),
    ('Meere und Ozeane', 'Arktischer Ozean'),
    ('Meere und Ozeane', 'Ärmelkanal'),
    ('Meere und Ozeane', 'Adriatisches Meer'),
    ('Meere und Ozeane', 'Ägäisches Meer'),
    ('Comic-Helden', 'Spider-Man'),
    ('Comic-Helden', 'Batman'),
    ('Comic-Helden', 'Superman'),
    ('Comic-Helden', 'Iron Man'),
    ('Comic-Helden', 'Hulk'),
    ('Comic-Helden', 'Thor'),
    ('Comic-Helden', 'Captain America'),
    ('Comic-Helden', 'Wonder Woman'),
    ('Comic-Helden', 'Flash'),
    ('Comic-Helden', 'Aquaman'),
    ('Comic-Helden', 'Black Panther'),
    ('Comic-Helden', 'Wolverine'),
    ('Comic-Helden', 'Deadpool'),
    ('Comic-Helden', 'Green Lantern'),
    ('Comic-Helden', 'Doctor Strange'),
    ('Comic-Helden', 'Ant-Man'),
    ('Comic-Helden', 'Black Widow'),
    ('Disney-Filme', 'Frozen'),
    ('Disney-Filme', 'Bambi'),
    ('Disney-Filme', 'Aladdin'),
    ('Disney-Filme', 'Cars'),
    ('Disney-Filme', 'Findet Nemo'),
    ('Disney-Filme', 'Mulan'),
    ('Disney-Filme', 'Moana'),
    ('Disney-Filme', 'Tarzan'),
    ('Disney-Filme', 'Pocahontas'),
    ('Disney-Filme', 'Encanto'),
    ('Disney-Filme', 'Der König der Löwen'),
    ('Disney-Filme', 'Die Schöne und das Biest'),
    ('Disney-Filme', 'Arielle'),
    ('Disney-Filme', 'Toy Story'),
    ('Disney-Filme', 'Cinderella'),
    ('Disney-Filme', 'Dornröschen'),
    ('Disney-Filme', 'Zoomania'),
    ('Videospiele', 'Mario Kart'),
    ('Videospiele', 'FIFA'),
    ('Videospiele', 'Minecraft'),
    ('Videospiele', 'Fortnite'),
    ('Videospiele', 'Tetris'),
    ('Videospiele', 'Pokemon'),
    ('Videospiele', 'GTA'),
    ('Videospiele', 'Zelda'),
    ('Videospiele', 'Call of Duty'),
    ('Videospiele', 'Witcher'),
    ('Videospiele', 'Among Us'),
    ('Videospiele', 'League of Legends'),
    ('Videospiele', 'Counter-Strike'),
    ('Videospiele', 'Valorant'),
    ('Videospiele', 'Overwatch'),
    ('Videospiele', 'Red Dead Redemption'),
    ('Videospiele', 'Cyberpunk 2077'),
    ('Videospiele', 'The Sims'),
    ('Fast-Food-Ketten', 'McDonalds'),
    ('Fast-Food-Ketten', 'Burger King'),
    ('Fast-Food-Ketten', 'KFC'),
    ('Fast-Food-Ketten', 'Subway'),
    ('Fast-Food-Ketten', 'Starbucks'),
    ('Fast-Food-Ketten', 'Pizza Hut'),
    ('Fast-Food-Ketten', 'Domino''s'),
    ('Fast-Food-Ketten', 'Vapiano'),
    ('Fast-Food-Ketten', 'Nordsee'),
    ('Fast-Food-Ketten', 'Five Guys'),
    ('Fast-Food-Ketten', 'Wendy''s'),
    ('Fast-Food-Ketten', 'Taco Bell'),
    ('Fast-Food-Ketten', 'Dunkin Donuts'),
    ('Kleidungsstücke', 'Hose'),
    ('Kleidungsstücke', 'Hemd'),
    ('Kleidungsstücke', 'T-Shirt'),
    ('Kleidungsstücke', 'Jacke'),
    ('Kleidungsstücke', 'Pullover'),
    ('Kleidungsstücke', 'Rock'),
    ('Kleidungsstücke', 'Kleid'),
    ('Kleidungsstücke', 'Socken'),
    ('Kleidungsstücke', 'Shorts'),
    ('Kleidungsstücke', 'Mantel'),
    ('Kleidungsstücke', 'Bluse'),
    ('Kleidungsstücke', 'Weste'),
    ('Kleidungsstücke', 'Schal'),
    ('Kleidungsstücke', 'Handschuhe'),
    ('Kleidungsstücke', 'Mütze'),
    ('Kleidungsstücke', 'Anzug'),
    ('Kleidungsstücke', 'Jeans'),
    ('Kleidungsstücke', 'Leggings'),
    ('Kleidungsstücke', 'Cardigan'),
    ('Schuh-Arten', 'Sneaker'),
    ('Schuh-Arten', 'Stiefel'),
    ('Schuh-Arten', 'Sandalen'),
    ('Schuh-Arten', 'Pumps'),
    ('Schuh-Arten', 'Flip-Flops'),
    ('Schuh-Arten', 'Hausschuhe'),
    ('Schuh-Arten', 'Wanderschuhe'),
    ('Schuh-Arten', 'Ballerinas'),
    ('Schuh-Arten', 'High Heels'),
    ('Schuh-Arten', 'Loafer'),
    ('Schuh-Arten', 'Espadrilles'),
    ('Schuh-Arten', 'Gummistiefel'),
    ('Schuh-Arten', 'Chucks'),
    ('Wetter-Phänomene', 'Regen'),
    ('Wetter-Phänomene', 'Schnee'),
    ('Wetter-Phänomene', 'Hagel'),
    ('Wetter-Phänomene', 'Nebel'),
    ('Wetter-Phänomene', 'Sturm'),
    ('Wetter-Phänomene', 'Gewitter'),
    ('Wetter-Phänomene', 'Sonnenschein'),
    ('Wetter-Phänomene', 'Wind'),
    ('Wetter-Phänomene', 'Tornado'),
    ('Wetter-Phänomene', 'Eis'),
    ('Wetter-Phänomene', 'Orkan'),
    ('Wetter-Phänomene', 'Blitz'),
    ('Wetter-Phänomene', 'Donner'),
    ('Wetter-Phänomene', 'Frost'),
    ('Wetter-Phänomene', 'Tau'),
    ('Wetter-Phänomene', 'Regenbogen'),
    ('Blumen', 'Rose'),
    ('Blumen', 'Tulpe'),
    ('Blumen', 'Sonnenblume'),
    ('Blumen', 'Margerite'),
    ('Blumen', 'Lilie'),
    ('Blumen', 'Veilchen'),
    ('Blumen', 'Nelke'),
    ('Blumen', 'Hyazinthe'),
    ('Blumen', 'Orchidee'),
    ('Blumen', 'Krokus'),
    ('Blumen', 'Narzisse'),
    ('Blumen', 'Gänseblümchen'),
    ('Blumen', 'Mohnblume'),
    ('Blumen', 'Dahlie'),
    ('Blumen', 'Chrysantheme'),
    ('Blumen', 'Lavendel'),
    ('Blumen', 'Iris'),
    ('Blumen', 'Anemone'),
    ('Blumen', 'Löwenzahn'),
    ('Bäume', 'Eiche'),
    ('Bäume', 'Buche'),
    ('Bäume', 'Birke'),
    ('Bäume', 'Kiefer'),
    ('Bäume', 'Tanne'),
    ('Bäume', 'Linde'),
    ('Bäume', 'Ahorn'),
    ('Bäume', 'Kastanie'),
    ('Bäume', 'Esche'),
    ('Bäume', 'Ulme'),
    ('Bäume', 'Fichte'),
    ('Bäume', 'Weide'),
    ('Bäume', 'Pappel'),
    ('Bäume', 'Erle'),
    ('Bäume', 'Lärche'),
    ('Bäume', 'Douglasie'),
    ('Bäume', 'Eibe'),
    ('Bäume', 'Robinie'),
    ('Bäume', 'Walnussbaum'),
    ('Bäume', 'Haselnussbaum'),
    ('Bäume', 'Platane'),
    ('Bäume', 'Zeder'),
    ('Bäume', 'Zypresse'),
    ('Bäume', 'Mammutbaum'),
    ('Bäume', 'Ginkgo'),
    ('Bäume', 'Rotbuche'),
    ('Bäume', 'Hainbuche'),
    ('Bäume', 'Eberesche'),
    ('Bäume', 'Weißdorn'),
    ('Bäume', 'Holunder'),
    ('Bäume', 'Apfelbaum'),
    ('Bäume', 'Birnbaum'),
    ('Bäume', 'Kirschbaum'),
    ('Bäume', 'Pflaumenbaum'),
    ('Bäume', 'Olivenbaum'),
    ('Bäume', 'Zitronenbaum'),
    ('Bäume', 'Mangobaum'),
    ('Bäume', 'Kokospalme'),
    ('Bäume', 'Dattelpalme'),
    ('Bäume', 'Bananenstaude'),
    ('Bäume', 'Bergahorn'),
    ('Bäume', 'Spitzahorn'),
    ('Bäume', 'Flatterulme'),
    ('Bäume', 'Traubeneiche'),
    ('Bäume', 'Stieleiche'),
    ('Bäume', 'Moorbirke'),
    ('Bäume', 'Sandbirke'),
    ('Bäume', 'Trauerweide'),
    ('Bäume', 'Korkeiche'),
    ('Bäume', 'Baobab'),
    ('Fahrzeuge', 'Bus'),
    ('Fahrzeuge', 'Auto'),
    ('Fahrzeuge', 'Fahrrad'),
    ('Fahrzeuge', 'Motorrad'),
    ('Fahrzeuge', 'LKW'),
    ('Fahrzeuge', 'Zug'),
    ('Fahrzeuge', 'U-Bahn'),
    ('Fahrzeuge', 'Straßenbahn'),
    ('Fahrzeuge', 'Flugzeug'),
    ('Fahrzeuge', 'Boot'),
    ('Fahrzeuge', 'Roller'),
    ('Fahrzeuge', 'Traktor'),
    ('Fahrzeuge', 'Wohnmobil'),
    ('Fahrzeuge', 'Taxi'),
    ('Fahrzeuge', 'S-Bahn'),
    ('Fahrzeuge', 'Fähre'),
    ('Fahrzeuge', 'Hubschrauber'),
    ('Fahrzeuge', 'Segelboot'),
    ('Möbelstücke', 'Sofa'),
    ('Möbelstücke', 'Stuhl'),
    ('Möbelstücke', 'Tisch'),
    ('Möbelstücke', 'Bett'),
    ('Möbelstücke', 'Schrank'),
    ('Möbelstücke', 'Regal'),
    ('Möbelstücke', 'Kommode'),
    ('Möbelstücke', 'Sessel'),
    ('Möbelstücke', 'Hocker'),
    ('Möbelstücke', 'Lampe'),
    ('Möbelstücke', 'Couchtisch'),
    ('Möbelstücke', 'Nachttisch'),
    ('Möbelstücke', 'Schreibtisch'),
    ('Möbelstücke', 'Vitrine'),
    ('Möbelstücke', 'Bank'),
    ('Möbelstücke', 'Spiegel'),
    ('Elektrogeräte', 'Toaster'),
    ('Elektrogeräte', 'Mixer'),
    ('Elektrogeräte', 'Wasserkocher'),
    ('Elektrogeräte', 'Föhn'),
    ('Elektrogeräte', 'Staubsauger'),
    ('Elektrogeräte', 'Bügeleisen'),
    ('Elektrogeräte', 'Kaffeemaschine'),
    ('Elektrogeräte', 'Mikrowelle'),
    ('Elektrogeräte', 'Waschmaschine'),
    ('Elektrogeräte', 'Trockner'),
    ('Elektrogeräte', 'Geschirrspüler'),
    ('Elektrogeräte', 'Rasierer'),
    ('Elektrogeräte', 'Ventilator'),
    ('Elektrogeräte', 'Heizlüfter'),
    ('Smartphone-Hersteller', 'Samsung'),
    ('Smartphone-Hersteller', 'Apple'),
    ('Smartphone-Hersteller', 'Huawei'),
    ('Smartphone-Hersteller', 'Xiaomi'),
    ('Smartphone-Hersteller', 'Sony'),
    ('Smartphone-Hersteller', 'LG'),
    ('Smartphone-Hersteller', 'OnePlus'),
    ('Smartphone-Hersteller', 'Google'),
    ('Smartphone-Hersteller', 'Motorola'),
    ('Smartphone-Hersteller', 'Nokia'),
    ('Smartphone-Hersteller', 'Oppo'),
    ('Smartphone-Hersteller', 'Vivo'),
    ('Smartphone-Hersteller', 'Realme'),
    ('Smartphone-Hersteller', 'Honor'),
    ('Soziale Medien', 'Instagram'),
    ('Soziale Medien', 'TikTok'),
    ('Soziale Medien', 'Facebook'),
    ('Soziale Medien', 'Twitter'),
    ('Soziale Medien', 'Snapchat'),
    ('Soziale Medien', 'YouTube'),
    ('Soziale Medien', 'LinkedIn'),
    ('Soziale Medien', 'Pinterest'),
    ('Soziale Medien', 'Reddit'),
    ('Soziale Medien', 'WhatsApp'),
    ('Soziale Medien', 'Telegram'),
    ('Soziale Medien', 'Discord'),
    ('Soziale Medien', 'Twitch'),
    ('Soziale Medien', 'BeReal'),
    ('Bekannte YouTuber', 'MrBeast'),
    ('Bekannte YouTuber', 'PewDiePie'),
    ('Bekannte YouTuber', 'Gronkh'),
    ('Bekannte YouTuber', 'Bibi'),
    ('Bekannte YouTuber', 'Julien Bam'),
    ('Bekannte YouTuber', 'Rezo'),
    ('Bekannte YouTuber', 'Knossi'),
    ('Bekannte YouTuber', 'Trymacs'),
    ('Bekannte YouTuber', 'Inscope21'),
    ('Bekannte YouTuber', 'Unge'),
    ('Bekannte YouTuber', 'Paluten'),
    ('Bekannte YouTuber', 'LeFloid'),
    ('Bekannte YouTuber', 'Ungespielt'),
    ('Bekannte YouTuber', 'Katja Krasavice'),
    ('Bekannte YouTuber', 'Montanablack'),
    ('Kleidungsmarken', 'Nike'),
    ('Kleidungsmarken', 'Adidas'),
    ('Kleidungsmarken', 'Puma'),
    ('Kleidungsmarken', 'H&M'),
    ('Kleidungsmarken', 'Zara'),
    ('Kleidungsmarken', 'Gucci'),
    ('Kleidungsmarken', 'Prada'),
    ('Kleidungsmarken', 'Levis'),
    ('Kleidungsmarken', 'Tommy Hilfiger'),
    ('Kleidungsmarken', 'Hugo Boss'),
    ('Kleidungsmarken', 'Under Armour'),
    ('Kleidungsmarken', 'New Balance'),
    ('Kleidungsmarken', 'Calvin Klein'),
    ('Kleidungsmarken', 'Lacoste'),
    ('Kleidungsmarken', 'Vans'),
    ('Kleidungsmarken', 'Reebok'),
    ('Elektronik-Marken', 'Apple'),
    ('Elektronik-Marken', 'Samsung'),
    ('Elektronik-Marken', 'Sony'),
    ('Elektronik-Marken', 'LG'),
    ('Elektronik-Marken', 'Bose'),
    ('Elektronik-Marken', 'Philips'),
    ('Elektronik-Marken', 'Bosch'),
    ('Elektronik-Marken', 'Siemens'),
    ('Elektronik-Marken', 'Panasonic'),
    ('Elektronik-Marken', 'JBL'),
    ('Elektronik-Marken', 'Sennheiser'),
    ('Elektronik-Marken', 'Canon'),
    ('Elektronik-Marken', 'Nikon'),
    ('Elektronik-Marken', 'Dell'),
    ('Elektronik-Marken', 'HP'),
    ('Elektronik-Marken', 'Lenovo'),
    ('Elektronik-Marken', 'Asus'),
    ('Deutsche Rapper', 'Capital Bra'),
    ('Deutsche Rapper', 'Bushido'),
    ('Deutsche Rapper', 'Sido'),
    ('Deutsche Rapper', 'Kollegah'),
    ('Deutsche Rapper', 'Apache'),
    ('Deutsche Rapper', 'RAF Camora'),
    ('Deutsche Rapper', 'Kontra K'),
    ('Deutsche Rapper', 'Shirin David'),
    ('Deutsche Rapper', 'Cro'),
    ('Deutsche Rapper', 'Fler'),
    ('Deutsche Rapper', 'Farid Bang'),
    ('Deutsche Rapper', 'Samra'),
    ('Deutsche Rapper', 'Luciano'),
    ('Deutsche Rapper', 'Ufo361'),
    ('Deutsche Rapper', 'Bonez MC'),
    ('Deutsche Rapper', 'Gzuz'),
    ('Deutsche Rapper', '01099'),
    ('Deutsche Rapper', 'Rin'),
    ('Kinderspiele', 'Verstecken'),
    ('Kinderspiele', 'Fangen'),
    ('Kinderspiele', 'Mensch ärgere dich nicht'),
    ('Kinderspiele', 'UNO'),
    ('Kinderspiele', 'Memory'),
    ('Kinderspiele', 'Stadt Land Fluss'),
    ('Kinderspiele', 'Twister'),
    ('Kinderspiele', 'Mau Mau'),
    ('Kinderspiele', 'Blinde Kuh'),
    ('Kinderspiele', 'Himmel und Hölle'),
    ('Kinderspiele', 'Gummitwist'),
    ('Kinderspiele', 'Seilspringen'),
    ('Brettspiele', 'Monopoly'),
    ('Brettspiele', 'Risiko'),
    ('Brettspiele', 'Catan'),
    ('Brettspiele', 'Scrabble'),
    ('Brettspiele', 'Backgammon'),
    ('Brettspiele', 'Dame'),
    ('Brettspiele', 'Schach'),
    ('Brettspiele', 'Trivial Pursuit'),
    ('Brettspiele', 'Cluedo'),
    ('Brettspiele', 'Mensch ärgere dich nicht'),
    ('Brettspiele', 'Uno'),
    ('Brettspiele', 'Rummikub'),
    ('Brettspiele', 'Carcassonne'),
    ('Brettspiele', 'Dixit'),
    ('Handwerks-Berufe', 'Tischler'),
    ('Handwerks-Berufe', 'Schreiner'),
    ('Handwerks-Berufe', 'Maurer'),
    ('Handwerks-Berufe', 'Elektriker'),
    ('Handwerks-Berufe', 'Klempner'),
    ('Handwerks-Berufe', 'Maler'),
    ('Handwerks-Berufe', 'Schlosser'),
    ('Handwerks-Berufe', 'Dachdecker'),
    ('Handwerks-Berufe', 'Friseur'),
    ('Handwerks-Berufe', 'Zimmermann'),
    ('Handwerks-Berufe', 'Installateur'),
    ('Handwerks-Berufe', 'Fliesenleger'),
    ('Handwerks-Berufe', 'Gärtner'),
    ('Handwerks-Berufe', 'Schweißer'),
    ('Deutschrap-Songs', 'Tequila'),
    ('Deutschrap-Songs', 'Wolke 10'),
    ('Deutschrap-Songs', 'Puuh Bär'),
    ('Deutschrap-Songs', 'Rockstar'),
    ('Deutschrap-Songs', 'Athen'),
    ('Deutschrap-Songs', 'Neymar'),
    ('Deutschrap-Songs', 'Millionär'),
    ('Deutschrap-Songs', 'Blaulicht'),
    ('Deutschrap-Songs', 'Vermissen'),
    ('Deutschrap-Songs', 'Dior'),
    ('Deutschrap-Songs', 'Bonez MC'),
    ('Deutschrap-Songs', 'Gangsta Rap'),
    ('Deutschrap-Songs', 'Willst du'),
    ('Deutschrap-Songs', 'Anfang'),
    ('Deutschrap-Songs', 'Powergirl'),
    ('Deutschrap-Songs', 'Meine Soldaten'),
    ('Deutschrap-Songs', 'Roller'),
    ('Deutschrap-Songs', 'Blackout'),
    ('Deutschrap-Songs', 'Palmen aus Plastik'),
    ('Deutschrap-Songs', 'Nicht verdient'),
    ('Deutschrap-Songs', '3 Millionen'),
    ('Deutschrap-Songs', 'Nightliner'),
    ('Deutschrap-Songs', 'Nur noch Gangster'),
    ('Deutschrap-Songs', 'Nummer 1'),
    ('Deutschrap-Songs', 'Nicht so wichtig'),
    ('Deutschrap-Songs', 'Nur für dich'),
    ('Deutschrap Klassiker', 'Halt dich fest'),
    ('Deutschrap Klassiker', 'Wilma rennt'),
    ('Deutschrap Klassiker', 'Für immer jung'),
    ('Deutschrap Klassiker', '1000 PS'),
    ('Deutschrap Klassiker', 'Wer hat Angst vorm schwarzen Mann'),
    ('Deutschrap Klassiker', 'Wo ist das Geld'),
    ('Deutschrap Klassiker', 'Berlin lebt'),
    ('Deutschrap Klassiker', 'Alles auf Rot'),
    ('Deutschrap Klassiker', 'Bilder im Kopf'),
    ('Deutschrap Klassiker', 'Frei sein'),
    ('Deutschrap Klassiker', 'Phantom'),
    ('Deutschrap Klassiker', 'Adrenalin'),
    ('Deutschrap Klassiker', 'Vermissen'),
    ('Deutschrap Klassiker', 'Prinzessin'),
    ('Deutschrap Klassiker', 'Willkommen im Bundestag'),
    ('Deutschrap Klassiker', 'Aggro Ansage Nr.1'),
    ('Deutschrap Klassiker', 'Bild dir deine Meinung'),
    ('Deutschrap Klassiker', 'Denkmal'),
    ('Deutschrap Klassiker', 'Wilder Wilder Westen'),
    ('Deutschrap Klassiker', 'Party Prinzessin'),
    ('Englische All-Time-Hits', 'Bohemian Rhapsody'),
    ('Englische All-Time-Hits', 'Billie Jean'),
    ('Englische All-Time-Hits', 'Rolling in the Deep'),
    ('Englische All-Time-Hits', 'Shape of You'),
    ('Englische All-Time-Hits', 'Blinding Lights'),
    ('Englische All-Time-Hits', 'Someone Like You'),
    ('Englische All-Time-Hits', 'Sweet Child O'' Mine'),
    ('Englische All-Time-Hits', 'Smells Like Teen Spirit'),
    ('Englische All-Time-Hits', 'Hotel California'),
    ('Englische All-Time-Hits', 'I Want It That Way'),
    ('Englische All-Time-Hits', 'Uptown Funk'),
    ('Englische All-Time-Hits', 'Umbrella'),
    ('Englische All-Time-Hits', 'Poker Face'),
    ('Englische All-Time-Hits', 'Firework'),
    ('Englische All-Time-Hits', 'Radioactive'),
    ('Englische All-Time-Hits', 'Thinking Out Loud'),
    ('Englische All-Time-Hits', 'Shake It Off'),
    ('Englische All-Time-Hits', 'Stayin'' Alive'),
    ('Englische All-Time-Hits', 'Like a Prayer'),
    ('Englische All-Time-Hits', 'Wonderwall'),
    ('Internationale Pop-Charts', 'Espresso'),
    ('Internationale Pop-Charts', 'Flowers'),
    ('Internationale Pop-Charts', 'As It Was'),
    ('Internationale Pop-Charts', 'Anti-Hero'),
    ('Internationale Pop-Charts', 'Cruel Summer'),
    ('Internationale Pop-Charts', 'Levitating'),
    ('Internationale Pop-Charts', 'Peaches'),
    ('Internationale Pop-Charts', 'Watermelon Sugar'),
    ('Internationale Pop-Charts', 'Good 4 U'),
    ('Internationale Pop-Charts', 'Stay'),
    ('Internationale Pop-Charts', 'Circles'),
    ('Internationale Pop-Charts', 'Blinding Lights'),
    ('Internationale Pop-Charts', 'Kill Bill'),
    ('Internationale Pop-Charts', 'Vampire'),
    ('Internationale Pop-Charts', 'Greedy'),
    ('Internationale Pop-Charts', 'Lose Control'),
    ('Internationale Pop-Charts', 'Die With a Smile'),
    ('Internationale Pop-Charts', 'Birds of a Feather'),
    ('Internationale Pop-Charts', 'Houdini')
) AS v(topic, answer) ON lower(tp.text) = lower(v.topic)
ON CONFLICT (topic_pool_id, lower_answer) DO NOTHING;
COMMIT;


-- ============================================================
-- 028_countdown_skip.sql
-- ============================================================
-- ============================================================
-- Migration 028: Themen-Countdown springt auf 5s wenn alle (Menschen) gewählt haben
-- ============================================================
-- Bots zählen bewusst NICHT mit -- ihre Wahl ist ohnehin zufällig
-- (useBotEngine.ts) und soll das Verkürzen nicht blockieren, falls ein
-- Bot noch seine 800-2400ms Zufallsverzögerung vor sich hat.
--
-- Wichtig: verkürzt nur EINMAL (wenn die verbleibende Zeit noch > 5s
-- ist). Würde man topic_vote_ends_at bei jedem Aufruf neu auf "jetzt +
-- 5s" setzen, würde der Countdown nie unter 5s fallen, solange die
-- Funktion weiter aufgerufen wird (z.B. durch Polling) -- das wäre ein
-- eingebauter Endlos-Countdown-Bug. Sobald die Restzeit <= 5s ist, tut
-- der Aufruf nichts mehr; die Uhr läuft normal weiter runter.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_maybe_shorten_topic_vote(p_lobby_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_phase text;
  v_ends_at timestamptz;
  v_voters_needed int;
  v_voters_have int;
begin
  select phase, topic_vote_ends_at into v_phase, v_ends_at
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'topic_vote' then return; end if;
  if v_ends_at is null then return; end if;
  if v_ends_at <= now() + interval '5 seconds' then return; end if;

  select count(*) into v_voters_needed
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and coalesce(is_bot, false) = false;

  if v_voters_needed = 0 then return; end if;

  select count(distinct tv.player_id) into v_voters_have
  from public.topic_votes tv
  join public.players p on p.lobby_id = p_lobby_id and p.player_id = tv.player_id
  where tv.lobby_id = p_lobby_id and p.status = 'active' and coalesce(p.is_bot, false) = false;

  if v_voters_have >= v_voters_needed then
    update public.lobbies
    set topic_vote_ends_at = now() + interval '5 seconds'
    where id = p_lobby_id;
  end if;
end;
$function$;

COMMIT;


-- ============================================================
-- 029_song_guess_mode.sql
-- ============================================================
-- ============================================================
-- Migration 029: Song-Raten statt Ambient-Playlist im Musik-Modus
-- ============================================================
-- Bisher: die 4 Musik-Kategorien (Deutschrap-Songs, Deutschrap
-- Klassiker, Englische All-Time-Hits, Internationale Pop-Charts)
-- betteten nur eine Spotify-Playlist als Dauerberieselung ein --
-- Spotifys Embed-Widget zeigt den Songnamen aber IMMER sichtbar an,
-- das lässt sich nicht unterdrücken. Für ein echtes "errate den Song"
-- braucht es eine Audioquelle ohne sichtbaren Titel.
--
-- Neu: song_pool -- pro Musik-Kategorie eine Liste echter Songtitel
-- (aus den bereits kuratierten Antworten von Migration 027 übernommen).
-- lobbies.current_song_id zeigt auf den GENAU EINEN Song, den der
-- aktuelle Halter gerade "hat". Der Client rendert den Titel nirgends,
-- sondern nutzt title+artist nur als Suchbegriff für einen 30s-Preview-
-- Clip von der iTunes Search API (öffentlich, kein API-Key, CORS offen
-- -- curl-verifiziert). Die Antwort-Prüfung läuft weiterhin serverseitig
-- gegen den in song_pool gespeicherten Titel.
--
-- Rotation: ein neuer Song wird gezogen bei Rundenstart
-- (rpc_advance_from_countdown), bei jedem erfolgreichen Pass
-- (rpc_pass_potato) und bei jeder Explosion/Elimination
-- (rpc_tick_game) -- also genau dann, wenn der Halter wechselt.
-- Bereits gespielte Songs merkt sich lobbies.used_song_ids und wird
-- beim Ziehen ausgeschlossen, damit derselbe Song nicht zweimal im
-- selben Match drankommt.
--
-- Transparenz-Hinweis: song_pool ist wie topic_answers (Migration 027)
-- bewusst normal SELECT-lesbar (RLS "for all") -- der Titel wird nie
-- im UI gerendert, ist über die Netzwerk-Konsole aber technisch
-- einsehbar, genau wie die bestehende Antwort-Datenbank. Für "wirklich
-- unmöglich nachzuschauen" bräuchte es einen Service-Role-Server-Call;
-- das ist hier bewusst nicht gebaut, um keinen neuen Secret-Typ in die
-- bislang rein Anon-Key-basierte Architektur einzuführen.
-- ============================================================

BEGIN;

ALTER TABLE public.topic_pool
    ADD COLUMN IF NOT EXISTS is_song_category BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.topic_pool
SET is_song_category = TRUE
WHERE text IN ('Deutschrap-Songs', 'Deutschrap Klassiker', 'Englische All-Time-Hits', 'Internationale Pop-Charts');

CREATE TABLE IF NOT EXISTS public.song_pool (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic_pool_id  UUID NOT NULL REFERENCES public.topic_pool(id) ON DELETE CASCADE,
    title          TEXT NOT NULL,
    artist         TEXT,
    lower_title    TEXT GENERATED ALWAYS AS (lower(title)) STORED,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (topic_pool_id, lower_title)
);

ALTER TABLE public.song_pool ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS song_pool_select_all ON public.song_pool;
CREATE POLICY song_pool_select_all ON public.song_pool FOR SELECT USING (true);

GRANT SELECT ON public.song_pool TO anon, authenticated;

-- Seed: Titel 1:1 aus der bereits kuratierten Antwort-Datenbank
-- (Migration 027) übernommen, Künstler wo sicher bekannt ergänzt --
-- fehlende Künstler sind kein Problem, die iTunes-Suche läuft auch
-- mit Titel allein (ggf. etwas unschärfer beim Treffer).
INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Deutschrap-Songs', 'Tequila', 'Eno feat. Bonez MC & Gzuz'),
    ('Deutschrap-Songs', 'Wolke 10', 'Apache 207'),
    ('Deutschrap-Songs', 'Puuh Bär', NULL),
    ('Deutschrap-Songs', 'Rockstar', 'Ufo361'),
    ('Deutschrap-Songs', 'Athen', 'Apache 207'),
    ('Deutschrap-Songs', 'Neymar', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Millionär', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Blaulicht', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Vermissen', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Dior', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Bonez MC', NULL),
    ('Deutschrap-Songs', 'Gangsta Rap', NULL),
    ('Deutschrap-Songs', 'Willst du', 'Bausa'),
    ('Deutschrap-Songs', 'Anfang', NULL),
    ('Deutschrap-Songs', 'Powergirl', NULL),
    ('Deutschrap-Songs', 'Meine Soldaten', NULL),
    ('Deutschrap-Songs', 'Roller', 'Apache 207'),
    ('Deutschrap-Songs', 'Blackout', NULL),
    ('Deutschrap-Songs', 'Palmen aus Plastik', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Nicht verdient', NULL),
    ('Deutschrap-Songs', '3 Millionen', NULL),
    ('Deutschrap-Songs', 'Nightliner', NULL),
    ('Deutschrap-Songs', 'Nur noch Gangster', NULL),
    ('Deutschrap-Songs', 'Nummer 1', NULL),
    ('Deutschrap-Songs', 'Nicht so wichtig', NULL),
    ('Deutschrap-Songs', 'Nur für dich', NULL),
    ('Deutschrap Klassiker', 'Halt dich fest', 'Marteria'),
    ('Deutschrap Klassiker', 'Wilma rennt', 'Seeed'),
    ('Deutschrap Klassiker', 'Für immer jung', NULL),
    ('Deutschrap Klassiker', '1000 PS', 'Kollegah & Farid Bang'),
    ('Deutschrap Klassiker', 'Wer hat Angst vorm schwarzen Mann', 'Fettes Brot'),
    ('Deutschrap Klassiker', 'Wo ist das Geld', 'Bushido'),
    ('Deutschrap Klassiker', 'Berlin lebt', 'Bushido'),
    ('Deutschrap Klassiker', 'Alles auf Rot', 'Sido'),
    ('Deutschrap Klassiker', 'Bilder im Kopf', 'Kontra K'),
    ('Deutschrap Klassiker', 'Frei sein', 'Kontra K'),
    ('Deutschrap Klassiker', 'Phantom', 'Sido'),
    ('Deutschrap Klassiker', 'Adrenalin', 'Bushido'),
    ('Deutschrap Klassiker', 'Vermissen', 'Bonez MC & RAF Camora'),
    ('Deutschrap Klassiker', 'Prinzessin', 'Fler'),
    ('Deutschrap Klassiker', 'Willkommen im Bundestag', 'Deichkind'),
    ('Deutschrap Klassiker', 'Aggro Ansage Nr.1', NULL),
    ('Deutschrap Klassiker', 'Bild dir deine Meinung', 'Fettes Brot'),
    ('Deutschrap Klassiker', 'Denkmal', 'Sido'),
    ('Deutschrap Klassiker', 'Wilder Wilder Westen', 'Peter Fox'),
    ('Deutschrap Klassiker', 'Party Prinzessin', NULL),
    ('Englische All-Time-Hits', 'Bohemian Rhapsody', 'Queen'),
    ('Englische All-Time-Hits', 'Billie Jean', 'Michael Jackson'),
    ('Englische All-Time-Hits', 'Rolling in the Deep', 'Adele'),
    ('Englische All-Time-Hits', 'Shape of You', 'Ed Sheeran'),
    ('Englische All-Time-Hits', 'Blinding Lights', 'The Weeknd'),
    ('Englische All-Time-Hits', 'Someone Like You', 'Adele'),
    ('Englische All-Time-Hits', 'Sweet Child O'' Mine', 'Guns N'' Roses'),
    ('Englische All-Time-Hits', 'Smells Like Teen Spirit', 'Nirvana'),
    ('Englische All-Time-Hits', 'Hotel California', 'Eagles'),
    ('Englische All-Time-Hits', 'I Want It That Way', 'Backstreet Boys'),
    ('Englische All-Time-Hits', 'Uptown Funk', 'Mark Ronson feat. Bruno Mars'),
    ('Englische All-Time-Hits', 'Umbrella', 'Rihanna'),
    ('Englische All-Time-Hits', 'Poker Face', 'Lady Gaga'),
    ('Englische All-Time-Hits', 'Firework', 'Katy Perry'),
    ('Englische All-Time-Hits', 'Radioactive', 'Imagine Dragons'),
    ('Englische All-Time-Hits', 'Thinking Out Loud', 'Ed Sheeran'),
    ('Englische All-Time-Hits', 'Shake It Off', 'Taylor Swift'),
    ('Englische All-Time-Hits', 'Stayin'' Alive', 'Bee Gees'),
    ('Englische All-Time-Hits', 'Like a Prayer', 'Madonna'),
    ('Englische All-Time-Hits', 'Wonderwall', 'Oasis'),
    ('Internationale Pop-Charts', 'Espresso', 'Sabrina Carpenter'),
    ('Internationale Pop-Charts', 'Flowers', 'Miley Cyrus'),
    ('Internationale Pop-Charts', 'As It Was', 'Harry Styles'),
    ('Internationale Pop-Charts', 'Anti-Hero', 'Taylor Swift'),
    ('Internationale Pop-Charts', 'Cruel Summer', 'Taylor Swift'),
    ('Internationale Pop-Charts', 'Levitating', 'Dua Lipa'),
    ('Internationale Pop-Charts', 'Peaches', 'Justin Bieber'),
    ('Internationale Pop-Charts', 'Watermelon Sugar', 'Harry Styles'),
    ('Internationale Pop-Charts', 'Good 4 U', 'Olivia Rodrigo'),
    ('Internationale Pop-Charts', 'Stay', 'The Kid LAROI & Justin Bieber'),
    ('Internationale Pop-Charts', 'Circles', 'Post Malone'),
    ('Internationale Pop-Charts', 'Blinding Lights', 'The Weeknd'),
    ('Internationale Pop-Charts', 'Kill Bill', 'SZA'),
    ('Internationale Pop-Charts', 'Vampire', 'Olivia Rodrigo'),
    ('Internationale Pop-Charts', 'Greedy', 'Tate McRae'),
    ('Internationale Pop-Charts', 'Lose Control', 'Teddy Swims'),
    ('Internationale Pop-Charts', 'Die With a Smile', 'Lady Gaga & Bruno Mars'),
    ('Internationale Pop-Charts', 'Birds of a Feather', 'Billie Eilish'),
    ('Internationale Pop-Charts', 'Houdini', 'Dua Lipa')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS current_song_id UUID REFERENCES public.song_pool(id),
    ADD COLUMN IF NOT EXISTS used_song_ids UUID[] NOT NULL DEFAULT '{}';

-- Zieht (falls das aktuelle Thema eine Musik-Kategorie ist) einen neuen,
-- in diesem Match noch nicht gespielten Song und setzt current_song_id.
-- Kein Song-Thema -> current_song_id wird genullt. Aufrufer hält die
-- Lobby-Row bereits per FOR UPDATE (rpc_advance_from_countdown,
-- rpc_pass_potato, rpc_tick_game locken schon vor ihrem Aufruf).
CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid;
begin
  select topic_selected, used_song_ids into v_topic, v_used
  from public.lobbies where id = p_lobby_id;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  -- Songs im Match aufgebraucht -> Pool für dieses Match wieder freigeben.
  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
    order by random() limit 1;
    v_used := '{}';
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

-- rpc_advance_from_countdown: ersten Song fürs Match ziehen.
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
begin
  select round_speed, coalesce(round_number, 0)
    into v_round_speed, v_round_number
  from public.lobbies where id = p_lobby_id for update;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  v_explode_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    greatest(1, v_alive_count),
    greatest(1, v_round_number)
  );

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + (v_explode_seconds * interval '1 second'),
      countdown_started_at = null,
      countdown_ends_at = null,
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- rpc_pass_potato: bei jedem erfolgreichen Pass den nächsten Song ziehen.
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
  from public.lobbies l
  where l.code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index) into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- Mode-aware next holder
  if v_mode = 'teleport' then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id
      and p.status = 'active' and p.is_alive = true
      and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then return; end if;

  elsif v_mode = 'reverse' then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];

  else
    next_idx := idx + 1;
    if next_idx > n then next_idx := 1; end if;
    v_next := alive_ids[next_idx];
  end if;

  update public.lobbies set holder_player_id = v_next, last_activity_at = v_now where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  -- Stats tracking
  select last_pass_at into v_last_pass from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms from public.lobbies where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

-- rpc_tick_game: bei jeder Explosion/Elimination den nächsten Song ziehen.
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  if v_now < v_explode_at then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby_id and player_id = v_loser;

  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  update public.lobbies
  set round_number = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at = v_now
  where id = v_lobby_id
  returning round_number into v_round_number;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true and player_id != v_loser
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = v_now + v_round_duration,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
end;
$function$;

-- rpc_attempt_pass: bei aktivem Song-Modus gegen den EINEN aktuellen Song
-- prüfen statt gegen die ganze Kategorie-Antwortliste.
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_known boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  if v_lobby.current_song_id is not null then
    -- Song-Modus: gegen genau den einen aktuellen Song prüfen (Klammer-
    -- Zusätze wie "(feat. ...)" werden toleriert, exakte Interpreten-
    -- Schreibweise wird nicht verlangt).
    select exists (
      select 1 from public.song_pool sp
      where sp.id = v_lobby.current_song_id
        and (
          sp.lower_title = lower(v_clean)
          or regexp_replace(sp.lower_title, '\s*\(.*?\)\s*', '', 'g') = lower(v_clean)
        )
    ) into v_known;
  else
    -- Antwort-Datenbank: bekannte, korrekte Antwort -> sofort annehmen,
    -- kein Voting nötig. _finalize_attempt_accept setzt current_attempt_id
    -- selbst wieder auf null und stößt rpc_pass_potato an.
    select exists (
      select 1
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(v_topic)
        and ta.lower_answer = lower(v_clean)
    ) into v_known;
  end if;

  if v_known then
    perform public._finalize_attempt_accept(v_attempt);
  end if;

  return v_attempt;
end;
$function$;

COMMIT;


-- ============================================================
-- 030_single_category_filter_fix.sql
-- ============================================================
-- ============================================================
-- Migration 030: Themen-Filter mit nur EINER Kategorie startet nicht
-- ============================================================
-- Live beim gemeinsamen Testen gefunden: setzt der Host den
-- Musik-Genre-Filter auf genau EINE Kategorie (z.B. nur
-- "Deutschrap-Songs"), wirft rpc_begin_topic_vote und
-- rpc_start_rematch_if_ready "Not enough topics in topic_pool" --
-- beide ziehen Thema A und Thema B als zwei UNTERSCHIEDLICHE
-- Kategorien aus dem gefilterten Pool, aber wenn der Filter nur eine
-- Kategorie zulaesst, gibt es kein zweites, verschiedenes Thema.
-- Das Spiel liess sich dann ueberhaupt nicht starten.
--
-- Fix: gibt es kein zweites, verschiedenes Thema im gefilterten Pool,
-- wird Thema B einfach gleich Thema A gesetzt (beide Wahlmoeglichkeiten
-- zeigen dieselbe einzige Kategorie -- die Abstimmung ist dann trivial,
-- aber das Spiel startet).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text; v_filter text[];
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, topic_filter into v_host, v_filter
  from public.lobbies where id = p_lobby_id for update;

  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select t.text into v_a from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_a is null then raise exception 'Not enough topics in topic_pool'; end if;
  if v_b is null then v_b := v_a; end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_ready_count int; v_active_count int; v_filter text[];
  v_topic_a text; v_topic_b text;
begin
  select id, topic_filter into v_lobby_id, v_filter
  from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  select count(*) into v_ready_count from public.players
  where lobby_id = v_lobby_id and status = 'active' and coalesce(ready, false) = true;

  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;
  if v_ready_count <> v_active_count then return; end if;

  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_a is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;
  if v_topic_b is null then v_topic_b := v_topic_a; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 031_public_lobbies_admin_stats_answer_mode.sql
-- ============================================================
-- ============================================================
-- Migration 031: Public-Lobbys fertigbauen, Admin-Stats absichern,
-- Antwort-Modus (Schreiben/Sprechen) als Lobby-Einstellung
-- ============================================================
-- Drei unabhängige Ergänzungen, in einer Migration gebündelt:
--
-- 1) Admin-Stats-Zugriffsschutz: `/admin/stats` hatte bisher gar keine
--    Zugriffskontrolle (weder Route noch Backend) -- jeder mit der URL
--    konnte interne Aggregat-Statistiken sehen. Neues `profiles.
--    is_platform_admin` Flag (manuell per SQL gesetzt, kein UI dafür --
--    bewusst, es soll niemand versehentlich sich selbst freischalten
--    können) + eine SECURITY DEFINER Funktion, die die Berechtigung
--    SERVERSEITIG prüft, bevor sie irgendwas zurückgibt. Das Frontend
--    ruft nur noch diese eine Funktion auf statt zehn Rohtabellen
--    direkt abzufragen.
--
-- 2) Public-Lobbys: `rpc_create_lobby` validiert `p_privacy` schon seit
--    Migration 020 korrekt -- die Public-Option war nur im Frontend
--    deaktiviert. Für eine Lobby-Übersicht ("welche Lobbys sind gerade
--    offen") fehlte bisher eine Abfragemöglichkeit + eine Funktion, um
--    die Privatsphäre auch NACH der Erstellung zu ändern (Konsistenz
--    mit set_lobby_mode/set_lobby_topic, die das für andere Einstellungen
--    schon können).
--
-- 3) Antwort-Modus: neue Spalte `lobbies.answer_mode` ('text' | 'voice'),
--    wählbar beim Hosten UND danach änderbar. 'text' bleibt Default --
--    Sprocheingabe ist ein Zusatzmodus, kein Ersatz.
-- ============================================================

BEGIN;

-- --- 1) Admin-Stats -------------------------------------------------

ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS is_platform_admin boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.rpc_get_admin_stats(p_user_id uuid)
    RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
    v_is_admin boolean;
    v_result jsonb;
    v_stuck_cutoff timestamptz := now() - interval '30 seconds';
    v_day_ago timestamptz := now() - interval '24 hours';
begin
    if p_user_id is null then
        raise exception 'not_authorized';
    end if;

    select coalesce(is_platform_admin, false) into v_is_admin
    from public.profiles where id = p_user_id;

    if not coalesce(v_is_admin, false) then
        raise exception 'not_authorized';
    end if;

    select jsonb_build_object(
        'lobbies', jsonb_build_object(
            'totalEver', (select count(*) from public.lobbies),
            'activeNow', (select count(*) from public.lobbies where phase in ('topic_vote','countdown','running','rematch_wait')),
            'last24h', (select count(*) from public.lobbies where created_at >= v_day_ago),
            'byMode', (
                select coalesce(jsonb_object_agg(game_mode, cnt), '{}'::jsonb)
                from (select coalesce(game_mode, 'original') as game_mode, count(*) as cnt from public.lobbies group by 1) s
            ),
            'bySpeed', (
                select coalesce(jsonb_object_agg(round_speed, cnt), '{}'::jsonb)
                from (select coalesce(round_speed, 'normal') as round_speed, count(*) as cnt from public.lobbies group by 1) s
            )
        ),
        'players', jsonb_build_object(
            'totalRows', (select count(*) from public.players),
            'botRows', (select count(*) from public.players where is_bot = true),
            'activeRows', (select count(*) from public.players where status = 'active')
        ),
        'matches', jsonb_build_object(
            'finished', (select count(*) from public.game_runs where finished_at is not null),
            'avgPlayers', (select round(avg(players_count)::numeric, 1) from public.game_runs where finished_at is not null and players_count is not null),
            'avgDurationSec', (select round(avg(extract(epoch from (finished_at - started_at)))::numeric) from public.game_runs where finished_at is not null)
        ),
        'social', jsonb_build_object(
            'registeredUsers', (select count(*) from public.profiles),
            'acceptedFriendships', (select count(*) from public.friendships where status = 'accepted'),
            'savedLobbies', (select count(*) from public.saved_lobbies)
        ),
        'content', jsonb_build_object(
            'activeTopics', (select count(*) from public.topic_pool where active = true)
        ),
        'votes', jsonb_build_object(
            'total', (select count(*) from public.pass_attempts),
            'accepted', (select count(*) from public.pass_attempts where status = 'accepted'),
            'rejected', (select count(*) from public.pass_attempts where status = 'rejected'),
            'pending', (select count(*) from public.pass_attempts where status = 'pending'),
            'stuckPending', (select count(*) from public.pass_attempts where status = 'pending' and created_at < v_stuck_cutoff)
        ),
        'achievements', jsonb_build_object(
            'totalUnlocked', (select count(*) from public.player_achievements)
        ),
        'leaderboard', (
            select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
            from (select username, wins, games_played, win_rate_pct from public.leaderboard_view order by wins desc limit 5) t
        )
    ) into v_result;

    return v_result;
end;
$function$;

-- --- 3) Antwort-Modus (Schreiben/Sprechen) -----------------------------
-- Muss VOR der public_lobbies_view (Abschnitt 2) stehen, die l.answer_mode
-- bereits mit ausliest -- sonst schlägt die View-Erstellung mit
-- "column l.answer_mode does not exist" fehl.

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS answer_mode text NOT NULL DEFAULT 'text'
        CHECK (answer_mode IN ('text', 'voice'));

CREATE OR REPLACE FUNCTION public.set_lobby_answer_mode(p_lobby_id uuid, p_me_player_id uuid, p_answer_mode text)
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_mode text;
begin
    if not public._verify_session(p_lobby_id, p_me_player_id) then
        raise exception 'invalid_session';
    end if;

    select host_player_id into v_host from public.lobbies where id = p_lobby_id;
    if v_host is null then raise exception 'lobby_not_found'; end if;
    if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

    v_mode := btrim(coalesce(p_answer_mode, ''));
    if v_mode not in ('text', 'voice') then raise exception 'invalid_answer_mode'; end if;

    update public.lobbies
    set answer_mode = v_mode,
        settings_version = coalesce(settings_version, 0) + 1
    where id = p_lobby_id;
end;
$function$;

-- --- 2) Public-Lobbys -------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_lobby_privacy(p_lobby_id uuid, p_me_player_id uuid, p_privacy text)
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_privacy text;
begin
    if not public._verify_session(p_lobby_id, p_me_player_id) then
        raise exception 'invalid_session';
    end if;

    select host_player_id into v_host from public.lobbies where id = p_lobby_id;
    if v_host is null then raise exception 'lobby_not_found'; end if;
    if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

    v_privacy := btrim(coalesce(p_privacy, ''));
    if v_privacy not in ('private', 'public') then raise exception 'invalid_privacy'; end if;

    update public.lobbies
    set privacy = v_privacy,
        settings_version = coalesce(settings_version, 0) + 1
    where id = p_lobby_id;
end;
$function$;

-- Übersicht offener Public-Lobbys (Warteraum, unversperrt). Die
-- zugrundeliegenden Tabellen erlauben anon SELECT ohnehin schon
-- uneingeschränkt (lobbies_read_all / players_read_all aus Migration
-- 012 -- "privacy" filtert bisher nur, was die UI anzeigt, nicht was
-- die DB rausgibt), eine normale View reicht hier also aus.
CREATE OR REPLACE VIEW public.public_lobbies_view AS
SELECT
    l.code,
    l.game_mode,
    l.round_speed,
    l.max_players,
    l.topic_filter,
    l.answer_mode,
    l.created_at,
    h.name AS host_name,
    (SELECT count(*) FROM public.players p WHERE p.lobby_id = l.id AND p.status = 'active') AS player_count
FROM public.lobbies l
JOIN public.players h ON h.lobby_id = l.id AND h.player_id = l.host_player_id
WHERE l.privacy = 'public' AND l.phase = 'waiting' AND l.locked = false;

COMMIT;


-- ============================================================
-- 032_pass_grace_bonus.sql
-- ============================================================
-- ============================================================
-- Migration 032: Grace-Bonus auf den Explosions-Timer bei jedem Pass
-- ============================================================
-- Bisher galt: explode_at wird nur EINMAL pro Runde gesetzt (Rundenstart
-- oder nach einer Explosion) und bleibt beim Weiterreichen der Kartoffel
-- unverändert -- wer die Kartoffel kurz vor Ablauf bekommt, kann quasi
-- ohne jede Chance sofort explodieren, egal wie schnell er reagiert.
--
-- Live-Feedback: bei jedem erfolgreichen Pass soll der Timer um ein paar
-- Sekunden VERLÄNGERT werden (nicht komplett zurückgesetzt) -- Beispiel:
-- Bombe hätte in 10s explodiert, Antwort kommt bei 3s Restzeit rein,
-- Bonus +2s -> 5s Restzeit für den nächsten Halter. Reagiert der wiederum
-- nach 1s (4s Restzeit), bekommt der übernächste 4s + 2s = 6s. Der Bonus
-- soll mit steigender Rundenzahl kleiner werden, damit das Spiel gegen
-- Ende (jeder war schon mehrfach dran) spürbar schneller/härter wird --
-- dieselbe Idee wie der bestehende scale_round-Faktor in
-- calc_explode_seconds, nur eigens für den Pass-Bonus statt die Basis-
-- Rundendauer.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.calc_pass_bonus_seconds(p_round_number integer)
    RETURNS numeric LANGUAGE sql IMMUTABLE
AS $function$
    SELECT CASE
        WHEN coalesce(p_round_number, 1) <= 2 THEN 4
        WHEN p_round_number <= 4 THEN 3
        WHEN p_round_number <= 6 THEN 2
        ELSE 1
    END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number
  from public.lobbies l
  where l.code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index) into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- Mode-aware next holder
  if v_mode = 'teleport' then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id
      and p.status = 'active' and p.is_alive = true
      and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then return; end if;

  elsif v_mode = 'reverse' then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];

  else
    next_idx := idx + 1;
    if next_idx > n then next_idx := 1; end if;
    v_next := alive_ids[next_idx];
  end if;

  -- Grace-Bonus: Timer wird bei jedem erfolgreichen Pass um ein paar
  -- Sekunden verlängert statt unverändert zu bleiben. GREATEST(..., now())
  -- als Basis statt einfach v_explode_at + Bonus, damit ein durch Client-
  -- Polling-Lag bereits abgelaufener Timer dem nächsten Halter trotzdem
  -- die volle Bonuszeit gibt statt einer Negativ-Restzeit + Bonus.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number);

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_seconds * interval '1 second'),
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  -- Stats tracking
  select last_pass_at into v_last_pass from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms from public.lobbies where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 033_refresh_current_song_categories.sql
-- ============================================================
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


-- ============================================================
-- 034_pass_bonus_cap.sql
-- ============================================================
-- ============================================================
-- Migration 034: Obergrenze für den kumulierten Pass-Bonus pro Runde
-- ============================================================
-- Live-Test mit 8 Spielern (Migration 032 nach dem Einbau): Runde 1 lief
-- 27.7s, Runde 2 aber 64.3s -- mit mehr lebenden Spielern gibt es mehr
-- Gelegenheiten, die Kartoffel erfolgreich weiterzureichen, und jeder
-- erfolgreiche Pass verlängert den Timer erneut. Bei genug Glück in
-- Folge kann eine Runde dadurch beliebig lange laufen -- "zu wenige
-- Bots fliegen pro Zeiteinheit", das Spiel zieht sich.
--
-- Fix: pro Runde gibt es jetzt eine Obergrenze, wie viel Bonuszeit sich
-- insgesamt aufsummieren darf (skaliert mit der Spielerzahl -- größere
-- Lobbys bekommen mehr Puffer, aber nie unbegrenzt). Ist die Grenze
-- erreicht, wird die Kartoffel trotzdem normal weitergereicht, der
-- Timer bekommt nur keinen weiteren Aufschlag mehr -- die Runde läuft
-- dann so lange wie geplant statt sich unbegrenzt weiter aufzuschaukeln.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS round_bonus_used numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.calc_pass_bonus_cap(p_alive_count integer)
    RETURNS numeric LANGUAGE sql IMMUTABLE
AS $function$
    SELECT greatest(12, least(30, coalesce(p_alive_count, 4) * 3));
$function$;

-- Reset bei jedem Rundenstart (neues Match/Rematch)
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
begin
  select round_speed, coalesce(round_number, 0)
    into v_round_speed, v_round_number
  from public.lobbies where id = p_lobby_id for update;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  v_explode_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    greatest(1, v_alive_count),
    greatest(1, v_round_number)
  );

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + (v_explode_seconds * interval '1 second'),
      countdown_started_at = null,
      countdown_ends_at = null,
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      round_bonus_used = 0,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- Reset bei jedem Rundenwechsel nach einer Explosion
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  if v_now < v_explode_at then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby_id and player_id = v_loser;

  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  update public.lobbies
  set round_number = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at = v_now
  where id = v_lobby_id
  returning round_number into v_round_number;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true and player_id != v_loser
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = v_now + v_round_duration,
      round_bonus_used = 0,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
end;
$function$;

-- Bonus bei jedem Pass jetzt gegen die Obergrenze geprüft
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number, coalesce(l.round_bonus_used, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number, v_bonus_used
  from public.lobbies l
  where l.code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index) into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- Mode-aware next holder
  if v_mode = 'teleport' then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id
      and p.status = 'active' and p.is_alive = true
      and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then return; end if;

  elsif v_mode = 'reverse' then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];

  else
    next_idx := idx + 1;
    if next_idx > n then next_idx := 1; end if;
    v_next := alive_ids[next_idx];
  end if;

  -- Grace-Bonus, gedeckelt: pro Runde darf sich höchstens calc_pass_bonus_cap(alive)
  -- Sekunden an Bonuszeit aufsummieren, damit viele Spieler + viel Glück nicht zu
  -- einer beliebig lang laufenden Runde führen (siehe Migrationskopf).
  v_bonus_cap := public.calc_pass_bonus_cap(n);
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number);
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second'),
      round_bonus_used = v_bonus_used + v_bonus_applied,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  -- Stats tracking
  select last_pass_at into v_last_pass from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms from public.lobbies where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;


-- ============================================================
-- 035_cleanup_ignores_bots.sql
-- ============================================================
-- ============================================================
-- Migration 035: cleanup_lobby kickte Bots als "inaktiv" raus
-- ============================================================
-- Live gefunden: Bots in der Warte-Lobby werden nach 45s (der
-- staleSeconds-Schwelle aus useHeartbeat) automatisch auf status='left'
-- gesetzt, weil cleanup_lobby jeden Spieler mit altem last_seen_at
-- als inaktiv behandelt -- Bots haben aber gar keinen eigenen Tab, der
-- last_seen_at je auffrischen könnte. last_seen_at bleibt für einen Bot
-- für immer auf dem Wert vom Beitritt stehen.
--
-- Effekt beim Testen: die zuerst hinzugefügten Bots einer 8er-Lobby
-- verschwanden von selbst, während man noch die restlichen hinzufügte
-- oder alle auf "Bereit" stellte -- rein weil das Zusammenstellen
-- länger als 45s dauerte. Für echte Mitspieler mit eigenem Browser-Tab
-- ist genau diese Prüfung richtig (verwaiste Tabs sollen rausfliegen),
-- für Bots ist sie einfach nur ein Timer bis zum Rauswurf.
--
-- Fix: cleanup_lobby schließt is_bot=true jetzt explizit aus.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_lobby(p_lobby_id uuid, p_stale_seconds integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_new_host uuid;
  v_phase text;
begin
  select host_player_id, phase
    into v_host, v_phase
  from public.lobbies
  where id = p_lobby_id;

  -- Only mark players as 'left' BEFORE the game is running.
  if v_phase is null or v_phase in ('lobby', 'topic_vote', 'countdown') then
    update public.players
    set status = 'left',
        left_at = coalesce(left_at, now())
    where lobby_id = p_lobby_id
      and status = 'active'
      and coalesce(is_bot, false) = false
      and (
        last_seen_at is null
        or last_seen_at < (now() - make_interval(secs => p_stale_seconds))
      );
  end if;

  if v_host is not null then
    if not exists (
      select 1 from public.players
      where lobby_id = p_lobby_id
        and player_id = v_host
        and status = 'active'
    ) then
      select player_id into v_new_host
      from public.players
      where lobby_id = p_lobby_id
        and status = 'active'
      order by joined_at asc nulls last, player_id asc
      limit 1;

      update public.lobbies
      set host_player_id = v_new_host
      where id = p_lobby_id;
    end if;
  end if;
end;
$function$;

COMMIT;


