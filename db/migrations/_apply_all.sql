-- ============================================================
-- KUMPIR — Alle 36 Migrationen in einem File
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


-- ============================================================
-- 036_song_preview_cache.sql
-- ============================================================
-- ============================================================
-- Migration 036: iTunes-Preview-URL pro Song gecacht statt live geladen
-- ============================================================
-- Bisher fragte SongRound.tsx bei JEDEM neuen Song live die iTunes
-- Search API an, um die Preview-URL zu finden -- unnötige Ladezeit und
-- ein externer Request pro Rundenwechsel, obwohl sich der Titel eines
-- Songs nie ändert. Neue Spalten cachen das Ergebnis einmalig in der DB;
-- db/scripts/backfill-song-previews.mjs füllt sie, SongRound.tsx liest
-- nur noch preview_url mit (kein Live-Fetch mehr, außer als Fallback
-- für Songs ohne Treffer).
-- ============================================================

BEGIN;

ALTER TABLE public.song_pool
    ADD COLUMN IF NOT EXISTS preview_url text,
    ADD COLUMN IF NOT EXISTS preview_checked_at timestamptz;

COMMIT;


-- ============================================================
-- 037_song_no_immediate_repeat.sql
-- ============================================================
-- ============================================================
-- Migration 037: Song-Wiederholung -- kein direktes Zweimal-hintereinander
-- ============================================================
-- _pick_next_song schließt bereits gespielte Songs aus (used_song_ids),
-- aber sobald der Pool einer Kategorie erschöpft ist (alle ~20 Songs
-- schon dran), wird er komplett zurückgesetzt und OHNE jede Ausnahme neu
-- gezogen -- dabei konnte der GERADE eben gespielte Song direkt nochmal
-- gezogen werden (spürbar als "der gleiche Song wie eben"). Bei vielen
-- Spielern + dem Pass-Bonus aus Migration 032 (viele Halterwechsel pro
-- Runde) ist der Pool schneller erschöpft als gedacht, der Fall tritt
-- also öfter auf als ursprünglich angenommen.
--
-- Fix: beim Reset wird der aktuell gespielte Song explizit von der
-- Neuziehung ausgeschlossen, garantiert also mindestens "kein Song
-- zweimal direkt hintereinander".
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
begin
  select topic_selected, used_song_ids, current_song_id into v_topic, v_used, v_current
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

  -- Songs im Match aufgebraucht -> Pool für dieses Match wieder freigeben,
  -- aber den gerade gespielten Song von der Neuziehung ausschließen
  -- (Migration 037), damit er nicht direkt zweimal hintereinander drankommt.
  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

COMMIT;

-- ============================================================
-- 038_expand_pop_charts_pool.sql
-- ============================================================
-- ============================================================
-- Migration 038: "Internationale Pop-Charts" erweitert (13 -> 21)
-- ============================================================
-- Kleinster Song-Pool aller Kategorien -- bei langen Matches (viele
-- Runden) war das Risiko am größten, dass der Pool durchläuft und
-- Migration 037 (kein Sofort-Repeat) auf einen sehr kleinen Rest
-- zurückgreifen muss. Quelle: Billboard Global 200 Top-10-Singles
-- 2026 (Wikipedia), Titel/Interpret 1:1 übernommen wie in Migration
-- 033. Preview-URLs holt sich der bestehende Backfill-Job automatisch
-- (preview_checked_at ist bei neuen Zeilen NULL).
-- ============================================================

BEGIN;

INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Internationale Pop-Charts', 'Golden', 'Huntrix (Ejae, Audrey Nuna & Rei Ami)'),
    ('Internationale Pop-Charts', 'Ordinary', 'Alex Warren'),
    ('Internationale Pop-Charts', 'Back to Friends', 'Sombr'),
    ('Internationale Pop-Charts', 'Die with a Smile', 'Lady Gaga & Bruno Mars'),
    ('Internationale Pop-Charts', 'Animal', 'Katseye'),
    ('Internationale Pop-Charts', 'Loser', 'Tame Impala'),
    ('Internationale Pop-Charts', 'BbY WOW', 'Karol G, Judeline & Rusowsky'),
    ('Internationale Pop-Charts', 'Man I Need', 'Olivia Dean')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

COMMIT;

-- ============================================================
-- 039_deutschrap_refresh_and_2000er.sql
-- ============================================================
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

-- ============================================================
-- 040_shisha_club.sql
-- ============================================================
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

-- ============================================================
-- 041_remove_old_music_categories.sql
-- ============================================================
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

-- ============================================================
-- 042_three_topic_choices.sql
-- ============================================================
-- ============================================================
-- Migration 042: Themen-Voting zeigt bei 3 verfügbaren Themen alle
-- 3 echten Themen statt Thema A / Thema B / "Zufällig"
-- ============================================================
-- Bisher: rpc_begin_topic_vote/rpc_start_rematch_if_ready zogen nur
-- ZWEI Themen (topic_a, topic_b); die dritte Voting-Karte war ein
-- generischer "Zufällig"-Button, der serverseitig einfach zufällig
-- zwischen A und B auslost (rpc_finalize_topic_vote, choice=3-Zweig).
-- Seit die Musik-Kategorien auf genau 3 (Deutschrap-Songs, 2000er Old
-- School, Shisha Club) eingedampft wurden, fiel auf: bei genau 3
-- verfügbaren Themen sollten alle 3 echt zur Wahl stehen, nicht 2 +
-- ein Zufalls-Feld.
--
-- Neue Spalte lobbies.topic_c: dritter echter Themen-Pick, NULL wenn
-- der (ggf. gefilterte) Pool keine 3 unterschiedlichen Themen hergibt
-- (dann bleibt es bei 2 echten Wahlmöglichkeiten -- kein Fake-Dritter
-- mehr). Bei nur 1 verfügbarem Thema bleiben a=b=c (wie schon vorher
-- a=b in diesem Fall, siehe Migration 030).
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS topic_c text;

CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text; v_c text; v_filter text[];
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

  if v_a is null then raise exception 'Not enough topics in topic_pool'; end if;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_b is null then
    v_b := v_a;
    v_c := v_a;
  else
    select t.text into v_c from public.topic_pool t
    where t.active is true and t.text <> v_a and t.text <> v_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_c = v_c, topic_selected = null, topic = null,
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
  v_topic_a text; v_topic_b text; v_topic_c text;
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

  if v_topic_a is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_b is null then
    v_topic_b := v_topic_a;
    v_topic_c := v_topic_a;
  else
    select t.text into v_topic_c
    from public.topic_pool t
    where t.active is true and t.text <> v_topic_a and t.text <> v_topic_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_c = v_topic_c, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text; v_topic_c text;
  v_a_count int := 0; v_b_count int := 0; v_c_count int := 0;
  v_selected text; v_pick int; v_choices int[]; v_best int;
begin
  select topic_a, topic_b, topic_c into v_topic_a, v_topic_b, v_topic_c
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  -- Choice 3 zählt nur, wenn es dafür überhaupt ein echtes drittes Thema
  -- gibt -- sonst hat die UI die Karte gar nicht erst angeboten, ein
  -- Bot könnte aber trotzdem (aus alten Client-Ständen o.ä.) 3 schicken.
  if v_topic_c is not null then
    select count(*) into v_c_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;
  end if;

  v_best := greatest(v_a_count, v_b_count, v_c_count);
  v_choices := array[]::int[];
  if v_a_count = v_best then v_choices := array_append(v_choices, 1); end if;
  if v_b_count = v_best then v_choices := array_append(v_choices, 2); end if;
  if v_topic_c is not null and v_c_count = v_best then v_choices := array_append(v_choices, 3); end if;

  if array_length(v_choices, 1) = 1 then
    v_pick := v_choices[1];
    v_choices := null;
  else
    v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
  end if;

  v_selected := case v_pick when 1 then v_topic_a when 2 then v_topic_b else v_topic_c end;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

-- topic_c mit nullen, wo bisher schon topic_a/topic_b genullt wurden
-- (reine Hygiene -- wird vor der nächsten Wahl ohnehin überschrieben).
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
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_reset_lobby(text) FROM PUBLIC, anon, authenticated;


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
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
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
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;

-- ============================================================
-- 043_topic_c_or_random.sql
-- ============================================================
-- ============================================================
-- Migration 043: dritte Voting-Karte zeigt "Zufällig" statt das
-- gleiche Thema nochmal, wenn kein echtes drittes Thema existiert
-- ============================================================
-- Bug aus Migration 042: wenn der (ggf. gefilterte) Pool keine 3
-- unterschiedlichen Themen hergibt (z.B. Musik-Filter nur auf
-- "Deutschrap-Songs" gesetzt -> nur 1 Kategorie verfügbar), wurde
-- topic_c NULL, und das Frontend blendete die dritte Karte einfach
-- aus -- aber der davor bestehende Fallback (topic_b := topic_a bei
-- nur 1 verfügbarem Thema) blieb bestehen, wodurch man "Deutschrap-
-- Songs" als Thema A UND B sah. Kombiniert mit der neuen dritten
-- Karte (falls doch mal minimal was da war) wirkte das wie 3x
-- derselbe Name.
--
-- Fix: Wenn topic_c NULL ist (kein echtes drittes Thema), zeigt die
-- dritte Karte wieder "Zufällig" (wie vor Migration 042) -- ein Klick
-- darauf verlost bei Sieg/Gleichstand zufällig zwischen Thema A und
-- B, zählt aber weiterhin als eigene Stimme. Nur wenn der Pool
-- WIRKLICH 3 unterschiedliche Themen hergibt, ist die dritte Karte
-- ein echtes drittes Thema (Migration-042-Verhalten bleibt dafür
-- unverändert).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text; v_topic_c text;
  v_a_count int := 0; v_b_count int := 0; v_c_count int := 0;
  v_selected text; v_pick int; v_choices int[]; v_best int;
begin
  select topic_a, topic_b, topic_c into v_topic_a, v_topic_b, v_topic_c
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  select count(*) into v_c_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;

  if v_topic_c is not null then
    -- Echtes drittes Thema: symmetrische 3-Wege-Wertung, Gleichstand
    -- lost zufällig unter den bestplatzierten Themen aus.
    v_best := greatest(v_a_count, v_b_count, v_c_count);
    v_choices := array[]::int[];
    if v_a_count = v_best then v_choices := array_append(v_choices, 1); end if;
    if v_b_count = v_best then v_choices := array_append(v_choices, 2); end if;
    if v_c_count = v_best then v_choices := array_append(v_choices, 3); end if;

    if array_length(v_choices, 1) = 1 then
      v_pick := v_choices[1];
      v_choices := null;
    else
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
    end if;

    v_selected := case v_pick when 1 then v_topic_a when 2 then v_topic_b else v_topic_c end;
  else
    -- Kein echtes drittes Thema -- Choice 3 ist "Zufällig" (wie vor
    -- Migration 042): gewinnt/steht im Gleichstand Choice 3, wird
    -- zwischen A und B ausgelost statt selbst ein Ziel zu sein.
    if v_a_count > v_b_count and v_a_count > v_c_count then
      v_selected := v_topic_a; v_pick := 1; v_choices := null;
    elsif v_b_count > v_a_count and v_b_count > v_c_count then
      v_selected := v_topic_b; v_pick := 2; v_choices := null;
    elsif v_c_count > v_a_count and v_c_count > v_b_count then
      v_pick := (array[1,2])[1 + floor(random() * 2)::int];
      v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      v_choices := array[3];
    else
      v_choices := array[]::int[];
      if v_a_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 1); end if;
      if v_b_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 2); end if;
      if v_c_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 3); end if;
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
      if v_pick = 1 then v_selected := v_topic_a;
      elsif v_pick = 2 then v_selected := v_topic_b;
      else
        v_pick := (array[1,2])[1 + floor(random() * 2)::int];
        v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      end if;
    end if;
  end if;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

COMMIT;

-- ============================================================
-- 044_topic_c_null_when_single.sql
-- ============================================================
-- ============================================================
-- Migration 044: topic_c bleibt NULL, wenn der Pool nur 1 Thema hat
-- ============================================================
-- Rest von Migration 042/043: rpc_begin_topic_vote/rpc_start_rematch_
-- if_ready setzten im 1-Themen-Fall (v_b ist null) BEIDE topic_b UND
-- topic_c auf v_a -- dadurch war topic_c nicht mehr NULL, und die dritte
-- Voting-Karte zeigte den Themennamen ein drittes Mal statt "Zufällig"
-- (Migration 043 fixt nur die Auswertung, nicht diese Zuweisung).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text; v_c text; v_filter text[];
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

  if v_a is null then raise exception 'Not enough topics in topic_pool'; end if;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_b is null then
    -- Nur 1 Thema im (ggf. gefilterten) Pool -- topic_c bleibt NULL,
    -- die UI zeigt dafür "Zufällig" statt den Namen ein drittes Mal.
    v_b := v_a;
  else
    select t.text into v_c from public.topic_pool t
    where t.active is true and t.text <> v_a and t.text <> v_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_c = v_c, topic_selected = null, topic = null,
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
  v_topic_a text; v_topic_b text; v_topic_c text;
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

  if v_topic_a is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_b is null then
    v_topic_b := v_topic_a;
  else
    select t.text into v_topic_c
    from public.topic_pool t
    where t.active is true and t.text <> v_topic_a and t.text <> v_topic_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_c = v_topic_c, topic_selected = null,
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
-- 045_song_artist_mode.sql
-- ============================================================
-- ============================================================
-- Migration 045: Zweiter Musik-Modus -- Interpret statt Songtitel
-- ============================================================
-- Bisher musste man im Song-Modus immer den TITEL des versteckten,
-- gerade laufenden Songs nennen. Neue Einstellung
-- lobbies.song_answer_mode ('title' | 'artist', Default 'title'):
-- bei 'artist' muss man stattdessen den/die Interpret(en) DIESES
-- konkreten Songs nennen -- es läuft weiterhin ein einzelner
-- versteckter Song (gleiche Fairness/Strenge wie bisher), nur die
-- erwartete Antwort ist eine andere.
--
-- song_pool.artist ist oft eine Liste ("Amo, Celo & Abdi", "50 Cent,
-- Justin Timberlake, Timbaland") -- die Prüfung splittet auf Komma/
-- "&" und akzeptiert jeden einzelnen genannten Namen für sich.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS song_answer_mode text NOT NULL DEFAULT 'title';

CREATE OR REPLACE FUNCTION public.set_lobby_song_answer_mode(p_lobby_id uuid, p_me_player_id uuid, p_song_answer_mode text)
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

  v_mode := btrim(coalesce(p_song_answer_mode, ''));
  if v_mode not in ('title', 'artist') then raise exception 'invalid_song_answer_mode'; end if;

  update public.lobbies
  set song_answer_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
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
    if coalesce(v_lobby.song_answer_mode, 'title') = 'artist' then
      -- Interpret-Modus: jeder einzeln genannte Interpret des aktuellen
      -- Songs zählt (Feld ist oft eine Liste wie "Amo, Celo & Abdi").
      select exists (
        select 1
        from public.song_pool sp
        cross join lateral unnest(regexp_split_to_array(coalesce(sp.artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
        where sp.id = v_lobby.current_song_id
          and lower(trim(a.name)) = lower(v_clean)
      ) into v_known;
    else
      -- Titel-Modus (Standard): gegen genau den einen aktuellen Song
      -- prüfen (Klammer-Zusätze wie "(feat. ...)" werden toleriert,
      -- exakte Interpreten-Schreibweise wird nicht verlangt).
      select exists (
        select 1 from public.song_pool sp
        where sp.id = v_lobby.current_song_id
          and (
            sp.lower_title = lower(v_clean)
            or regexp_replace(sp.lower_title, '\s*\(.*?\)\s*', '', 'g') = lower(v_clean)
          )
      ) into v_known;
    end if;
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
-- Migration 046: Antworten immer akzeptieren + Host-Live-Kick
-- ============================================================
-- 1) rpc_attempt_pass akzeptiert ab jetzt JEDE getippte Antwort sofort
--    (kein Titel/Interpret-Abgleich, kein Mehrheits-Voting mehr nötig).
--    Die Spieler entscheiden manuell/sozial, wer rausfliegt -- dafür
--    gibt es Punkt 2.
-- 2) Neue RPC rpc_host_kick_during_round: der Host kann während einer
--    laufenden Runde jederzeit einen Spieler sofort eliminieren (kein
--    Bestätigungsdialog im Client nötig). Ist der Gekickte gerade der
--    Halter, rückt automatisch der nächste lebende Spieler nach --
--    exakt wie beim normalen Rundenverlust in rpc_tick_game.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
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

  -- Jede Antwort wird sofort angenommen -- keine Titel/Interpret- oder
  -- Kategorie-Prüfung mehr. Die Spieler entscheiden danach manuell
  -- (Host-Kick), wer eigentlich hätte rausfliegen müssen.
  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_host_kick_during_round(
    p_code TEXT, p_host_player_id UUID, p_target_player_id UUID
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_was_holder boolean;
  v_alive_count int;
  v_next_holder uuid;
  v_round_duration interval;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_host_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.host_player_id is distinct from p_host_player_id then raise exception 'not_host'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if p_target_player_id = p_host_player_id then raise exception 'cannot_kick_self'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_target_player_id
      and status = 'active' and is_alive = true
  ) then raise exception 'target_not_active'; end if;

  v_was_holder := (v_lobby.holder_player_id = p_target_player_id);

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  -- Ein offener Versuch des Gekickten verfällt kommentarlos.
  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = v_lobby.id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target_player_id,
      last_activity_at = now()
  where id = v_lobby.id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby.id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby.id;
    return;
  end if;

  if not v_was_holder then
    -- Halter bleibt unverändert, nur der Kandidatenkreis schrumpft.
    return;
  end if;

  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby.id and p_loser.player_id = p_target_player_id
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_lobby.game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_lobby.round_speed, 'normal'),
    v_alive_count,
    coalesce(v_lobby.round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = now() + v_round_duration,
      round_bonus_used = 0
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 047: slowest_pass_ms -- Basis fürs "Slowest"-Award
-- ============================================================
-- Bisher wurde pro Spieler nur die SCHNELLSTE Passzeit (fastest_pass_ms)
-- getrackt. Fürs neue "Slowest"-Award (Ende-Bildschirm) brauchen wir
-- das Gegenstück: die LANGSAMSTE Passzeit. Gleiche Quelle (v_pass_ms in
-- rpc_pass_potato), nur GREATEST statt LEAST, und wird an denselben 3
-- Stellen wie fastest_pass_ms zurückgesetzt (rpc_reset_lobby x2,
-- rpc_rematch). Alle drei Funktionskörper sind 1:1 aus der LIVE-DB
-- übernommen (per pg_get_functiondef), nur um slowest_pass_ms ergänzt --
-- keine sonstige Verhaltensänderung.
-- ============================================================

BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS slowest_pass_ms numeric;

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 048: "Runden überlebt" -- neue Ranking-Spalte am Ende-Screen
-- ============================================================
-- Neue Spalte players.eliminated_at_round: die Rundennummer, in der ein
-- Spieler ausgeschieden ist (Timer-Explosion ODER Host-Live-Kick aus
-- Migration 046). Bleibt NULL für den/die Sieger (die haben alle Runden
-- überlebt -- das Frontend zeigt für sie lobbies.round_number).
--
-- Nebenbei ein Konsistenz-Fix: rpc_host_kick_during_round erhöhte
-- round_number bisher NICHT (anders als rpc_tick_game bei jeder
-- Explosion) -- dadurch blieben Rundenzahl-abhängige Dinge (Bot-
-- Schwierigkeit, Explosions-Timer-Skalierung) nach einem Kick stehen.
-- Jetzt erhöht auch ein Kick round_number, exakt wie eine Explosion.
-- ============================================================

BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS eliminated_at_round int;

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

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby_id and player_id = v_loser;

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


CREATE OR REPLACE FUNCTION public.rpc_host_kick_during_round(
    p_code TEXT, p_host_player_id UUID, p_target_player_id UUID
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_was_holder boolean;
  v_alive_count int;
  v_next_holder uuid;
  v_round_duration interval;
  v_round_number int;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_host_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.host_player_id is distinct from p_host_player_id then raise exception 'not_host'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if p_target_player_id = p_host_player_id then raise exception 'cannot_kick_self'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_target_player_id
      and status = 'active' and is_alive = true
  ) then raise exception 'target_not_active'; end if;

  v_was_holder := (v_lobby.holder_player_id = p_target_player_id);

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  -- Ein offener Versuch des Gekickten verfällt kommentarlos.
  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = v_lobby.id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target_player_id,
      round_number = coalesce(round_number, 0) + 1,
      last_activity_at = now()
  where id = v_lobby.id
  returning round_number into v_round_number;

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby.id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby.id;
    return;
  end if;

  if not v_was_holder then
    -- Halter bleibt unverändert, nur der Kandidatenkreis schrumpft.
    return;
  end if;

  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby.id and p_loser.player_id = p_target_player_id
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_lobby.game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_lobby.round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = now() + v_round_duration,
      round_bonus_used = 0
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code text, p_player_id uuid)
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text, p_player_id uuid)
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 049: Column-Grant für slowest_pass_ms + eliminated_at_round
-- ============================================================
-- Migration 023 grantet anon/authenticated SELECT nur auf eine explizite
-- Spalten-Allowlist (alles außer dem geheimen session_token). Die 2
-- neuen Spalten aus 047/048 (slowest_pass_ms, eliminated_at_round)
-- standen da noch nicht drin -- das Frontend bekam beim Laden von
-- players() sofort "permission denied for table players" (live im
-- Browser reproduziert). Gleiche Liste wie 023, nur um die 2 neuen
-- Spalten ergänzt.
-- ============================================================

BEGIN;

REVOKE SELECT ON public.players FROM anon, authenticated;
GRANT SELECT (
    id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id,
    seat_index, is_alive, kicked_at, is_online, status, left_at, last_pass_at,
    survival_streak, pass_count, clutch_pass_count, fastest_pass_ms,
    slowest_pass_ms, eliminated_at_round,
    total_hold_ms, is_bot
) ON public.players TO anon, authenticated;

COMMIT;


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


-- ============================================================
-- Migration 051: Nur noch private Lobbys -- Public komplett raus
-- ============================================================
-- Host-UI hatte "Public" schon länger deaktiviert (Migration 020), jetzt
-- wird die Möglichkeit auch serverseitig entfernt statt nur versteckt:
--   - rpc_create_lobby (6-Parameter-Version, die aktuell einzige vom
--     Frontend genutzte Überladung) erzwingt jetzt IMMER 'private',
--     unabhängig vom übergebenen p_privacy-Wert -- Parameter bleibt in
--     der Signatur (Kompatibilität), wird aber ignoriert.
--   - set_lobby_privacy (nachträgliches Umschalten auf öffentlich) und
--     public_lobbies_view (Grundlage für die /browse-Seite) werden
--     komplett entfernt.
-- Die beiden älteren rpc_create_lobby-Überladungen (4/5 Parameter) sind
-- vom aktuellen Frontend ungenutzt und bleiben unangetastet -- sie
-- defaulten bei ungültigem privacy-Wert ohnehin schon auf 'private'.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_create_lobby(p_host_name text, p_privacy text, p_max_players integer, p_round_seconds integer, p_user_id uuid DEFAULT NULL::uuid, p_round_speed text DEFAULT 'normal'::text)
 RETURNS TABLE(code text, host_player_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid := gen_random_uuid();
  v_code text;
  v_host_player_id uuid := gen_random_uuid();
  v_round_speed text := btrim(coalesce(p_round_speed, 'normal'));
  v_privacy text := 'private';
  v_headers text;
  v_token uuid;
begin
  if v_round_speed not in ('fast', 'normal', 'calm') then
    v_round_speed := 'normal';
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

DROP FUNCTION IF EXISTS public.set_lobby_privacy(uuid, uuid, text);
DROP VIEW IF EXISTS public.public_lobbies_view;

COMMIT;


-- ============================================================
-- Migration 052: current_song_started_at -- synchrone Song-Wiedergabe
-- ============================================================
-- Bisher startete jeder Client seinen <audio>-Tag einfach, sobald SEIN
-- eigener Preview-URL-Request/Buffer fertig war -- je nach Netzwerk-
-- Timing hörte jeder Spieler den Song an einer anderen Stelle. Neue
-- Spalte lobbies.current_song_started_at wird von _pick_next_song genau
-- dann gesetzt, wenn ein neuer Song gezogen wird -- das Frontend
-- berechnet daraus für jeden Client dieselbe Ziel-Wiedergabeposition
-- (Date.now() - current_song_started_at) und synct periodisch nach.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS current_song_started_at timestamptz;

-- Migration 049 hat gezeigt: eine neue Spalte erbt NICHT automatisch das
-- SELECT-Grant, das für die restliche Tabelle gilt (bekam nur REFERENCES).
-- Hier defensiv nochmal explizit granten, damit das Frontend sie sofort
-- lesen kann, unabhängig davon, ob lobbies ursprünglich per Tabellen- oder
-- Spalten-Grant abgesichert wurde.
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
begin
  select topic_selected, used_song_ids, current_song_id into v_topic, v_used, v_current
  from public.lobbies where id = p_lobby_id;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null, current_song_started_at = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  -- Songs im Match aufgebraucht -> Pool für dieses Match wieder freigeben,
  -- aber den gerade gespielten Song von der Neuziehung ausschließen, damit
  -- er nicht direkt zweimal hintereinander drankommt.
  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      current_song_started_at = case when v_song_id is null then null else now() end,
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 053: Server-Zeit-Sync + fester Startspieler beim Countdown
-- ============================================================
-- 1) rpc_server_time(): gibt now() zurück. Das Frontend ruft das einmal
--    beim Betreten der Runde auf und berechnet daraus einen Client<->
--    Server-Zeitversatz -- behebt den gemeldeten Bug, dass der "START IN"-
--    Countdown auf einem Gerät bei "10" feststand, während er auf einem
--    anderen normal von "5" runterlief: countdown_ends_at ist bei BEIDEN
--    Geräten identisch (immer +5s ab Finalisierung), ein spürbar
--    falsch gehender Geräte-Takt (Date.now()) reicht aber, um die daraus
--    berechnete Restzeit deutlich zu verfälschen.
-- 2) countdown_starter_player_id: wird SOFORT bei Countdown-Beginn
--    zufällig gezogen (statt erst am Countdown-Ende) und von
--    rpc_advance_from_countdown wiederverwendet -- damit während des
--    Countdowns stabil angezeigt werden kann, WER gleich anfängt, ohne
--    dass sich das am Ende nochmal ändert.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_server_time()
 RETURNS timestamptz
 LANGUAGE sql
 STABLE
AS $function$
  SELECT now();
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_server_time() TO anon, authenticated;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS countdown_starter_player_id uuid;
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text; v_topic_c text;
  v_a_count int := 0; v_b_count int := 0; v_c_count int := 0;
  v_selected text; v_pick int; v_choices int[]; v_best int;
  v_starter uuid;
begin
  select topic_a, topic_b, topic_c into v_topic_a, v_topic_b, v_topic_c
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  select count(*) into v_c_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;

  if v_topic_c is not null then
    -- Echtes drittes Thema: symmetrische 3-Wege-Wertung, Gleichstand
    -- lost zufällig unter den bestplatzierten Themen aus.
    v_best := greatest(v_a_count, v_b_count, v_c_count);
    v_choices := array[]::int[];
    if v_a_count = v_best then v_choices := array_append(v_choices, 1); end if;
    if v_b_count = v_best then v_choices := array_append(v_choices, 2); end if;
    if v_c_count = v_best then v_choices := array_append(v_choices, 3); end if;

    if array_length(v_choices, 1) = 1 then
      v_pick := v_choices[1];
      v_choices := null;
    else
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
    end if;

    v_selected := case v_pick when 1 then v_topic_a when 2 then v_topic_b else v_topic_c end;
  else
    -- Kein echtes drittes Thema -- Choice 3 ist "Zufällig" (wie vor
    -- Migration 042): gewinnt/steht im Gleichstand Choice 3, wird
    -- zwischen A und B ausgelost statt selbst ein Ziel zu sein.
    if v_a_count > v_b_count and v_a_count > v_c_count then
      v_selected := v_topic_a; v_pick := 1; v_choices := null;
    elsif v_b_count > v_a_count and v_b_count > v_c_count then
      v_selected := v_topic_b; v_pick := 2; v_choices := null;
    elsif v_c_count > v_a_count and v_c_count > v_b_count then
      v_pick := (array[1,2])[1 + floor(random() * 2)::int];
      v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      v_choices := array[3];
    else
      v_choices := array[]::int[];
      if v_a_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 1); end if;
      if v_b_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 2); end if;
      if v_c_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 3); end if;
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
      if v_pick = 1 then v_selected := v_topic_a;
      elsif v_pick = 2 then v_selected := v_topic_b;
      else
        v_pick := (array[1,2])[1 + floor(random() * 2)::int];
        v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      end if;
    end if;
  end if;

  select player_id into v_starter
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_starter_player_id = v_starter,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

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
  select round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  -- Der beim Countdown-Beginn gezogene Starter gilt weiter -- nur falls er
  -- inzwischen ungültig wurde (z.B. gekickt), wird neu gezogen.
  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

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
      countdown_starter_player_id = null,
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      round_bonus_used = 0,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 054: Rematch startet automatisch nach 10s, ohne erneutes
-- Bereit-Klicken
-- ============================================================
-- Bisher: rpc_rematch setzte phase='rematch_wait' und wartete, bis JEDER
-- Spieler nochmal manuell auf "Bereit" klickt (rpc_toggle_ready), erst
-- dann lief rpc_start_rematch_if_ready. Jetzt: der erste Tastendruck auf
-- "R" setzt einen 10s-Countdown (countdown_started_at/countdown_ends_at,
-- dieselben Felder wie beim normalen Runden-Countdown, in rematch_wait
-- sonst ungenutzt) -- nach Ablauf startet die nächste Runde automatisch
-- für alle noch anwesenden Spieler, ohne dass irgendjemand nochmal
-- bestätigen muss.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_ends_at = null,
      countdown_started_at = now(), countdown_ends_at = now() + interval '10 seconds',
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_active_count int; v_filter text[];
  v_topic_a text; v_topic_b text; v_topic_c text;
begin
  select id, topic_filter into v_lobby_id, v_filter
  from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;

  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_a is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_b is null then
    v_topic_b := v_topic_a;
  else
    select t.text into v_topic_c
    from public.topic_pool t
    where t.active is true and t.text <> v_topic_a and t.text <> v_topic_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_c = v_topic_c, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id and phase = 'rematch_wait';
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 055: Song-Antworten wieder geprüft (fuzzy), Punkte-System
-- ============================================================
-- Migration 046 hat JEDE Antwort ausnahmslos akzeptiert. Für den
-- Song-Modus (der jetzt durch Migration "Musik läuft immer" in praktisch
-- jeder Runde aktiv ist) soll das differenzierter sein:
--   - Songtitel korrekt (tippfehlertolerant, Groß-/Kleinschreibung egal)
--     -> akzeptiert, 1 Punkt.
--   - Interpret korrekt (einfachere Alternative, falls man den Titel
--     nicht weiß) -> akzeptiert, 0.5 Punkte.
--   - Sonst -> abgelehnt (raise 'answer_incorrect'), der Halter darf es
--     sofort nochmal versuchen (kein Attempt wird angelegt, used_answers
--     bleibt unberührt).
-- Tippfehlertoleranz über levenshtein() (fuzzystrmatch): Schwelle skaliert
-- mit der Titellänge (1 Fehler pro 5 Zeichen, mind. 1), deckt z.B.
-- "Liebe" vs "Liebe+" oder einen vertauschten Buchstaben ab, ohne bei
-- komplett falschen Antworten durchzuwinken.
--
-- Themen OHNE Song (current_song_id null) bleiben unverändert beim
-- Migration-046-Verhalten: jede Antwort wird sofort akzeptiert.
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS song_points numeric NOT NULL DEFAULT 0;
GRANT SELECT ON public.players TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._fuzzy_song_match(p_candidate text, p_answer text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_a text := lower(trim(p_candidate));
  v_b text := lower(trim(p_answer));
  v_a_clean text;
  v_threshold int;
begin
  if v_a = '' or v_b = '' then return false; end if;
  if v_a = v_b then return true; end if;

  -- Klammer-Zusätze wie "(feat. ...)" tolerieren, exakt wie bisher.
  v_a_clean := regexp_replace(v_a, '\s*\(.*?\)\s*', '', 'g');
  if v_a_clean = v_b then return true; end if;

  v_threshold := greatest(1, floor(length(v_a_clean) / 5.0)::int);
  return levenshtein(v_a_clean, v_b) <= v_threshold;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_points numeric;
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

  -- Song-Modus: Titel (1 Punkt) oder Interpret (0.5 Punkte) müssen
  -- tatsächlich passen -- tippfehlertolerant, aber keine Blanko-Annahme
  -- mehr. Falsche Antworten werden abgelehnt, OHNE einen Attempt/Used-
  -- Answers-Eintrag anzulegen, damit sofort ein neuer Versuch möglich ist.
  if v_lobby.current_song_id is not null then
    select title, artist into v_song_title, v_song_artist
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    else
      if exists (
        select 1
        from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
        where public._fuzzy_song_match(a.name, v_clean)
      ) then
        v_points := 0.5;
        v_known := true;
      end if;
    end if;

    if not v_known then
      raise exception 'answer_incorrect';
    end if;

    update public.players
    set song_points = song_points + v_points
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  -- Themen ohne Song: weiterhin jede Antwort sofort annehmen (Migration
  -- 046) -- Spieler entscheiden sozial/per Host-Kick, wer rausfliegt.
  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 056: KRITISCHER Sicherheits-Fix -- session_token versehentlich
-- wieder lesbar gemacht
-- ============================================================
-- Migration 055 hat aus Versehen `GRANT SELECT ON public.players TO anon,
-- authenticated;` OHNE Spaltenliste ausgeführt (wollte nur song_points
-- freigeben) -- das hebt die Spalten-Allowlist aus Migration 023 komplett
-- auf und macht session_token wieder für JEDEN lesbar. Live geprüft und
-- bestätigt: session_token hatte danach SELECT für anon.
--
-- Das ist der exakte Exploit, den Migration 023 ursprünglich geschlossen
-- hat (Identitäts-Spoofing: fremde Antworten einreichen, Vote-Stuffing,
-- Ready-Status fremder Spieler umschalten). Sofort zurückgesetzt auf die
-- Allowlist aus Migration 049 + song_points.
-- ============================================================

BEGIN;

REVOKE SELECT ON public.players FROM anon, authenticated;
GRANT SELECT (
    id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id,
    seat_index, is_alive, kicked_at, is_online, status, left_at, last_pass_at,
    survival_streak, pass_count, clutch_pass_count, fastest_pass_ms,
    slowest_pass_ms, eliminated_at_round, song_points,
    total_hold_ms, is_bot
) ON public.players TO anon, authenticated;

COMMIT;

-- ============================================================
-- Migration 057: song_points bei Reset/Rematch zurücksetzen
-- ============================================================
-- Migration 055 hat players.song_points eingeführt, aber vergessen, es an
-- denselben 3 Stellen wie fastest_pass_ms/slowest_pass_ms zurückzusetzen
-- -- ohne diesen Fix würden Song-Punkte über Rematches/Resets hinweg
-- falsch weiter aufsummiert werden.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_ends_at = null,
      countdown_started_at = now(), countdown_ends_at = now() + interval '10 seconds',
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 058: Lücken in der Antwort-Prüfung schließen
-- ============================================================
-- Gefunden beim Multi-Bot-Checkup:
--  1) Fuzzy-Schwelle war für kurze Titel zu großzügig: bei einem Titel wie
--     "Love" (4 Zeichen) galt "Live"/"Lose"/"Move" (je 1 Fehler) als
--     richtig. Jetzt: bis 4 Zeichen exakt, 5-8 -> 1 Fehler, 9-14 -> 2,
--     darüber 3.
--  2) Antworten NACH Ablauf des Timers (explode_at, +0.5s Toleranz für
--     Netzwerk-Latenz) wurden noch angenommen und verlängerten die Runde
--     über das Bonus-Zeit-Verfahren -- wer die Antwort knapp nach 0 absendet,
--     bevor der Tick feuert, konnte so der Explosion entkommen. Jetzt
--     'time_up'.
--  3) Song-Modus blockierte Antworten über used_answers quer über Songs
--     hinweg: derselbe Interpret ("Eminem") war nach dem ersten Treffer für
--     jeden weiteren Eminem-Song gesperrt (answer_already_used). Im Song-
--     Modus entfällt die Duplikat-Sperre, jeder Song wird einzeln geprüft.
--  4) Unbegrenztes Durchprobieren: nach einer falschen Song-Antwort ist
--     für denselben Spieler 1s Pause (Spalte last_wrong_guess_at, bewusst
--     OHNE SELECT-Grant -- nur die SECURITY-DEFINER-RPC liest sie).
-- ============================================================

BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS last_wrong_guess_at timestamptz;

CREATE OR REPLACE FUNCTION public._fuzzy_song_match(p_candidate text, p_answer text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_a text := lower(trim(p_candidate));
  v_b text := lower(trim(p_answer));
  v_a_clean text;
  v_len int;
  v_threshold int;
begin
  if v_a = '' or v_b = '' then return false; end if;
  if v_a = v_b then return true; end if;

  v_a_clean := regexp_replace(v_a, '\s*\(.*?\)\s*', '', 'g');
  if v_a_clean = '' then return false; end if;
  if v_a_clean = v_b then return true; end if;

  v_len := length(v_a_clean);
  v_threshold := case
    when v_len <= 4 then 0
    when v_len <= 8 then 1
    when v_len <= 14 then 2
    else 3
  end;
  if v_threshold = 0 then return false; end if;
  return levenshtein(v_a_clean, v_b) <= v_threshold;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at into v_last_wrong
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist into v_song_title, v_song_artist
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      v_points := 0.5;
      v_known := true;
    end if;

    if not v_known then
      update public.players set last_wrong_guess_at = now()
      where lobby_id = v_lobby.id and player_id = p_player_id;
      -- Fehlerzustand soll das UPDATE oben nicht zurückrollen: Postgres
      -- rollt bei RAISE die ganze Funktion zurück, daher wird die Sperre
      -- hier bewusst per Rückgabe-Sentinel statt Exception gesetzt.
      return null;
    end if;

    update public.players
    set song_points = song_points + v_points
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 059: Server-seitiger Ticker (pg_cron) -- Match friert nicht mehr ein
-- ============================================================
-- Bisher trieb AUSSCHLIESSLICH die Browser-Seite der Spieler die Phasen
-- an (setInterval ruft rpc_tick_game / rpc_finalize_topic_vote /
-- rpc_advance_from_countdown / rpc_start_rematch_if_ready auf). Sobald ALLE
-- Tabs im Hintergrund waren (Alt-Tab zu Discord, Handy gesperrt, Fenster
-- minimiert), drosselt der Browser die Timer -- die Runde blieb
-- stehen, der überfällige Halter explodierte erst, wenn jemand wieder hinsah
-- (im Multi-Bot-Checkup live reproduziert: explode_at 13s überfällig,
-- nichts passierte).
--
-- Jetzt prüft zusätzlich ein pg_cron-Job alle 2 Sekunden alle Lobbys und ruft
-- die ohnehin idempotenten RPCs bei überfälligen Timern selbst auf. Die
-- Client-Ticks bleiben als schnellere Primärquelle bestehen (die RPCs sind
-- phasengeschützt, doppelte Aufrufe sind harmlos).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._server_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select id, code, phase from public.lobbies
    where (phase = 'running' and explode_at is not null and explode_at <= now())
       or (phase = 'topic_vote' and topic_vote_ends_at is not null and topic_vote_ends_at <= now())
       or (phase = 'countdown' and countdown_ends_at is not null and countdown_ends_at <= now())
       or (phase = 'rematch_wait' and countdown_ends_at is not null and countdown_ends_at <= now())
  loop
    begin
      if r.phase = 'running' then
        perform public.rpc_tick_game(r.code);
      elsif r.phase = 'topic_vote' then
        perform public.rpc_finalize_topic_vote(r.id);
      elsif r.phase = 'countdown' then
        perform public.rpc_advance_from_countdown(r.id);
      elsif r.phase = 'rematch_wait' then
        perform public.rpc_start_rematch_if_ready(r.code);
      end if;
    exception when others then
      -- Eine kaputte Lobby (z.B. nur 1 Spieler im Rematch) darf den
      -- Ticker für alle anderen nicht blockieren.
      null;
    end;
  end loop;
end;
$function$;

REVOKE ALL ON FUNCTION public._server_tick() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kumpir-server-tick';
SELECT cron.schedule('kumpir-server-tick', '2 seconds', 'select public._server_tick()');

COMMIT;


-- ============================================================
-- Migration 060: Pass-/Haltezeit = Zeit seit ERHALT der Kartoffel
-- ============================================================
-- rpc_pass_potato maß v_pass_ms bisher als Zeit seit dem EIGENEN letzten
-- Pass (beim ersten Pass: seit Rundenstart). Das schloss die komplette
-- Wartezeit ein, in der andere Spieler dran waren -- im Ende-Screen
-- standen dadurch "Fastest Pass"-Werte von 47-56 Sekunden, "Fastest" und
-- "Slowest" waren bei nur einem Pass identisch, und "Longest Hold" war
-- einfach "wer hat am längsten überlebt".
--
-- Neu: lobbies.holder_since wird per Trigger bei JEDEM Halterwechsel auf
-- now() gesetzt. rpc_pass_potato liest es vor dem Wechsel und misst damit
-- die echte Haltezeit (Kartoffel erhalten -> abgegeben). Fastest/Slowest/
-- Longest Hold bekommen dadurch wieder ihre eigentliche Bedeutung.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS holder_since timestamptz;
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._set_holder_since()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.holder_player_id is distinct from OLD.holder_player_id then
    NEW.holder_since := case when NEW.holder_player_id is null then null else now() end;
  end if;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_set_holder_since ON public.lobbies;
CREATE TRIGGER lobbies_set_holder_since
  BEFORE UPDATE OF holder_player_id ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._set_holder_since();

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number, coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number, v_bonus_used, v_since
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

  -- Haltezeit = von Erhalt der Kartoffel (holder_since) bis jetzt.
  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 061: "Kumpir Arena" -- Wettbewerbs-Regelwerk
-- ============================================================
-- Ziel: schneller werdendes, faires Duell-Format rund um Songs erraten.
--
--  1) TEMPO-STUFEN: Die Zündschnur wird mit jeder Eliminierung deutlich
--     kürzer (-6 % pro Runde, Boden bei 45 %; vorher -3 %/Boden 65 %).
--  2) DUELL-FINALE: Bei nur noch 2 Lebenden ist die Schnur 20 % kürzer
--     und Pässe geben KEINE Bonuszeit mehr -- das Finale ist ein
--     reines Nervenspiel.
--  3) QUALITÄTS-BONUS: Die Bonuszeit pro Pass hängt von der Antwort ab:
--     Songtitel = volle Bonuszeit, Interpret = halbe Bonuszeit. Wer den
--     Titel weiß, wird mit mehr Zeit belohnt (Titel > Interpret).
--  4) SONG-TAUSCH (Joker): Jeder Spieler darf pro Match EINMAL seinen
--     Song gegen einen neuen tauschen (kostet 2s Zündschnur, nur wenn
--     noch >3s übrig sind). Gleicht Pech bei der Songziehung aus.
--  5) FAIRE SITZORDNUNG: Zu Matchbeginn werden die Sitzplätze zufällig
--     gemischt -- wer zuerst beigetreten ist (Host), hat keinen festen
--     Vorteil/Nachteil in der Weitergabe-Reihenfolge mehr.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_pass_quality numeric NOT NULL DEFAULT 1;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS skips_left int NOT NULL DEFAULT 1;
-- NUR die neue Spalte freigeben (kein Tabellen-GRANT -- siehe Migration 056).
GRANT SELECT (skips_left) ON public.players TO anon, authenticated;
GRANT SELECT ON public.lobbies TO anon, authenticated;

-- ------------------------------------------------------------
-- 1+2) Zündschnur: Tempo-Stufen + Duell
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calc_explode_seconds(p_round_speed text, p_alive_count integer, p_round_number integer, p_exponent numeric DEFAULT 1.9, p_quantize_step_sec numeric DEFAULT 0.5, p_clamp_min_sec numeric DEFAULT 3)
 RETURNS numeric
 LANGUAGE plpgsql
AS $function$
declare
  base_min numeric;
  base_max numeric;
  scale_alive numeric;
  scale_round numeric;
  scale_duel numeric := 1.0;
  min_sec numeric;
  max_sec numeric;
  u numeric;
  biased numeric;
  raw numeric;
  quantized numeric;
begin
  if p_round_speed = 'fast' then
    base_min := 9;  base_max := 16;
  elsif p_round_speed = 'normal' then
    base_min := 14; base_max := 26;
  elsif p_round_speed = 'calm' then
    base_min := 22; base_max := 40;
  else
    base_min := 14; base_max := 26;
  end if;

  scale_alive := greatest(0.75, least(1.25, 1.15 - (p_alive_count * 0.035)));

  -- Tempo-Stufen: -6 % pro Eliminierung, nicht unter 45 %.
  scale_round := greatest(0.45, 1.0 - greatest(0, (p_round_number - 1)) * 0.06);

  -- Duell-Finale: bei 2 Lebenden 20 % kürzer.
  if p_alive_count <= 2 then scale_duel := 0.8; end if;

  min_sec := greatest(p_clamp_min_sec, base_min * scale_alive * scale_round * scale_duel);
  max_sec := greatest(min_sec + 1, base_max * scale_alive * scale_round * scale_duel);

  u := random();
  biased := power(u, p_exponent);
  raw := min_sec + biased * (max_sec - min_sec);

  quantized := round(raw / p_quantize_step_sec) * p_quantize_step_sec;

  return greatest(p_clamp_min_sec, quantized);
end;
$function$;

-- ------------------------------------------------------------
-- 3) Qualität der Antwort merken (Titel 1.0 / Interpret 0.5)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at into v_last_wrong
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist into v_song_title, v_song_artist
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      v_points := 0.5;
      v_known := true;
    end if;

    if not v_known then
      update public.players set last_wrong_guess_at = now()
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    v_quality := v_points;

    update public.players
    set song_points = song_points + v_points
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ------------------------------------------------------------
-- 2+3) Bonuszeit: Qualität skaliert, im Duell keine
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
  v_quality numeric;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number, coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at), coalesce(l.last_pass_quality, 1)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number, v_bonus_used, v_since, v_quality
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

  v_bonus_cap := public.calc_pass_bonus_cap(n);
  -- Titel = volle Bonuszeit, Interpret = halbe; im Duell (2 Lebende) keine.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second'),
      round_bonus_used = v_bonus_used + v_bonus_applied,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

-- ------------------------------------------------------------
-- 4) Song-Tausch-Joker
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_skip_song(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_skips int;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_song_id is null then raise exception 'no_song'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  select skips_left into v_skips from public.players
  where lobby_id = v_lobby.id and player_id = p_player_id;
  if coalesce(v_skips, 0) <= 0 then raise exception 'no_skips_left'; end if;

  if v_lobby.explode_at is null or v_lobby.explode_at - now() < interval '3 seconds' then
    raise exception 'too_late';
  end if;

  update public.players set skips_left = skips_left - 1
  where lobby_id = v_lobby.id and player_id = p_player_id;

  update public.lobbies
  set explode_at = explode_at - interval '2 seconds', last_activity_at = now()
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_skip_song(text, uuid) TO anon, authenticated;

-- ------------------------------------------------------------
-- 5) Matchstart: Sitze mischen, Joker auffüllen
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
  v_phase text;
begin
  select phase, round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_phase, v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'countdown' then return; end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  -- Faire Weitergabe-Reihenfolge: Sitzplätze zufällig mischen.
  -- (unique_seat_per_lobby gilt für ALLE Zeilen der Lobby inkl. gegangener
  -- Spieler -> nur innerhalb der bereits belegten Plätze permutieren, in
  -- zwei Schritten über temporär negative Werte.)
  with act as (
    select player_id, seat_index as old_seat,
           row_number() over (order by seat_index) as rk
    from public.players
    where lobby_id = p_lobby_id and status = 'active'
  ), shuf as (
    select player_id, row_number() over (order by random()) as rk from act
  ), pick as (
    select s.player_id, a.old_seat
    from shuf s join act a on a.rk = s.rk
  )
  update public.players p set seat_index = -(pick.old_seat + 1)
  from pick where p.lobby_id = p_lobby_id and p.player_id = pick.player_id;

  update public.players set seat_index = -seat_index - 1
  where lobby_id = p_lobby_id and status = 'active' and seat_index < 0;

  update public.players set skips_left = 1
  where lobby_id = p_lobby_id and status = 'active';

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
      countdown_starter_player_id = null,
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      round_bonus_used = 0,
      last_pass_quality = 1,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 062: Serien -- mehrere Durchgänge pro Match + Zwischenstand
-- ============================================================
-- Der Host wählt beim Erstellen, wie viele Durchgänge gespielt werden
-- (1 / 3 / 5). Jeder Durchgang läuft wie bisher bis nur noch EIN Spieler
-- übrig ist. Danach:
--   - die Platzierungen + Arena-Punkte des Durchgangs werden in
--     series_results gespeichert,
--   - ist es nicht der letzte Durchgang -> Phase 'set_summary' (Zwischen-
--     stand, 12s), danach automatisch neues Themen-Voting (rpc_start_next_set),
--   - ist es der letzte -> 'finished' mit Gesamtwertung.
-- Arena-Punkte pro Durchgang (identisch zur Client-Anzeige):
--   Platzierung (1. = 100 ... Letzter = 0, linear) + Song-Punkte x 15 + Clutch x 10
-- Zusätzlich: Saison-Punkte (Monat) für eingeloggte Spieler.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_total int NOT NULL DEFAULT 1;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_index int NOT NULL DEFAULT 1;

-- Neue Phase 'set_summary' (Zwischenstand) im Check-Constraint zulassen.
ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_phase_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_phase_check CHECK (phase = ANY (ARRAY['waiting','lobby','topic_vote','countdown','running','finished','rematch_wait','set_summary']));
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.series_results (
  id bigserial PRIMARY KEY,
  lobby_id uuid NOT NULL,
  set_index int NOT NULL,
  player_id uuid NOT NULL,
  name text NOT NULL,
  place int NOT NULL,
  arena_points int NOT NULL,
  song_points numeric NOT NULL DEFAULT 0,
  rounds_survived int NOT NULL DEFAULT 0,
  passes int NOT NULL DEFAULT 0,
  clutch int NOT NULL DEFAULT 0,
  is_bot boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lobby_id, set_index, player_id)
);
CREATE INDEX IF NOT EXISTS series_results_lobby_idx ON public.series_results (lobby_id, set_index);
ALTER TABLE public.series_results ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS series_results_read ON public.series_results;
CREATE POLICY series_results_read ON public.series_results FOR SELECT USING (true);
GRANT SELECT ON public.series_results TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.season_points (
  user_id uuid NOT NULL,
  season text NOT NULL,
  arena_points int NOT NULL DEFAULT 0,
  sets_played int NOT NULL DEFAULT 0,
  set_wins int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, season)
);
ALTER TABLE public.season_points ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS season_points_read ON public.season_points;
CREATE POLICY season_points_read ON public.season_points FOR SELECT USING (true);
GRANT SELECT ON public.season_points TO anon, authenticated;

-- Neue Serie (Rematch / zurück in die Lobby) beginnt wieder bei Durchgang 1.
CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_reset_series ON public.lobbies;
CREATE TRIGGER lobbies_reset_series
  BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._reset_series_on_phase();

-- Host stellt die Anzahl Durchgänge ein (nur in der Wartelobby).
CREATE OR REPLACE FUNCTION public.set_lobby_series(p_lobby_id uuid, p_me_player_id uuid, p_total int)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_phase text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then raise exception 'invalid_session'; end if;
  select host_player_id, phase into v_host, v_phase from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  if v_phase not in ('waiting', 'finished') then raise exception 'lobby_not_waiting'; end if;
  if p_total not in (1, 3, 5) then raise exception 'invalid_series_total'; end if;
  update public.lobbies
  set series_total = p_total, settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

-- ------------------------------------------------------------
-- Durchgang abschließen: Ergebnisse speichern, dann Zwischenstand
-- oder Serienende.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.clutch * 10,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.is_bot, false) as is_bot
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler.
  for r in
    select p.user_id, sr.arena_points, sr.place
    from public.series_results sr
    join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
    where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
  loop
    insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
    values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
    on conflict (user_id, season) do update
      set arena_points = public.season_points.arena_points + excluded.arena_points,
          sets_played = public.season_points.sets_played + 1,
          set_wins = public.season_points.set_wins + excluded.set_wins,
          updated_at = now();
  end loop;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    begin
      perform public.aggregate_player_stats(p_lobby_id);
    exception when others then
      null;
    end;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public._finish_round(uuid) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Nächster Durchgang: Spieler zurücksetzen, neues Themen-Voting.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_start_next_set(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_phase text; v_filter text[]; v_prev text; v_ends timestamptz;
  v_topic_a text; v_topic_b text; v_topic_c text;
begin
  select id, phase, topic_filter, topic_selected, countdown_ends_at
    into v_lobby_id, v_phase, v_filter, v_prev, v_ends
  from public.lobbies where code = upper(trim(p_code)) for update;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'set_summary' then return; end if;
  if v_ends is not null and v_ends > now() + interval '1 second' then return; end if;

  -- Neues Thema bevorzugt NICHT dasselbe wie im letzten Durchgang.
  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter)) and t.text is distinct from v_prev
  order by random() limit 1;
  if v_topic_a is null then
    select t.text into v_topic_a from public.topic_pool t
    where t.active is true and (v_filter is null or t.text = any(v_filter)) order by random() limit 1;
  end if;
  if v_topic_a is null then raise exception 'Nicht genug Themen im topic_pool'; end if;

  select t.text into v_topic_b from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;
  if v_topic_b is null then
    v_topic_b := v_topic_a;
  else
    select t.text into v_topic_c from public.topic_pool t
    where t.active is true and t.text <> v_topic_a and t.text <> v_topic_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      series_index = series_index + 1,
      round_number = 1, pass_direction = 1,
      topic_a = v_topic_a, topic_b = v_topic_b, topic_c = v_topic_c, topic_selected = null,
      topic_vote_started_at = now(), topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_loser_player_id = null, current_attempt_id = null, used_answers = '{}',
      last_activity_at = now()
  where id = v_lobby_id and phase = 'set_summary';
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_start_next_set(text) TO anon, authenticated;

-- ------------------------------------------------------------
-- Matchende läuft jetzt über _finish_round (Tick + Host-Kick)
-- ------------------------------------------------------------
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

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby_id and player_id = v_loser;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    perform public._finish_round(v_lobby_id);
    return;
  end if;

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

CREATE OR REPLACE FUNCTION public.rpc_host_kick_during_round(
    p_code TEXT, p_host_player_id UUID, p_target_player_id UUID
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_was_holder boolean;
  v_alive_count int;
  v_next_holder uuid;
  v_round_duration interval;
  v_round_number int;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_host_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.host_player_id is distinct from p_host_player_id then raise exception 'not_host'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if p_target_player_id = p_host_player_id then raise exception 'cannot_kick_self'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_target_player_id
      and status = 'active' and is_alive = true
  ) then raise exception 'target_not_active'; end if;

  v_was_holder := (v_lobby.holder_player_id = p_target_player_id);

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = v_lobby.id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target_player_id,
      round_number = coalesce(round_number, 0) + 1,
      last_activity_at = now()
  where id = v_lobby.id
  returning round_number into v_round_number;

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    perform public._finish_round(v_lobby.id);
    return;
  end if;

  if not v_was_holder then
    return;
  end if;

  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby.id and p_loser.player_id = p_target_player_id
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_lobby.game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_lobby.round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = now() + v_round_duration,
      round_bonus_used = 0
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;

-- ------------------------------------------------------------
-- Server-Ticker kennt den Zwischenstand
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._server_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select id, code, phase from public.lobbies
    where (phase = 'running' and explode_at is not null and explode_at <= now())
       or (phase = 'topic_vote' and topic_vote_ends_at is not null and topic_vote_ends_at <= now())
       or (phase = 'countdown' and countdown_ends_at is not null and countdown_ends_at <= now())
       or (phase in ('rematch_wait', 'set_summary') and countdown_ends_at is not null and countdown_ends_at <= now())
  loop
    begin
      if r.phase = 'running' then
        perform public.rpc_tick_game(r.code);
      elsif r.phase = 'topic_vote' then
        perform public.rpc_finalize_topic_vote(r.id);
      elsif r.phase = 'countdown' then
        perform public.rpc_advance_from_countdown(r.id);
      elsif r.phase = 'rematch_wait' then
        perform public.rpc_start_rematch_if_ready(r.code);
      elsif r.phase = 'set_summary' then
        perform public.rpc_start_next_set(r.code);
      end if;
    exception when others then
      null;
    end;
  end loop;
end;
$function$;

COMMIT;


-- ============================================================
-- Migration 063: Combo, Song-Schwierigkeit, Rache-Pass, Anti-Leak
-- ============================================================
--  1) ANTI-LEAK (wichtig für Fairness): song_pool.title / artist /
--     lower_title waren für JEDEN Client per API lesbar -- wer die
--     Browser-Konsole öffnete, konnte die Lösung des laufenden Songs
--     nachschlagen. Jetzt nur noch Spalten ohne Lösung freigegeben.
--  2) COMBO: Titel-Treffer in Folge geben Extra-Bonuszeit (+0.5s pro
--     weiterem Treffer, max +2s). Interpret-Treffer oder Fehlversuch
--     setzen die Combo zurück.
--  3) SCHWIERIGKEIT: adaptiv aus echten Daten (Trefferquote Titel pro
--     Ziehung, ab 5 Ziehungen): leicht x0.8, mittel x1.0, schwer x1.3
--     auf die Bonuszeit. Sichtbar als Sterne beim Halter.
--  4) RACHE-PASS: Wer ausgeschieden ist, darf EINMAL pro Durchgang die
--     Weitergabe-Richtung drehen (rpc_revenge_flip).
-- ============================================================

BEGIN;

-- ---------- 1) Anti-Leak ----------
ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS plays int NOT NULL DEFAULT 0;
ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS hits int NOT NULL DEFAULT 0;

REVOKE SELECT ON public.song_pool FROM anon, authenticated;
GRANT SELECT (id, topic_pool_id, created_at, preview_url, preview_checked_at) ON public.song_pool TO anon, authenticated;

-- ---------- Spalten ----------
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS combo int NOT NULL DEFAULT 0;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS revenge_used boolean NOT NULL DEFAULT false;
GRANT SELECT (combo, revenge_used) ON public.players TO anon, authenticated;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_pass_diff numeric NOT NULL DEFAULT 1;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_pass_combo_bonus numeric NOT NULL DEFAULT 0;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS current_song_difficulty smallint NOT NULL DEFAULT 2;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS revenge_nonce int NOT NULL DEFAULT 0;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_revenge_by uuid;
GRANT SELECT ON public.lobbies TO anon, authenticated;

-- Combo/Rache-Pass pro Durchgang zurücksetzen (jedes neue Themen-Voting
-- = neuer Durchgang) und beim Zurück-in-die-Lobby / Rematch.
CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
 AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from NEW.phase then
    update public.players set combo = 0, revenge_used = false where lobby_id = NEW.id;
    NEW.pass_direction := 1;
  end if;
  return NEW;
end;
$function$;

-- ---------- 3) Schwierigkeit ----------
CREATE OR REPLACE FUNCTION public._song_difficulty(p_plays int, p_hits int)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when coalesce(p_plays, 0) < 5 then 2
    when p_hits::numeric / p_plays >= 0.6 then 1
    when p_hits::numeric / p_plays >= 0.3 then 2
    else 3
  end::smallint;
$function$;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
  v_plays int; v_hits int;
begin
  select topic_selected, used_song_ids, current_song_id into v_topic, v_used, v_current
  from public.lobbies where id = p_lobby_id;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null, current_song_started_at = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  if v_song_id is not null then
    update public.song_pool set plays = plays + 1 where id = v_song_id
    returning plays, hits into v_plays, v_hits;
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      current_song_started_at = case when v_song_id is null then null else now() end,
      current_song_difficulty = public._song_difficulty(v_plays, v_hits),
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

-- ---------- 2+3) Antwort prüfen: Combo + Schwierigkeit ----------
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_plays int; v_hits int;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
  v_diff numeric := 1;
  v_combo int := 0;
  v_combo_bonus numeric := 0;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at, combo into v_last_wrong, v_combo
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist, plays, hits into v_song_title, v_song_artist, v_plays, v_hits
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      v_points := 0.5;
      v_known := true;
    end if;

    if not v_known then
      update public.players set last_wrong_guess_at = now(), combo = 0
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    v_quality := v_points;
    v_diff := case public._song_difficulty(v_plays, v_hits) when 1 then 0.8 when 3 then 1.3 else 1.0 end;

    if v_points = 1 then
      v_combo := coalesce(v_combo, 0) + 1;
      v_combo_bonus := case when v_combo >= 2 then least(2, 0.5 * (v_combo - 1)) else 0 end;
      update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
    else
      v_combo := 0;
    end if;

    update public.players
    set song_points = song_points + v_points, combo = v_combo
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality,
      last_pass_diff = v_diff, last_pass_combo_bonus = v_combo_bonus
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ---------- Nächster lebender Spieler in Richtung ----------
CREATE OR REPLACE FUNCTION public._next_alive(p_lobby_id uuid, p_from uuid, p_dir int)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v_seat int; v_next uuid;
begin
  select seat_index into v_seat from public.players where lobby_id = p_lobby_id and player_id = p_from;
  if coalesce(p_dir, 1) >= 0 then
    select player_id into v_next from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true and seat_index > v_seat
    order by seat_index asc limit 1;
    if v_next is null then
      select player_id into v_next from public.players
      where lobby_id = p_lobby_id and status = 'active' and is_alive = true
      order by seat_index asc limit 1;
    end if;
  else
    select player_id into v_next from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true and seat_index < v_seat
    order by seat_index desc limit 1;
    if v_next is null then
      select player_id into v_next from public.players
      where lobby_id = p_lobby_id and status = 'active' and is_alive = true
      order by seat_index desc limit 1;
    end if;
  end if;
  return v_next;
end;
$function$;

-- ---------- Weitergabe: Qualität x Schwierigkeit + Combo, Richtung ----------
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
  v_quality numeric; v_diff numeric; v_combo_bonus numeric;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number,
         coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at),
         coalesce(l.last_pass_quality, 1), coalesce(l.last_pass_diff, 1), coalesce(l.last_pass_combo_bonus, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number,
         v_bonus_used, v_since, v_quality, v_diff, v_combo_bonus
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
    -- Original: Richtung kann durch den Rache-Pass gedreht sein.
    if coalesce(v_dir, 1) >= 0 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  v_bonus_cap := public.calc_pass_bonus_cap(n);
  -- Basis (Runde) x Antwortqualität (Titel 1 / Interpret 0.5) x Song-
  -- Schwierigkeit + Combo-Bonus; im Duell (2 Lebende) gar keine Bonuszeit.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality * v_diff + v_combo_bonus;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second'),
      round_bonus_used = v_bonus_used + v_bonus_applied,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

-- ---------- Tick/Kick: Richtung beachten ----------
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int; v_dir int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, pass_direction
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_dir
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  if v_now < v_explode_at then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0, combo = 0
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

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby_id and player_id = v_loser;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    perform public._finish_round(v_lobby_id);
    return;
  end if;

  v_next_holder := public._next_alive(v_lobby_id, v_loser, case when v_game_mode = 'original' then v_dir else 1 end);

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
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
end;
$function$;

-- ---------- 4) Rache-Pass ----------
CREATE OR REPLACE FUNCTION public.rpc_revenge_flip(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_alive int;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then raise exception 'invalid_session'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.game_mode <> 'original' then raise exception 'mode_not_supported'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_player_id and status = 'active'
      and is_alive = false and eliminated_at_round is not null and revenge_used = false
  ) then raise exception 'no_revenge_available'; end if;

  select count(*) into v_alive from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;
  if v_alive <= 2 then raise exception 'duel_no_revenge'; end if;

  update public.players set revenge_used = true
  where lobby_id = v_lobby.id and player_id = p_player_id;

  update public.lobbies
  set pass_direction = (coalesce(pass_direction, 1) * -1)::smallint,
      revenge_nonce = revenge_nonce + 1,
      last_revenge_by = p_player_id,
      last_activity_at = now()
  where id = v_lobby.id;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_revenge_flip(text, uuid) TO anon, authenticated;

COMMIT;


-- ============================================================
-- Migration 064: Bots laufen auf dem Server -- unabhängig vom Host-Browser
-- ============================================================
-- Bisher steuerte useBotEngine die Bots NUR im Browser des Hosts: Tab im
-- Hintergrund / Host weg => alle Bots standen still. Jetzt übernimmt ein
-- pg_cron-Job (jede Sekunde) die Bots direkt an die Runde gebunden:
--   - Themen-Voting: jeder Bot stimmt nach 1.0-3.5s ab (deterministisch
--     pro Bot+Voting aus einem Hash, damit es nicht jede Sekunde neu
--     gewürfelt wird).
--   - Laufende Runde: ist ein Bot Halter, antwortet er nach 1.2-3.8s mit
--     dem ECHTEN Songtitel -- aber nur mit der Erfolgswahrscheinlichkeit
--     der Runde (Runde 1: 90 %, 2: 60 %, 3: 40 %, 4: 20 %, danach min.
--     10 %). Bei "Misserfolg" tut der Bot nichts, die Schnur entscheidet.
-- Alles deterministisch aus holder_since => keine Doppel-Würfe pro Tick.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._bot_survival(p_round int)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when coalesce(p_round, 1) <= 1 then 0.9
    when p_round = 2 then 0.6
    when p_round = 3 then 0.4
    when p_round = 4 then 0.2
    else greatest(0.1, 0.2 - (p_round - 4) * 0.05)
  end;
$function$;

CREATE OR REPLACE FUNCTION public._bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_delay numeric;
  v_roll numeric;
  v_answer text;
  v_seed text;
begin
  -- ---------- Themen-Voting ----------
  for r in
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % 3))
      on conflict (lobby_id, player_id) do nothing;
    end if;
  end loop;

  -- ---------- Laufende Runde: Bot ist Halter ----------
  for r in
    select l.id, l.code, l.holder_player_id, l.holder_since, l.round_number, l.current_song_id,
           l.topic_selected, l.used_answers, l.explode_at
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := 1.2 + (abs(hashtext(v_seed)) % 2600) / 1000.0;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number) then continue; end if;

    v_answer := null;
    if r.current_song_id is not null then
      select title into v_answer from public.song_pool where id = r.current_song_id;
    else
      select ta.answer into v_answer
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(coalesce(r.topic_selected, ''))
        and not (ta.lower_answer = any (select lower(u) from unnest(r.used_answers) u))
      order by random() limit 1;
      v_answer := coalesce(v_answer, 'Keine Ahnung');
    end if;

    if v_answer is not null then
      begin
        perform public.rpc_attempt_pass(r.code, r.holder_player_id, v_answer);
      exception when others then
        null;
      end;
    end if;
  end loop;
end;
$function$;

REVOKE ALL ON FUNCTION public._bot_tick() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kumpir-bot-tick';
SELECT cron.schedule('kumpir-bot-tick', '1 seconds', 'select public._bot_tick()');

COMMIT;


-- ============================================================
-- Migration 065: Saison-Bestenliste (Monats-Saison)
-- ============================================================
-- season_points wird seit Migration 062 bei jedem Durchgang für
-- eingeloggte Spieler gefüllt (Arena-Punkte, gespielte Durchgänge,
-- Durchgangs-Siege). Diese View liefert die Rangliste pro Saison
-- (Saison = Kalendermonat, 'YYYY-MM') inkl. Benutzername.
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW public.season_leaderboard_view
  WITH (security_invoker = true) AS
SELECT sp.season, sp.user_id, pr.username, sp.arena_points, sp.sets_played, sp.set_wins,
       rank() OVER (PARTITION BY sp.season ORDER BY sp.arena_points DESC, sp.set_wins DESC) AS rank
FROM public.season_points sp
JOIN public.profiles pr ON pr.id = sp.user_id
WHERE pr.username IS NOT NULL;

GRANT SELECT ON public.season_leaderboard_view TO anon, authenticated;

COMMIT;

-- >>> 066_fair_topic_voting.sql <<<
-- ============================================================
-- Migration 066: faires Themen-Voting (2 Themen + Zufalls-Karte)
-- ============================================================
-- Karte 1 + 2 sind benannte Themen, Karte 3 ist immer "Zufall".
-- Gewinnt/steht die Zufalls-Karte, wird ein Thema aus ALLEN übrigen
-- Playlists (ohne die beiden angezeigten) gewichtet gezogen.
--
-- Balancing:
--   * Themen, die in diesem Match noch NICHT dran waren, haben dreifaches
--     Gewicht (Auswahl der Karten + Zufalls-Karte).
--   * Gleichstand beim Voting: Optionen mit frischem (noch nicht gespieltes)
--     Thema gewinnen vor bereits gespielten; bleibt ein Gleichstand, entscheidet
--     das Los.
--   * Das Thema des vorherigen Durchgangs wird bei den Karten gemieden.
--   * Startspieler der Runde: wer in diesem Match schon öfter starten
--     musste, wird seltener gezogen.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_topics text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_starters uuid[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    NEW.series_topics := '{}';
    NEW.series_starters := '{}';
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  return NEW;
end;
$function$;

-- Alle wählbaren Themen der Lobby (Musik-Filter beachtet)
CREATE OR REPLACE FUNCTION public._vote_topic_pool(p_filter text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(t.text), '{}')
  from public.topic_pool t
  where t.active is true and (p_filter is null or t.text = any(p_filter));
$function$;

-- Gewichtete Ziehung: noch nicht gespielte Themen zählen dreifach.
CREATE OR REPLACE FUNCTION public._weighted_topic(p_cands text[], p_played text[])
 RETURNS text
 LANGUAGE sql
 VOLATILE
 SET search_path TO 'public'
AS $function$
  select c
  from unnest(coalesce(p_cands, '{}')) as c
  order by -ln(greatest(random(), 1e-12)) / (case when c = any(coalesce(p_played, '{}')) then 1.0 else 3.0 end)
  limit 1;
$function$;

-- Zwei Karten-Themen ziehen (A, B). topic_c bleibt NULL = Zufalls-Karte.
CREATE OR REPLACE FUNCTION public._pick_vote_topics(p_lobby_id uuid, OUT o_a text, OUT o_b text)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_filter text[]; v_played text[]; v_prev text; v_all text[];
begin
  select topic_filter, series_topics, topic_selected into v_filter, v_played, v_prev
  from public.lobbies where id = p_lobby_id;

  v_all := public._vote_topic_pool(v_filter);
  if coalesce(array_length(v_all, 1), 0) = 0 then raise exception 'Nicht genug Themen im topic_pool'; end if;

  -- A: gewichtet, möglichst nicht das Thema der letzten Runde
  o_a := public._weighted_topic(array(select x from unnest(v_all) x where x is distinct from v_prev), v_played);
  if o_a is null then o_a := public._weighted_topic(v_all, v_played); end if;

  o_b := public._weighted_topic(array(select x from unnest(v_all) x where x <> o_a), v_played);
  if o_b is null then o_b := o_a; end if;
end;
$function$;

-- ------------------------------------------------------------
-- Voting starten (Host)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id for update;
  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(p_lobby_id);

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;

-- ------------------------------------------------------------
-- Rematch: neues Voting
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_active_count int; v_a text; v_b text;
begin
  select id into v_lobby_id from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';
  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(v_lobby_id);

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id and phase = 'rematch_wait';
end;
$function$;

-- ------------------------------------------------------------
-- Nächste Runde des Matches: neues Voting
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_start_next_set(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_phase text; v_ends timestamptz; v_a text; v_b text;
begin
  select id, phase, countdown_ends_at into v_lobby_id, v_phase, v_ends
  from public.lobbies where code = upper(trim(p_code)) for update;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'set_summary' then return; end if;
  if v_ends is not null and v_ends > now() + interval '1 second' then return; end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(v_lobby_id);

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      series_index = series_index + 1,
      round_number = 1, pass_direction = 1,
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null,
      topic_vote_started_at = now(), topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_loser_player_id = null, current_attempt_id = null, used_answers = '{}',
      last_activity_at = now()
  where id = v_lobby_id and phase = 'set_summary';
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_start_next_set(text) TO anon, authenticated;

-- ------------------------------------------------------------
-- Voting auswerten
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a text; v_b text; v_filter text[]; v_played text[]; v_starters uuid[];
  v_cnt int[] := array[0, 0, 0];
  v_best int; v_tied int[] := '{}'; v_fresh int[] := '{}';
  v_pick int; v_selected text; v_choices int[]; v_starter uuid;
  v_rest text[]; i int; v_n int;
begin
  select topic_a, topic_b, topic_filter, series_topics, series_starters
    into v_a, v_b, v_filter, v_played, v_starters
  from public.lobbies where id = p_lobby_id and phase = 'topic_vote' for update;
  if not found then return; end if;

  if v_a is null then v_a := 'Thema A'; end if;
  if v_b is null then v_b := 'Thema B'; end if;

  for i in 1..3 loop
    select count(*) into v_n from public.topic_votes where lobby_id = p_lobby_id and choice = i;
    v_cnt[i] := v_n;
  end loop;

  v_best := greatest(v_cnt[1], v_cnt[2], v_cnt[3]);
  for i in 1..3 loop
    if v_cnt[i] = v_best then v_tied := array_append(v_tied, i); end if;
  end loop;

  -- Zufalls-Karte: Themen außerhalb der beiden Karten (gibt es keine, bleibt A/B)
  v_rest := array(select x from unnest(public._vote_topic_pool(v_filter)) x where x <> v_a and x <> v_b);

  if array_length(v_tied, 1) = 1 then
    v_pick := v_tied[1];
    v_choices := null;
  else
    -- Gleichstand: bevorzugt Optionen mit noch nicht gespieltem Thema
    foreach i in array v_tied loop
      if (i = 1 and not (v_a = any(v_played)))
         or (i = 2 and not (v_b = any(v_played)))
         or (i = 3 and (array_length(v_rest, 1) is null or exists (select 1 from unnest(v_rest) r where not (r = any(v_played)))))
      then v_fresh := array_append(v_fresh, i); end if;
    end loop;
    if array_length(v_fresh, 1) is null then v_fresh := v_tied; end if;
    v_pick := v_fresh[1 + floor(random() * array_length(v_fresh, 1))::int];
    v_choices := v_tied;
  end if;

  if v_pick = 1 then v_selected := v_a;
  elsif v_pick = 2 then v_selected := v_b;
  else
    v_selected := public._weighted_topic(v_rest, v_played);
    if v_selected is null then
      v_selected := public._weighted_topic(array[v_a, v_b], v_played);
    end if;
  end if;

  -- Startspieler: wer in diesem Match schon öfter gestartet hat, wird seltener gezogen
  select p.player_id into v_starter
  from public.players p
  where p.lobby_id = p_lobby_id and p.status = 'active' and p.is_alive = true
  order by -ln(greatest(random(), 1e-12)) * (1 + (select count(*) from unnest(v_starters) s where s = p.player_id))
  limit 1;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      series_topics = array_append(series_topics, v_selected),
      series_starters = case when v_starter is null then series_starters else array_append(series_starters, v_starter) end,
      countdown_starter_player_id = v_starter,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

COMMIT;

-- >>> 067_playlists_variety.sql <<<
-- ============================================================
-- Migration 067: 3 neue Playlists (80er Hits, Deutsch-Pop, Rock-Klassiker)
-- + Deutschrap-Songs auf 30+ Titel aufgefüllt
-- ============================================================
-- Auswahl: nur allgemein bekannte Hits (Ziel: mind. 85 % kennen sie),
-- keine Überschneidung zwischen den Playlists (Titel einzigartig, auch
-- gegen die bestehenden 3 Playlists geprüft). Jeder Song wurde per
-- iTunes-Suche verifiziert (Titel + Interpret passen, Preview vorhanden)
-- -- generiert mit db/scripts/build-playlists.mjs.
-- ============================================================
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT '80er Hits', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = '80er Hits');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('80er Hits', 'Billie Jean', 'Michael Jackson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a0/20/1b/a0201bf3-e6a7-f2fc-a836-a536593c3e51/mzaf_3717140176449046337.plus.aac.p.m4a'),
    ('80er Hits', 'Girls Just Want to Have Fun', 'Cyndi Lauper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/17/cf/6a17cffc-3d8f-96cf-9796-3b1894c87081/mzaf_4651252225789153600.plus.aac.p.m4a'),
    ('80er Hits', 'Sweet Dreams (Are Made of This)', 'Eurythmics', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/86/e3/8a/86e38af3-8863-973c-1c55-9f8187125741/mzaf_11175782400808341439.plus.aac.p.m4a'),
    ('80er Hits', 'Don''t You (Forget About Me)', 'Simple Minds', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/38/f0/d238f015-847a-6a10-09e4-9f00391a59bb/mzaf_6669203872576217423.plus.aac.p.m4a'),
    ('80er Hits', 'Africa', 'Toto', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/bb/3d/07/bb3d07a3-b3af-2c99-5c9f-eb72796268c2/mzaf_11871467005041854011.plus.aac.p.m4a'),
    ('80er Hits', 'Like a Virgin', 'Madonna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/53/7c/ee/537ceef4-ef8b-f822-2863-e754a404cd0b/mzaf_10337818103101697835.plus.aac.p.m4a'),
    ('80er Hits', 'Material Girl', 'Madonna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f9/a3/69/f9a369cc-16a4-3064-2c12-56ecf13f18bc/mzaf_2371968126843790037.plus.aac.p.m4a'),
    ('80er Hits', 'Every Breath You Take', 'The Police', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/33/55/ce/3355ceb6-679b-dede-bc9e-20240c173541/mzaf_2582695436913795899.plus.aac.p.m4a'),
    ('80er Hits', 'Beat It', 'Michael Jackson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3a/5d/68/3a5d6822-c66d-a66d-9ff4-b5c202ccb1e6/mzaf_2361657803900731663.plus.aac.p.m4a'),
    ('80er Hits', 'Thriller', 'Michael Jackson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f0/f5/e3/f0f5e387-ff78-101a-6397-aa3983d47031/mzaf_17965432547060573077.plus.aac.p.m4a'),
    ('80er Hits', 'Wake Me Up Before You Go-Go', 'Wham!', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/35/99/9e/35999e3f-480b-158a-2149-fa8ff249f882/mzaf_10746700119453640305.plus.aac.p.m4a'),
    ('80er Hits', 'Last Christmas', 'Wham!', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e6/77/57/e67757c8-e967-b6c1-87cc-1e0575693d2b/mzaf_6900971918188256614.plus.aac.p.m4a'),
    ('80er Hits', 'Careless Whisper', 'George Michael', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/21/89/59/21895916-e570-019b-1dce-fd19a9e4d6b8/mzaf_253631016813185496.plus.aac.p.m4a'),
    ('80er Hits', 'Karma Chameleon', 'Culture Club', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7c/de/e5/7cdee5ce-a379-9f68-0602-8cf8c57311ac/mzaf_10937102495873020253.plus.aac.p.m4a'),
    ('80er Hits', 'Tainted Love', 'Soft Cell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/05/7a/d8/057ad825-8f51-30ab-f830-e12a31ceeb5c/mzaf_15503561629945838399.plus.aac.p.m4a'),
    ('80er Hits', 'Don''t Stop Believin''', 'Journey', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b3/9f/9a/b39f9aff-5420-1499-ad96-4279228fdca4/mzaf_106745718629962303.plus.aac.p.m4a'),
    ('80er Hits', 'Livin'' on a Prayer', 'Bon Jovi', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/75/15/30/75153020-b7c4-7958-8907-4aa1b965dc24/mzaf_2377504467597068152.plus.aac.p.m4a'),
    ('80er Hits', 'Eye of the Tiger', 'Survivor', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d8/8a/b1/d88ab192-8608-562d-7442-d4cd76d7fefe/mzaf_1482115361099733526.plus.aac.p.m4a'),
    ('80er Hits', 'The Final Countdown', 'Europe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d3/5b/d9/d35bd9a3-d105-95d8-ba29-0f5c6b8e764b/mzaf_7609183394807520180.plus.aac.p.m4a'),
    ('80er Hits', 'Never Gonna Give You Up', 'Rick Astley', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f5/2a/b8/f52ab85e-059c-e466-65f9-a6a2e7a568e7/mzaf_9448240738290206647.plus.aac.p.m4a'),
    ('80er Hits', 'Holding Out for a Hero', 'Bonnie Tyler', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/af/64/9c/af649c31-3655-14e6-7fe5-216a6f78ff67/mzaf_15929190961841576220.plus.aac.p.m4a'),
    ('80er Hits', 'Total Eclipse of the Heart', 'Bonnie Tyler', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/47/3d/35/473d35b3-b379-12d9-8fbf-88299e3cad7e/mzaf_5191559564499798673.plus.aac.p.m4a'),
    ('80er Hits', 'Walking on Sunshine', 'Katrina & The Waves', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a8/ac/35/a8ac356e-a64d-ac5d-16eb-ff62d8105e08/mzaf_6193506445269557291.plus.aac.p.m4a'),
    ('80er Hits', 'Time After Time', 'Cyndi Lauper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/00/b4/ec00b43c-2e21-c931-e452-cacd682f2251/mzaf_16975899866446384890.plus.aac.p.m4a'),
    ('80er Hits', 'I Wanna Dance with Somebody (Who Loves Me)', 'Whitney Houston', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/91/6e/5e/916e5ed8-e73d-3eaa-530e-2b29eba8dbdf/mzaf_12685718320321072710.plus.aac.p.m4a'),
    ('80er Hits', 'Come On Eileen', 'Dexys Midnight Runners', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/99/3f/2f/993f2f79-eff6-8bb6-5620-89297ab82bf9/mzaf_8325234611055133997.plus.aac.p.m4a'),
    ('80er Hits', 'Jump', 'Van Halen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/89/fa/f1/89faf128-b7de-808a-6893-4fc730dcfbe4/mzaf_10903024022773138434.plus.aac.p.m4a'),
    ('80er Hits', 'Footloose', 'Kenny Loggins', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/22/18/68/2218688a-ff36-7277-56de-c6b221d691c8/mzaf_12250270063124855744.plus.aac.p.m4a'),
    ('80er Hits', 'Flashdance... What a Feeling', 'Irene Cara', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ee/f0/fd/eef0fda5-3a77-ba9a-41e1-31e0fe603faa/mzaf_4287430643698303778.plus.aac.p.m4a'),
    ('80er Hits', 'Purple Rain', 'Prince', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/76/17/ba/7617bae9-013f-3e37-cd89-41998f6ed902/mzaf_15080256781020707908.plus.aac.p.m4a'),
    ('80er Hits', 'When Doves Cry', 'Prince', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f0/51/fc/f051fcce-eb4f-f9d5-d7ea-eb137750d9a8/mzaf_15769385331104997195.plus.aac.p.m4a'),
    ('80er Hits', 'Let''s Dance', 'David Bowie', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ea/e1/be/eae1be9d-611b-f67d-864f-1dc8df04726b/mzaf_8018381438157593013.plus.aac.p.m4a'),
    ('80er Hits', 'Down Under', 'Men At Work', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/76/1c/6e/761c6e1d-1b95-e87f-bcec-41afc0836a9a/mzaf_11800999298773408397.plus.aac.p.m4a'),
    ('80er Hits', 'Voyage, Voyage', 'Desireless', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c7/24/06/c7240641-7035-44a8-f2d0-e2ee8f197e2b/mzaf_2041993949195620983.plus.aac.p.m4a'),
    ('80er Hits', '99 Luftballons', 'Nena', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0c/24/c9/0c24c947-6410-77a3-057c-0987d613ad36/mzaf_66170433704112999.plus.aac.p.m4a'),
    ('80er Hits', 'Major Tom (Völlig losgelöst)', 'Peter Schilling', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8d/a2/4a/8da24a3b-1d84-2d5f-3305-14d24c781c33/mzaf_13902943445669410809.plus.aac.p.m4a'),
    ('80er Hits', 'Der Kommissar', 'Falco', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/65/d1/f4/65d1f495-beef-e4b4-17d3-28bca761560f/mzaf_4630646480375616791.plus.aac.p.m4a'),
    ('80er Hits', 'Rock Me Amadeus', 'Falco', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/17/a5/26/17a526da-8141-7266-98fc-7f8b21cad289/mzaf_12457553091099431726.plus.aac.p.m4a'),
    ('80er Hits', 'Blue Monday', 'New Order', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0f/43/1c/0f431c1a-119c-6614-2736-3fbc4c8a597c/mzaf_3646998447648845325.plus.aac.p.m4a'),
    ('80er Hits', 'Kids in America', 'Kim Wilde', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3f/6e/cf/3f6ecf1a-8038-0313-36a3-5b2949142155/mzaf_932783320149738969.plus.aac.p.m4a'),
    ('80er Hits', 'Relax', 'Frankie Goes To Hollywood', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6d/b6/48/6db648ab-8b25-648a-420a-15fd086f0947/mzaf_17017095599203750844.plus.aac.p.m4a'),
    ('80er Hits', 'The NeverEnding Story', 'Limahl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9e/41/2f/9e412f86-f086-bcda-4caf-9aec0da5db73/mzaf_3281567823547002322.plus.aac.p.m4a'),
    ('80er Hits', 'Gloria', 'Laura Branigan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b4/78/be/b478be15-8a37-8cd3-1ec7-a761149fcb21/mzaf_7508608839338770010.plus.aac.p.m4a'),
    ('80er Hits', 'Hungry Like the Wolf', 'Duran Duran', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/3d/89/37/3d8937c0-0af8-8e56-7a05-84eb313bebf1/mzaf_6649517434617225776.plus.aac.p.m4a'),
    ('80er Hits', 'Girls on Film', 'Duran Duran', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b1/73/59/b1735946-02e4-5676-dd28-d3566442141a/mzaf_10211230340607294220.plus.aac.p.m4a'),
    ('80er Hits', 'Dancing in the Dark', 'Bruce Springsteen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ec/c9/91/ecc99192-1c69-6aa0-5b80-35e5545528cb/mzaf_18148738310915598129.plus.aac.p.m4a'),
    ('80er Hits', 'Pump Up the Jam', 'Technotronic', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cd/24/04/cd2404d8-ec33-2d0b-6426-9f4037ddfe1c/mzaf_1717233101104902284.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutsch-Pop', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutsch-Pop');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Deutsch-Pop', 'Atemlos durch die Nacht', 'Helene Fischer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/de/96/b0/de96b0e2-457f-80ab-8deb-483074b3f964/mzaf_13820032290883879872.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Auf uns', 'Andreas Bourani', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/3c/61/ad3c61a1-f240-4a25-a33e-57bc71e5add9/mzaf_16275168154031441733.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Das Beste', 'Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b1/24/c7/b124c7ef-837d-cfb1-6cd9-afb61ea03a17/mzaf_691353218883590972.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Haus am See', 'Peter Fox', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dd/73/c8/dd73c864-bd13-5c3c-c684-bc45e7e1b658/mzaf_11804343455496657686.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Alles neu', 'Peter Fox', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/25/3e/0b/253e0bd2-403f-2d77-772b-d57293284597/mzaf_9531020977280373361.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Schwarz zu Blau', 'Peter Fox', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/ca/d1/da/cad1da45-b88b-22f3-9830-17afdde093b3/mzaf_10692662865583289845.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Nur ein Wort', 'Wir sind Helden', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/be/16/18/be16185a-8729-64fb-97a0-5e5eb03c7ca5/mzaf_8894170273939000752.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Denkmal', 'Wir sind Helden', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/69/e4/92/69e492ad-1ca1-f103-140e-8b3afaf9f028/mzaf_15095749718268062153.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Vom selben Stern', 'Ich + Ich', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/27/dc/f5/27dcf5c3-a235-5681-3337-940688185468/mzaf_1006676206739409196.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Geile Zeit', 'Juli', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/13/5d/58/135d587c-207d-1578-6adb-b6830ed0b1b8/mzaf_324307169502288637.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Perfekte Welle', 'Juli', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/22/10/6e/22106eb5-b184-4a39-dadc-86955685361c/mzaf_14611313335791529378.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Wie schön du bist', 'Sarah Connor', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/62/d8/12/62d8124c-6c57-7f17-1209-e3b9f2b8d8c0/mzaf_16701527472761760534.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Au revoir', 'Mark Forster, Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/78/3f/5a/783f5a09-e406-d843-ffa3-3b0f30cd3150/mzaf_12336214171557554920.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Chöre', 'Mark Forster', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/71/f8/59/71f8595f-cf30-44e8-8bf3-021e4fbde75e/mzaf_15526366958179967486.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Flash mich', 'Mark Forster', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/01/0e/b4/010eb4bb-9148-3a30-c64a-ebb7a32ad5d0/mzaf_4659479273206319668.plus.aac.p.m4a'),
    ('Deutsch-Pop', '80 Millionen', 'Max Giesinger', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8c/a3/db/8ca3dbab-22e9-040c-b1d0-6fb0d5c8b4a7/mzaf_10388389663581688460.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Wenn sie tanzt', 'Max Giesinger', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/66/1d/c9/661dc92e-f473-2874-221b-ccd71b0a8de5/mzaf_5638113420182681751.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Tage wie diese', 'Die Toten Hosen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ca/86/95/ca869587-b0c5-c3f5-5200-21c0c682660b/mzaf_6658429541659026420.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Männer', 'Herbert Grönemeyer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/97/72/a5977274-6982-bb64-79db-43578f974163/mzaf_3541195977681608889.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Mensch', 'Herbert Grönemeyer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3c/9a/20/3c9a203a-63e8-89a1-5870-355a06bfb4dd/mzaf_1128187272067325576.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Bochum', 'Herbert Grönemeyer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a5/22/77/a52277b9-bc63-2352-09af-22694ec4c168/mzaf_15078942190330159748.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Irgendwas bleibt', 'Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/dd/d3/f9/ddd3f9cb-5639-9069-ff7a-f124e7d22cab/mzaf_17833433783132470617.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Symphonie', 'Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d9/59/ad/d959ad82-33be-bd57-dd0f-f28813c7fefc/mzaf_8011789993432230967.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Du hast', 'Rammstein', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/75/08/5a7508ee-f167-37aa-3b1a-7c63db8cb450/mzaf_11938743806268466326.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Schrei nach Liebe', 'Die Ärzte', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e5/3f/4d/e53f4dbb-c45a-4669-8c8d-36cd641e550a/mzaf_5250262973873347333.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Junge', 'Die Ärzte', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/b7/55/5c/b7555c03-0a1c-f676-71ed-b5531047b33b/mzaf_3937501780846588412.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Dieser Weg', 'Xavier Naidoo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ec/09/54/ec095427-a499-1f51-75a9-d8db3491464e/mzaf_5239449848784989632.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Was wir alleine nicht schaffen', 'Xavier Naidoo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dc/a5/56/dca55673-ad29-8e21-119f-96e22a8daa71/mzaf_10981131678521095176.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Nur noch kurz die Welt retten', 'Tim Bendzko', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9c/eb/d3/9cebd391-04ba-47f5-15dc-dbddc17db196/mzaf_2464837171895883732.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Wie soll ein Mensch das ertragen', 'Philipp Poisel', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c7/03/62/c7036244-dd57-9e00-d554-6f929cc1a495/mzaf_15557778499790392309.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Die immer lacht', 'Kerstin Ott', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a9/6e/a2/a96ea2ea-3785-72ed-26d5-86d8872adf5c/mzaf_13081333979695466971.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Halt dich an mir fest', 'Revolverheld', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b3/3f/7a/b33f7a0b-43e9-6d6c-fc46-cde65311cc4a/mzaf_9122751001031449853.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Lass uns gehen', 'Revolverheld', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a0/df/7f/a0df7f8e-1260-41d4-6020-a50a68565e9d/mzaf_16393009569438452120.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Verdammt, ich lieb'' dich', 'Matthias Reim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/30/1f/7d/301f7d60-4916-21cd-dbe2-6dd11f9daece/mzaf_12171051327600935346.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Remmidemmi (Yippie Yippie Yeah)', 'Deichkind', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/09/0c/f8/090cf8f9-b476-a65a-bbc6-410b3ea4eb40/mzaf_3066246424451358538.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Ohne Dich', 'Münchener Freiheit', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8f/14/d7/8f14d7bf-2f7c-ebdb-7b88-d3a7a8db98d0/mzaf_13097502796743649801.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Sonne', 'Rammstein', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5a/74/79/5a7479f4-54f7-62e8-6500-51fd2bc41a1f/mzaf_5614602769858578012.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Millionär', 'Die Prinzen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f5/ba/b3/f5bab310-4b4a-90e7-9709-01aa6d029d40/mzaf_9938191721252823859.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Mein Herz brennt', 'Rammstein', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/07/c4/37/07c437fb-1181-c34f-c12d-1d5bf620f530/mzaf_13566694454359017291.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Ich will Spaß', 'Markus', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/95/53/9d/95539d27-f94f-60d5-5f94-23c4cf9d3091/mzaf_7976054926271081178.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Ich war noch niemals in New York', 'Udo Jürgens', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e2/c4/5b/e2c45bd5-c0bf-2315-32b3-bc49c4d21b56/mzaf_10457787525492184810.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Rock-Klassiker', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Rock-Klassiker');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Rock-Klassiker', 'Bohemian Rhapsody', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cd/9f/c5/cd9fc5f8-4979-d79e-abf4-883e54f717d1/mzaf_15408639854395137008.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'We Will Rock You', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0a/a9/f3/0aa9f3af-4672-fb3b-42d8-6d56a9a4c69b/mzaf_16030082968131796908.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Don''t Stop Me Now', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f1/33/52/f1335205-3f9c-d385-4ad1-05e1fdbb4b25/mzaf_12271468743380438228.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Another One Bites the Dust', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cf/06/67/cf066706-f868-e26b-c8b9-552f51b258f6/mzaf_8129975054693207838.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Stairway to Heaven', 'Led Zeppelin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fc/3e/cf/fc3ecfde-a878-2d65-5929-cf325bcc234a/mzaf_17376241315973674081.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Whole Lotta Love', 'Led Zeppelin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8a/15/37/8a1537e5-9d18-7e44-4ca8-3295942263b6/mzaf_2401048427177636441.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Hotel California', 'Eagles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a9/be/ba/a9bebaab-3eb5-d185-a5af-c75d122ba892/mzaf_15660694999198133668.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Smoke on the Water', 'Deep Purple', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/08/3f/1b/083f1b23-decd-8fe6-2bad-0437d1c5d959/mzaf_9991776491763640927.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Sweet Child O'' Mine', 'Guns N'' Roses', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/82/2d/a5822d67-2e65-fe95-511e-1f785d23e5cc/mzaf_8619467974951398014.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Paradise City', 'Guns N'' Roses', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0b/2d/ec/0b2dec08-f03d-8a96-93a8-386a7d7b5091/mzaf_12821402190646617663.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Welcome to the Jungle', 'Guns N'' Roses', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1f/70/d6/1f70d6e8-edab-5ea1-4c3b-e51744cc79c7/mzaf_2766266430694093633.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Nothing Else Matters', 'Metallica', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9b/a1/37/9ba137ed-330d-09e6-7449-e0557dfbe85d/mzaf_14863385354373294620.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Enter Sandman', 'Metallica', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f9/5b/8d/f95b8d0b-6526-b5a3-b565-e9e07f9ce929/mzaf_1100904155230105156.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Smells Like Teen Spirit', 'Nirvana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b0/36/9c/b0369c24-5047-1f93-a228-64ecec779cdc/mzaf_17479720470163953122.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Come as You Are', 'Nirvana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/f1/9e/6af19e76-a475-2837-db0a-60d29f74ace6/mzaf_9899031328948492518.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Wonderwall', 'Oasis', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ea/e6/de/eae6de59-5000-da21-c882-f52fc2492428/mzaf_12629158787072767220.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Don''t Look Back in Anger', 'Oasis', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/58/62/66/58626600-2593-05b5-9b47-6eacc65ea8d2/mzaf_11697044045943414259.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Creep', 'Radiohead', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1f/18/e2/1f18e22b-264e-88f8-ee89-c196fa9abd7a/mzaf_14184372154331980897.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Under the Bridge', 'Red Hot Chili Peppers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9b/5b/76/9b5b76af-214c-82c9-2dae-5971e3bb25ba/mzaf_12325461313798845398.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Californication', 'Red Hot Chili Peppers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/cb/4a/fc/cb4afcc4-021b-664d-ddb0-3c6fe969b519/mzaf_2631134696080272573.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Basket Case', 'Green Day', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d2/5b/2a/d25b2a88-232a-f454-9df2-670b8115a0e8/mzaf_1677607799407141057.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Seven Nation Army', 'The White Stripes', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7f/28/22/7f282276-e463-79c2-b770-40c762df0c48/mzaf_3138918352191055941.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Mr. Brightside', 'The Killers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5b/17/4e/5b174e80-1047-7214-1077-d822ba1f9520/mzaf_5975692497663881329.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Zombie', 'The Cranberries', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/35/bb/65/35bb6532-1abe-59e4-9ced-8bee2742ea24/mzaf_15102830936602294569.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Sweet Home Alabama', 'Lynyrd Skynyrd', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/83/05/df830577-1f01-5cd8-0121-be1d211e0fb6/mzaf_6134975832316471112.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Paint It Black', 'The Rolling Stones', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/da/f5/ec/daf5ece2-6853-c6a4-d481-389001453f75/mzaf_3869995397273029315.plus.aac.p.m4a'),
    ('Rock-Klassiker', '(I Can''t Get No) Satisfaction', 'The Rolling Stones', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ee/4d/28/ee4d28cd-a465-1334-2863-efda9ea9669b/mzaf_8440807812349084607.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Born to Be Wild', 'Steppenwolf', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/71/33/6d/71336d1f-e008-d0f8-5dff-25fa0974ef8d/mzaf_13245098132834526016.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Let It Be', 'The Beatles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6d/17/53/6d1753e6-debc-115a-0fd2-11a705795b74/mzaf_10149167119683527545.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'In the End', 'Linkin Park', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0c/ad/c0/0cadc05e-846a-b090-c7e9-6017df2e0ab5/mzaf_1775739195432502696.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Numb', 'Linkin Park', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/93/dc/45/93dc455c-483f-8931-ef2e-cec30e2ed4bb/mzaf_3013383482601094146.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Bring Me to Life', 'Evanescence', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dd/fe/35/ddfe35a4-491e-cf31-658c-d0a146402b29/mzaf_1325478918326867414.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Chop Suey!', 'System Of A Down', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2c/5e/b8/2c5eb8e9-93d3-b530-d7fd-63774ae21066/mzaf_7290820158982694185.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Iron Man', 'Black Sabbath', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/77/ca/ae/77caae8f-3f9d-db83-a453-b9d2d46c7118/mzaf_17772168214401601614.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Paranoid', 'Black Sabbath', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview124/v4/db/4a/48/db4a48f4-01a3-ab8e-f0ff-b2cff713142f/mzaf_1687608787420965868.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Do I Wanna Know?', 'Arctic Monkeys', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/89/ae/42/89ae4206-048a-7eae-3eaf-c3abd02914fb/mzaf_15551176804491638370.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Use Somebody', 'Kings of Leon', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/23/1d/b3/231db3c5-a99c-3fba-5d3b-f6e9cdbeb841/mzaf_12581310710694950303.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Sex on Fire', 'Kings of Leon', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9f/e7/52/9fe75225-7a58-47d3-d570-22ae95bb160d/mzaf_1409968636503833590.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Knockin'' on Heaven''s Door', 'Bob Dylan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/04/65/74/046574c1-e3d3-d94e-6c06-0fc5b283a688/mzaf_4165602350498591047.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Hey Jude', 'The Beatles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/31/47/fe/3147fe89-fb45-bc4a-4c16-dcc82e205aa6/mzaf_11654990763388730424.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Light My Fire', 'The Doors', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e2/2e/99/e22e9993-9f0c-df04-4aec-133a7045bce5/mzaf_14103368404409074100.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Back in the U.S.S.R.', 'The Beatles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/14/8d/37/148d379a-2070-8f0a-a542-1a9d57caa91e/mzaf_17277814682471409823.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Rock You Like a Hurricane', 'Scorpions', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/36/46/fd/3646fd1f-4f9b-2395-2c83-89624fa1447f/mzaf_3391925793740712006.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap-Songs', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap-Songs');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Deutschrap-Songs', 'Easy', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/72/e5/9b/72e59b85-ee9e-9b0e-746d-bc35aee1b0b5/mzaf_7893096664339783467.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Traum', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b0/21/e1/b021e142-6926-8dbe-2619-3ff999a5c770/mzaf_4428899675628945601.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Erfolg ist kein Glück', 'Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/29/cc/94/29cc94f7-f243-2f23-4f26-ccfe243bbd7c/mzaf_5704929239630484468.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'NDW 2005', 'Fler', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/93/13/d1/9313d1a3-3c5e-354a-c02e-315fed91473f/mzaf_8694059876417981331.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Mein Block', 'Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/02/dc/9b/02dc9bc1-cce4-8e7f-b6d8-65c55b6b2086/mzaf_468114569001241405.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Für immer jung', 'Bushido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/c4/6c/32/c46c329f-62ce-0a6c-4a32-bddcf5d41e1c/mzaf_8034649478957838891.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Palmen aus Plastik', 'Bonez MC, RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1e/c4/e1/1ec4e1eb-fe4d-37be-0f0b-3b3776d3e25b/mzaf_8167689886240399456.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Vermissen', 'Juju', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/db/a6/d6/dba6d667-f699-7b95-3109-e949d5e1c089/mzaf_5952168470338838373.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Lila Wolken', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a1/47/4b/a1474b0b-2b24-f330-4345-7fbe8212dba7/mzaf_10836573937865411354.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Hinterland', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/19/4e/f4/194ef4e4-7d3e-5c08-5380-54d487285db5/mzaf_7755148851616662122.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Willst du', 'Alligatoah', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/bf/12/90/bf1290a6-9d84-a854-0015-a17372df44ae/mzaf_14479433487154095514.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Bad Chick', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/50/c5/52/50c55257-c07f-b827-9493-884aaaf0c318/mzaf_17421216701355027386.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Jein', 'Fettes Brot', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8a/a3/7a/8aa37a84-36e8-8dcd-0b5c-e2532d8b2cf2/mzaf_3867408908518139439.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'MfG', 'Die Fantastischen Vier', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b7/c2/56/b7c256bd-c38e-2432-5e97-5d412ca36b7a/mzaf_1354000171391241042.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Kids (2 Finger an den Kopf)', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6b/da/c7/6bdac7aa-ae8d-b89e-d9cf-b066e88996f3/mzaf_3303354876056285465.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Augen auf', 'Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/c9/9c/cf/c99ccfc1-9bcf-fa2d-eb63-8b6c30487d17/mzaf_11743602834165678944.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

COMMIT;

-- >>> 068_shisha_topup.sql <<<
-- Migration 068: Shisha Club auf 30 Titel aufgefüllt (iTunes-verifiziert)
-- Generiert von db/scripts/build-playlists.mjs (iTunes-verifiziert: Titel+Interpret+Preview)
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Shisha Club', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Shisha Club');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Shisha Club', 'Cherry Lady', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/58/59/26/5859264e-97ce-0eee-7ee2-0fc252394323/mzaf_6696924934051821960.plus.aac.p.m4a'),
    ('Shisha Club', 'Airwaves', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/51/41/f2/5141f286-b3bd-3318-89cf-a6ccb98cccb4/mzaf_7876580721373569987.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

COMMIT;

-- >>> 069_remove_wrong_previews.sql <<<
-- Migration 069: falsche Song-Previews entfernt + Playlists aufgefüllt
-- Audit (db/scripts/audit-previews.mjs): bei 16 alten Songs (Deutschrap-Songs, Shisha Club)
-- spielte die Preview einen ANDEREN Titel. Entfernt; beide Playlists mit iTunes-verifizierten,
-- bekannten Titeln wieder auf >= 30 aufgefüllt.
BEGIN;
DELETE FROM public.song_pool WHERE id IN ('1515b6ea-6263-4f3a-bedb-64a55ae169c8','75ed00ee-a115-4281-9cb2-d38e75067259','9c40fb11-d0b2-4b25-8ed0-ea2179c51feb','d359bfac-6064-47fa-abc7-59ba96392e1a','789ce9c7-3ed3-482d-a691-742f402171c7','ef1c4a52-d0c7-4117-81f7-d0f8b3ae6982','32d1822f-d5a9-4b74-a18f-b6ebb1b976a0','23035edd-146e-4e99-ab2d-78d7d27a6f9a','251411b7-753f-4887-ae07-53faa5642ea6','7957f0bf-3b58-4404-a9b8-e3535d420b72','5c1ae52d-8dce-4c01-8f18-d2ad524e3600','2c75d371-5c0d-471e-9afc-b9451f3a5384','1decddaa-7480-4790-9f7a-acc711c6ed62','1454d246-6bff-4132-a0b7-3a188e5b4b07','17b395b0-89b9-4767-8759-b13c331bf3de','9df1a008-253e-404c-bbd4-7e674f9eb742','ae8d9b5f-a491-4e78-a04b-c1a5c43e55b8');

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap-Songs', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap-Songs');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Deutschrap-Songs', 'Hi Kids', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/97/66/25/976625d2-e1ee-91a3-00e2-caf8a930f0a5/mzaf_15887768229262030255.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Einmal um die Welt', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/12/c6/70/12c6701a-294e-50d1-a490-d2a3bd91ffa9/mzaf_15225202634199766013.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Bye Bye', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/07/19/d6/0719d63e-7b50-10aa-dbda-ffebac3f9b57/mzaf_11760575587449635273.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Melodie', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5b/1a/4f/5b1a4f4f-b861-b104-f816-deab8cb8c1da/mzaf_7631167956273878838.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Neymar', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a7/69/de/a769de2c-18d6-064c-04e2-e82d96ea9225/mzaf_5362429075520904707.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Bläulich', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f2/27/a6/f227a6ef-b6f2-de0b-8060-e0e5a29ba4fa/mzaf_7106802513914058652.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Electro Ghetto', 'Bushido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d7/9f/08/d79f0869-01a5-1db5-d414-8381ce4045ee/mzaf_17757541506833908075.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Welt der Wunder', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3f/93/01/3f93014d-a17c-f4a0-046d-cd6802b0187b/mzaf_16721263306747837763.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'XOXO', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/88/b2/ec88b2bb-9b5a-a723-4591-1d4841837ae5/mzaf_10971516685321414190.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Im Ascheregen', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/bc/06/09/bc060979-868b-0cb8-d605-9e298808693f/mzaf_7632267496433031349.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Shisha Club', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Shisha Club');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Shisha Club', 'Kein Plan', 'Loredana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/94/ce/5b/94ce5be4-d487-19ba-b376-a60d38954fd0/mzaf_17595214646994012332.plus.aac.p.m4a'),
    ('Shisha Club', 'Papaoutai', 'Stromae', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f5/74/17/f5741739-6e4a-22d1-7d1c-fb1d83cd48fa/mzaf_7090140597883469797.plus.aac.p.m4a'),
    ('Shisha Club', 'Alors on danse', 'Stromae', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/87/84/ae/8784ae2b-8e39-0053-23ad-940bf2f69d87/mzaf_16356168226426243495.plus.aac.p.m4a'),
    ('Shisha Club', 'Djadja', 'Aya Nakamura', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ff/c1/fa/ffc1faa2-506d-4c5b-3e09-b7067959adf3/mzaf_3563312867774255295.plus.aac.p.m4a'),
    ('Shisha Club', 'Dernière Danse', 'Indila', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/c0/a7/c6c0a7a9-8e64-11d2-1146-5103b1c07004/mzaf_12112688470040263229.plus.aac.p.m4a'),
    ('Shisha Club', 'Despacito', 'Luis Fonsi', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/46/42/db/4642db8f-13f6-457d-bd3e-1d9c22654ace/mzaf_16062777735482664257.plus.aac.p.m4a'),
    ('Shisha Club', 'Mi Gente', 'J Balvin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/71/1f/14/711f149d-9843-7d00-0092-eac653a1e014/mzaf_2844927362482586540.plus.aac.p.m4a'),
    ('Shisha Club', 'Danza Kuduro', 'Don Omar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/08/40/df/0840df61-1e6d-c985-1136-500dd9e09cc5/mzaf_13424326045030692319.plus.aac.p.m4a'),
    ('Shisha Club', 'Gasolina', 'Daddy Yankee', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/80/a6/9f/80a69fdc-b334-a648-6efc-6f57a60782c0/mzaf_18210801488139650311.plus.aac.p.m4a'),
    ('Shisha Club', 'Bailando', 'Enrique Iglesias', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a7/6d/a1/a76da115-ae3f-2d54-0f90-cfd006d8db4e/mzaf_18397821616695221456.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

COMMIT;


-- >>> 070_bot_skill.sql <<<
-- ============================================================
-- Migration 070: Bots mit unterschiedlicher Stärke
-- ============================================================
-- players.bot_skill: 1 = Anfänger, 2 = Mittel, 3 = Profi (NULL bei Menschen).
-- Unterschiede (serverseitig in _bot_tick):
--   * Reaktionszeit:      Anfänger 2.4-5.4 s | Mittel 1.2-3.8 s | Profi 0.8-2.0 s
--   * Trefferquote/Runde: Anfänger = 70 % der Basis | Mittel = Basis | Profi bleibt hoch
--   * Interpret statt Titel (halbe Punkte, weniger Bonuszeit):
--                         Anfänger 45 % | Mittel 15 % | Profi 0 %
-- rpc_add_bot nimmt optional die Stärke; ohne Angabe wird gemischt gelost
-- (30 % Anfänger, 45 % Mittel, 25 % Profi).
-- ============================================================

BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS bot_skill smallint;
ALTER TABLE public.players DROP CONSTRAINT IF EXISTS players_bot_skill_check;
ALTER TABLE public.players ADD CONSTRAINT players_bot_skill_check CHECK (bot_skill IS NULL OR bot_skill BETWEEN 1 AND 3);
-- Spalten-Allowlist (nie Tabellen-GRANT -- session_token!)
GRANT SELECT (bot_skill) ON public.players TO anon, authenticated;

-- Bots, die schon existieren: mittel
UPDATE public.players SET bot_skill = 2 WHERE is_bot = true AND bot_skill IS NULL;

-- Trefferwahrscheinlichkeit pro Runde je Stärke
CREATE OR REPLACE FUNCTION public._bot_survival(p_round integer, p_skill integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case coalesce(p_skill, 2)
    when 1 then greatest(0.08, public._bot_survival(p_round) * 0.7)
    when 3 then greatest(0.5, 0.97 - (greatest(coalesce(p_round, 1), 1) - 1) * 0.11)
    else public._bot_survival(p_round)
  end;
$function$;

-- rpc_add_bot mit optionaler Stärke
DROP FUNCTION IF EXISTS public.rpc_add_bot(uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.rpc_add_bot(p_lobby_id uuid, p_me_player_id uuid, p_bot_name text, p_skill smallint DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid; v_max_players int; v_active_count int; v_next_seat int;
  v_bot_id uuid := gen_random_uuid();
  v_skill smallint := p_skill;
  v_roll numeric;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, max_players into v_host, v_max_players
  from public.lobbies where id = p_lobby_id;

  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  if v_skill is not null and v_skill not between 1 and 3 then raise exception 'invalid_skill'; end if;
  if v_skill is null then
    v_roll := random();
    v_skill := case when v_roll < 0.30 then 1 when v_roll < 0.75 then 2 else 3 end;
  end if;

  select count(*) into v_active_count from public.players where lobby_id = p_lobby_id and status = 'active';
  if v_active_count >= v_max_players then raise exception 'lobby_full'; end if;

  select coalesce(min(s.i), 0) into v_next_seat
  from generate_series(0, v_max_players - 1) as s(i)
  left join public.players p on p.lobby_id = p_lobby_id and p.seat_index = s.i and p.status = 'active'
  where p.id is null;

  insert into public.players (lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at, is_bot, ready, bot_skill)
  values (p_lobby_id, v_bot_id, left(trim(p_bot_name), 24), 'active', v_next_seat, now(), now(), true, true, v_skill);

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
  return v_bot_id;
end;
$function$;
GRANT EXECUTE ON FUNCTION public.rpc_add_bot(uuid, uuid, text, smallint) TO anon, authenticated;

-- Bot-Ticker: Halter-Teil mit Stärke
CREATE OR REPLACE FUNCTION public._bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_delay numeric;
  v_roll numeric;
  v_answer text;
  v_seed text;
  v_artist_chance numeric;
  v_base numeric; v_span numeric;
begin
  -- ---------- Themen-Voting ----------
  for r in
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % 3))
      on conflict (lobby_id, player_id) do nothing;
    end if;
  end loop;

  -- ---------- Laufende Runde: Bot ist Halter ----------
  for r in
    select l.id, l.code, l.holder_player_id, l.holder_since, l.round_number, l.current_song_id,
           l.topic_selected, l.used_answers, l.explode_at, coalesce(p.bot_skill, 2) as skill
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    -- Reaktionszeit je Stärke
    if r.skill = 1 then v_base := 2.4; v_span := 3.0;
    elsif r.skill = 3 then v_base := 0.8; v_span := 1.2;
    else v_base := 1.2; v_span := 2.6; end if;

    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := v_base + (abs(hashtext(v_seed)) % 1000) / 1000.0 * v_span;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number, r.skill) then continue; end if;

    v_artist_chance := case r.skill when 1 then 0.45 when 3 then 0 else 0.15 end;

    v_answer := null;
    if r.current_song_id is not null then
      if (abs(hashtext('a' || v_seed)) % 1000) / 1000.0 < v_artist_chance then
        select trim(split_part(artist, ',', 1)) into v_answer from public.song_pool where id = r.current_song_id;
      end if;
      if v_answer is null or length(v_answer) = 0 then
        select title into v_answer from public.song_pool where id = r.current_song_id;
      end if;
    else
      select ta.answer into v_answer
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(coalesce(r.topic_selected, ''))
        and not (ta.lower_answer = any (select lower(u) from unnest(r.used_answers) u))
      order by random() limit 1;
      v_answer := coalesce(v_answer, 'Keine Ahnung');
    end if;

    if v_answer is not null then
      begin
        perform public.rpc_attempt_pass(r.code, r.holder_player_id, v_answer);
      exception when others then
        null;
      end;
    end if;
  end loop;
end;
$function$;

COMMIT;


-- >>> 071_revoke_legacy_unsafe_rpcs.sql <<<
-- ============================================================
-- Migration 071: unsichere Alt-RPCs für Clients sperren
-- ============================================================
-- Gefunden bei der Spiel-Simulation: mehrere SECURITY-DEFINER-Funktionen waren für
-- anon/authenticated aufrufbar, OHNE die Session des Aufrufers zu prüfen. Wer eine
-- player_id kannte (die ist öffentlich lesbar), konnte damit u. a.
--   * die Kumpir für den Halter weitergeben, ohne den Song zu erraten (rpc_pass_potato),
--   * beliebige Spieler eliminieren / kicken / aus der Lobby werfen,
--   * das Spiel für den Host starten oder fremde "bereit"-Haken setzen.
-- Der Client nutzt nur die session-geprüften Varianten (rpc_attempt_pass, rpc_leave_lobby,
-- rpc_begin_topic_vote, rpc_toggle_ready, kick_player mit p_me_player_id ...). Die Alt-Funktionen
-- werden intern teils noch von anderen SECURITY-DEFINER-Funktionen genutzt (z. B. rpc_pass_potato
-- aus der Antwort-Prüfung) -- das bleibt erlaubt, nur der direkte Client-Zugriff entfällt.
-- ============================================================

DO $$
declare r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (
        (p.proname = 'rpc_pass_potato')
        or (p.proname = 'rpc_eliminate_player')
        or (p.proname = 'kick_player' and pg_get_function_identity_arguments(p.oid) = 'p_lobby_id uuid, p_target_player_id uuid')
        or (p.proname = 'leave_lobby')
        or (p.proname = 'rpc_restart_game')
        or (p.proname = 'rpc_start_game')
        or (p.proname = 'start_game')
        or (p.proname = 'set_ready')
        or (p.proname = 'rpc_ready_up')
      )
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon, authenticated', r.proname, r.args);
    raise notice 'gesperrt: %(%)', r.proname, r.args;
  end loop;
end $$;


-- >>> 072_restore_round_reset.sql <<<
-- ============================================================
-- Migration 072: Combo / Rache-Pass / Richtung pro Runde wieder zurücksetzen
-- ============================================================
-- Regression aus Migration 066: dort wurde _reset_series_on_phase neu definiert und der
-- Zweig "neues Themen-Voting = neue Runde" aus 063 ging verloren. Folge: Combo und
-- Rache-Pass (einmal pro Runde) wurden nie zurückgesetzt, eine gedrehte Richtung blieb
-- in der nächsten Runde erhalten. Hier wieder zusammengeführt.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    NEW.series_topics := '{}';
    NEW.series_starters := '{}';
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from NEW.phase then
    update public.players set combo = 0, revenge_used = false where lobby_id = NEW.id;
    NEW.pass_direction := 1;
  end if;
  return NEW;
end;
$function$;

COMMIT;


-- >>> 073_player_exit_balance_cleanup.sql <<<
-- ============================================================
-- Migration 073: Austritt ohne Spielabbruch, Bot-Balance, Song-Schwierigkeit, Aufräumen
-- ============================================================
-- Aus der Spiel-Simulation:
--  1) Wenn irgendwer die Lobby verließ, setzte ein Trigger die Lobby für ALLE auf "waiting"
--     zurück (Match + Ergebnisse weg). Neu: der Austritt wird wie eine Eliminierung behandelt,
--     das Spiel läuft weiter (siehe _on_player_exit).
--  2) Host weg -> bevorzugt der nächste MENSCH wird Host (nicht ein Bot).
--  3) Spiel endet bei <=1 Lebenden immer über _finish_round (Rundenergebnis, Saison-Punkte,
--     Mehr-Runden-Match läuft korrekt weiter).
--  4) Bot-Balance: Abstand Anfänger/Mittel/Profi verkleinert.
--  5) Song-Schwierigkeit: geglättete Trefferquote (kein "erst ab 5 Spielen"), nur Menschen
--     zählen (Bots verfälschten die Statistik); bisherige Zahlen zurückgesetzt.
--  6) Host-Kick und Austritt berücksichtigen die Weitergabe-Richtung (gemeinsame Funktion).
--  7) Tote Alt-Funktionen entfernt.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 4) Bot-Balance
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bot_survival(p_round integer, p_skill integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case coalesce(p_skill, 2)
    when 1 then greatest(0.08, public._bot_survival(p_round) * 0.85)
    when 3 then greatest(0.30, 0.92 - (greatest(coalesce(p_round, 1), 1) - 1) * 0.14)
    else public._bot_survival(p_round)
  end;
$function$;

-- ------------------------------------------------------------
-- 5) Song-Schwierigkeit
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._song_difficulty(p_plays integer, p_hits integer)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
AS $function$
  -- geglättet (Prior: 4 Pseudo-Spiele bei 50 %): wenige Daten bleiben "mittel", echte Ausreißer
  -- kippen nach wenigen Runden Richtung leicht/schwer.
  select case
    when (coalesce(p_hits, 0) + 2.0) / (coalesce(p_plays, 0) + 4.0) >= 0.6 then 1
    when (coalesce(p_hits, 0) + 2.0) / (coalesce(p_plays, 0) + 4.0) >= 0.3 then 2
    else 3
  end::smallint;
$function$;

UPDATE public.song_pool SET plays = 0, hits = 0;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
  v_plays int; v_hits int; v_holder uuid; v_holder_is_bot boolean;
begin
  select topic_selected, used_song_ids, current_song_id, holder_player_id
    into v_topic, v_used, v_current, v_holder
  from public.lobbies where id = p_lobby_id;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null, current_song_started_at = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  if v_song_id is not null then
    -- Nur Songs, die ein MENSCH vor sich hat, zählen für die Schwierigkeits-Statistik.
    select coalesce(is_bot, false) into v_holder_is_bot
    from public.players where lobby_id = p_lobby_id and player_id = v_holder;
    if coalesce(v_holder_is_bot, false) then
      select plays, hits into v_plays, v_hits from public.song_pool where id = v_song_id;
    else
      update public.song_pool set plays = plays + 1 where id = v_song_id
      returning plays, hits into v_plays, v_hits;
    end if;
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      current_song_started_at = case when v_song_id is null then null else now() end,
      current_song_difficulty = public._song_difficulty(v_plays, v_hits),
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

-- rpc_attempt_pass: Treffer nur zählen, wenn ein Mensch geantwortet hat
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_plays int; v_hits int;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
  v_diff numeric := 1;
  v_combo int := 0;
  v_combo_bonus numeric := 0;
  v_is_bot boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at, combo, coalesce(is_bot, false) into v_last_wrong, v_combo, v_is_bot
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist, plays, hits into v_song_title, v_song_artist, v_plays, v_hits
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      v_points := 0.5;
      v_known := true;
    end if;


    if not v_known then
      update public.players set last_wrong_guess_at = now(), combo = 0
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    v_quality := v_points;
    v_diff := case public._song_difficulty(v_plays, v_hits) when 1 then 0.8 when 3 then 1.3 else 1.0 end;

    if v_points = 1 then
      v_combo := coalesce(v_combo, 0) + 1;
      v_combo_bonus := case when v_combo >= 2 then least(2, 0.5 * (v_combo - 1)) else 0 end;
      if not coalesce(v_is_bot, false) then
        update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
      end if;
    else
      v_combo := 0;
    end if;

    update public.players
    set song_points = song_points + v_points, combo = v_combo
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality,
      last_pass_diff = v_diff, last_pass_combo_bonus = v_combo_bonus
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ------------------------------------------------------------
-- 1) + 6) Gemeinsame Eliminierung während der Runde (Kick, Austritt)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._remove_from_round(p_lobby_id uuid, p_target uuid, p_force_alive boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_was_alive boolean;
  v_was_holder boolean;
  v_alive int;
  v_next uuid;
  v_round int;
begin
  select * into v_lobby from public.lobbies where id = p_lobby_id for update;
  if not found or v_lobby.phase <> 'running' then return; end if;

  select is_alive into v_was_alive from public.players where lobby_id = p_lobby_id and player_id = p_target;
  v_was_alive := coalesce(v_was_alive, false) or p_force_alive;
  if not v_was_alive then return; end if;

  v_was_holder := (v_lobby.holder_player_id = p_target);

  update public.players
  set is_alive = false, survival_streak = 0, combo = 0
  where lobby_id = p_lobby_id and player_id = p_target;

  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = p_lobby_id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target,
      round_number = coalesce(round_number, 0) + 1,
      last_activity_at = now()
  where id = p_lobby_id
  returning round_number into v_round;

  update public.players set eliminated_at_round = v_round
  where lobby_id = p_lobby_id and player_id = p_target;

  select count(*) into v_alive
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_alive <= 1 then
    perform public._finish_round(p_lobby_id);
    return;
  end if;

  if not v_was_holder then return; end if;

  -- Nächster Halter: Richtung beachten (Rache-Pass), Teleport = zufällig
  if v_lobby.game_mode = 'teleport' then
    select player_id into v_next from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  else
    v_next := public._next_alive(p_lobby_id, p_target, case when v_lobby.game_mode = 'original' then coalesce(v_lobby.pass_direction, 1) else 1 end);
  end if;

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = now() + public.calc_explode_seconds(coalesce(v_lobby.round_speed, 'normal'), v_alive, coalesce(v_round, 1)) * interval '1 second',
      round_bonus_used = 0,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0
  where id = p_lobby_id;

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- Host-Kick mitten in der Runde nutzt dieselbe Funktion (jetzt richtungsbewusst)
CREATE OR REPLACE FUNCTION public.rpc_host_kick_during_round(p_code text, p_host_player_id uuid, p_target_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_host_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.host_player_id is distinct from p_host_player_id then raise exception 'not_host'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if p_target_player_id = p_host_player_id then raise exception 'cannot_kick_self'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_target_player_id
      and status = 'active' and is_alive = true
  ) then raise exception 'target_not_active'; end if;

  perform public._remove_from_round(v_lobby.id, p_target_player_id);
end;
$function$;

-- ------------------------------------------------------------
-- 1) + 2) Austritt: Spiel läuft weiter
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._on_player_exit(p_lobby_id uuid, p_player_id uuid, p_was_alive boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phase text; v_code text; v_host uuid; v_new_host uuid;
  v_humans int; v_active int; v_survivor uuid;
begin
  select phase, code, host_player_id into v_phase, v_code, v_host
  from public.lobbies where id = p_lobby_id for update;
  if not found then return; end if;

  select count(*) filter (where not coalesce(is_bot, false)), count(*)
    into v_humans, v_active
  from public.players where lobby_id = p_lobby_id and status = 'active';

  -- Host weg -> nächster Mensch
  if v_host is null or not exists (
    select 1 from public.players where lobby_id = p_lobby_id and player_id = v_host and status = 'active'
  ) then
    select player_id into v_new_host from public.players
    where lobby_id = p_lobby_id and status = 'active' and not coalesce(is_bot, false)
    order by joined_at asc limit 1;
    if v_new_host is not null then
      update public.lobbies set host_player_id = v_new_host, last_activity_at = now() where id = p_lobby_id;
    end if;
  end if;

  -- Nur noch Bots (oder niemand): Lobby zurücksetzen
  if v_humans = 0 then
    if v_phase <> 'waiting' then perform public.rpc_reset_lobby(v_code); end if;
    return;
  end if;

  if v_phase = 'topic_vote' then
    delete from public.topic_votes where lobby_id = p_lobby_id and player_id = p_player_id;
    if v_active < 2 then perform public.rpc_reset_lobby(v_code); end if;

  elsif v_phase = 'countdown' then
    if v_active < 2 then perform public.rpc_reset_lobby(v_code); end if;

  elsif v_phase = 'running' then
    perform public._remove_from_round(p_lobby_id, p_player_id, p_was_alive);

  elsif v_phase = 'set_summary' then
    -- Zwischenstand: bleibt nur noch einer, ist das Match vorbei
    if v_active < 2 then
      select player_id into v_survivor from public.players
      where lobby_id = p_lobby_id and status = 'active' limit 1;
      update public.lobbies
      set phase = 'finished', explode_at = null, current_song_id = null, current_attempt_id = null,
          holder_player_id = v_survivor, last_activity_at = now()
      where id = p_lobby_id;
    end if;
  end if;
  -- waiting / finished / rematch_wait: nichts weiter -- die Ergebnisse bleiben stehen.
end;
$function$;

CREATE OR REPLACE FUNCTION public._trg_player_exit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' then
    if old.status = 'active' and new.status in ('left', 'kicked') then
      perform public._on_player_exit(new.lobby_id, new.player_id, coalesce(new.is_alive, false));
    end if;
  elsif tg_op = 'DELETE' then
    if old.status = 'active' then
      perform public._on_player_exit(old.lobby_id, old.player_id, coalesce(old.is_alive, false));
    end if;
  end if;
  return null;
end;
$function$;

-- Alte Reset-Trigger entfernen, neuen setzen
DROP TRIGGER IF EXISTS trg_players_reconcile_on_status ON public.players;
DROP TRIGGER IF EXISTS trg_players_reconcile_after_exit ON public.players;
DROP TRIGGER IF EXISTS trg_players_clear_on_status_leave ON public.players;
DROP TRIGGER IF EXISTS trg_players_reconcile_on_delete ON public.players;
DROP TRIGGER IF EXISTS trg_players_clear_on_delete ON public.players;

DROP TRIGGER IF EXISTS trg_player_exit_update ON public.players;
CREATE TRIGGER trg_player_exit_update
  AFTER UPDATE OF status ON public.players
  FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status)
  EXECUTE FUNCTION public._trg_player_exit();
DROP TRIGGER IF EXISTS trg_player_exit_delete ON public.players;
CREATE TRIGGER trg_player_exit_delete
  AFTER DELETE ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_player_exit();

-- Host-Nachfolge beim Löschen: bevorzugt Menschen
CREATE OR REPLACE FUNCTION public.end_lobby_if_host_left()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_new_host uuid;
begin
  if exists (select 1 from public.lobbies l where l.id = old.lobby_id and l.host_player_id = old.player_id) then
    select p.player_id into v_new_host
    from public.players p
    where p.lobby_id = old.lobby_id and p.status = 'active' and p.player_id <> old.player_id
    order by coalesce(p.is_bot, false) asc, p.joined_at asc
    limit 1;

    if v_new_host is not null then
      update public.lobbies set host_player_id = v_new_host, last_activity_at = now() where id = old.lobby_id;
    end if;
  end if;
  return null;
end;
$function$;

-- ------------------------------------------------------------
-- 7) Tote Alt-Funktionen entfernen
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.trg_clear_lobby_on_player_leave();
DROP FUNCTION IF EXISTS public.trg_reconcile_after_exit();
DROP FUNCTION IF EXISTS public.trg_reconcile_on_player_change();
DROP FUNCTION IF EXISTS public.reconcile_lobby_after_exit(uuid);
DROP FUNCTION IF EXISTS public.rpc_reconcile_lobby(uuid);
DROP FUNCTION IF EXISTS public.rpc_create_lobby(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.rpc_create_lobby(text, text, integer, integer, uuid);
DROP FUNCTION IF EXISTS public.rpc_start_game(uuid);
DROP FUNCTION IF EXISTS public.rpc_start_game(text);
DROP FUNCTION IF EXISTS public.rpc_start_game(uuid, uuid);
DROP FUNCTION IF EXISTS public.start_game(text, uuid);
DROP FUNCTION IF EXISTS public.start_game(uuid);
DROP FUNCTION IF EXISTS public.set_ready(uuid, boolean);
DROP FUNCTION IF EXISTS public.rpc_ready_up(text, uuid);
DROP FUNCTION IF EXISTS public.rpc_eliminate_player(uuid, uuid);
DROP FUNCTION IF EXISTS public.rpc_restart_game(uuid, uuid);
DROP FUNCTION IF EXISTS public.kick_player(uuid, uuid);
DROP FUNCTION IF EXISTS public.leave_lobby(uuid, uuid);
DROP FUNCTION IF EXISTS public.leave_lobby(uuid);
DROP FUNCTION IF EXISTS public.rpc_rematch_1v1(uuid);
DROP FUNCTION IF EXISTS public.rpc_schedule_next_explosion(uuid);

COMMIT;


-- >>> 074_transfer_host_humans_only.sql <<<
-- Migration 074: Host-Rolle darf nicht an einen Bot übertragen werden (niemand könnte die Lobby steuern).
CREATE OR REPLACE FUNCTION public.transfer_host(p_lobby_id uuid, p_me_player_id uuid, p_new_host_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      and not coalesce(p.is_bot, false)
  ) into v_ok;

  if not v_ok then raise exception 'new_host_not_active'; end if;

  update public.lobbies set host_player_id = p_new_host_player_id where id = p_lobby_id;
end;
$function$;


-- >>> 075_bot_games_unranked.sql <<<
-- ============================================================
-- Migration 075: Spiele gegen Bots zählen nicht für Bestenliste/Statistik
-- ============================================================
-- Mit "Solo gegen Bots" (ein Tipp, 3 schwache/mittlere Bots) konnte man sich
-- Saison-Punkte, Siege und Achievements beliebig erspielen. Ab jetzt werden
-- season_points und player_lifetime_stats (inkl. Achievements) nur noch
-- gutgeschrieben, wenn mindestens 2 Menschen in der Lobby mitgespielt haben
-- (Menschen, die mittendrin gegangen sind, zählen mit).
--
-- Spielablauf unverändert: series_results (Zwischenstand/Endstand) wird wie
-- bisher geschrieben, Phasenwechsel identisch zur Live-Version aus 062.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._lobby_human_count(p_lobby_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select count(*)::int from public.players
  where lobby_id = p_lobby_id and not coalesce(is_bot, false);
$function$;

REVOKE ALL ON FUNCTION public._lobby_human_count(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  v_ranked boolean := public._lobby_human_count(p_lobby_id) >= 2;
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.clutch * 10,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.is_bot, false) as is_bot
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler und nur, wenn mind. 2 Menschen mitspielen (075).
  if v_ranked then
    for r in
      select p.user_id, sr.arena_points, sr.place
      from public.series_results sr
      join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
      where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
    loop
      insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
      values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
      on conflict (user_id, season) do update
        set arena_points = public.season_points.arena_points + excluded.arena_points,
            sets_played = public.season_points.sets_played + 1,
            set_wins = public.season_points.set_wins + excluded.set_wins,
            updated_at = now();
    end loop;
  end if;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    if v_ranked then
      begin
        perform public.aggregate_player_stats(p_lobby_id);
      exception when others then
        null;
      end;
    end if;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.trg_aggregate_on_finished()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.phase = 'finished' AND (OLD.phase IS DISTINCT FROM NEW.phase)
       AND public._lobby_human_count(NEW.id) >= 2 THEN
        PERFORM public.aggregate_player_stats(NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;

-- >>> 076_account_history_analytics.sql <<<
-- ============================================================
-- Migration 076: Konto-Verlauf, Musik-Statistik, Analyse
-- ============================================================
-- Spielregeln bleiben unverändert. Alles hier SCHREIBT nur mit:
--   * lobbies.match_id      – eindeutige ID pro Match (BEFORE-Trigger beim Matchstart)
--   * game_events           – Protokoll pro Zug (Titel/Interpret/falsch/raus), per Trigger
--                             auf players; Fehler im Trigger brechen das Spiel NIE ab.
--                             Wird nach 90 Tagen gelöscht (pg_cron).
--   * account_rounds        – dauerhaft: eine Zeile pro Konto und Runde
--   * account_matches       – dauerhaft: eine Zeile pro Konto und Match (Match-Platz)
--   * _finish_round         – EIN zusätzlicher, abgesicherter Aufruf (_record_round_history)
--   * Achievements          – neue Musik-/Match-Achievements, unpassende Pass-Achievements raus,
--                             Texte "Partie" -> "Runde" (games_played zählt Runden)
--   * funnel_events         – anonyme Nutzungs-Ereignisse (Solo gestartet, Beitritt, ...), 90 Tage
--   * RPCs: get_my_profile_stats, admin_song_stats, admin_balance_stats, admin_funnel, log_event
--   * Sicherheitsfix: rpc_get_admin_stats prüft jetzt auth.uid() statt nur die mitgeschickte ID
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Match-ID
-- ------------------------------------------------------------
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS match_id uuid;

CREATE OR REPLACE FUNCTION public._set_match_id_on_start()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  -- Neues Match = Wechsel in die Themenwahl aus einem Start-Zustand (nicht zwischen zwei Runden).
  if NEW.phase = 'topic_vote'
     and OLD.phase in ('waiting', 'lobby', 'rematch_wait', 'finished') then
    NEW.match_id := gen_random_uuid();
  end if;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_set_match_id ON public.lobbies;
CREATE TRIGGER lobbies_set_match_id
  BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._set_match_id_on_start();

-- ------------------------------------------------------------
-- 2) Spielprotokoll (H) – Rohdaten, 90 Tage
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.game_events (
  id            bigserial PRIMARY KEY,
  created_at    timestamptz NOT NULL DEFAULT now(),
  lobby_id      uuid NOT NULL,
  match_id      uuid,
  series_index  integer,
  round_number  integer,           -- "Zug"
  player_id     uuid NOT NULL,
  user_id       uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  is_bot        boolean NOT NULL DEFAULT false,
  bot_skill     smallint,
  kind          text NOT NULL CHECK (kind IN ('title', 'artist', 'wrong', 'exploded', 'left')),
  song_id       uuid,
  playlist      text,
  ms            integer,           -- Antwortzeit seit Songstart bzw. Haltezeit bis zur Explosion
  combo         integer,
  alive_count   integer,
  players_count integer
);

CREATE INDEX IF NOT EXISTS game_events_round_idx ON public.game_events (lobby_id, match_id, series_index, player_id);
CREATE INDEX IF NOT EXISTS game_events_created_idx ON public.game_events (created_at);
CREATE INDEX IF NOT EXISTS game_events_song_idx ON public.game_events (song_id);

ALTER TABLE public.game_events ENABLE ROW LEVEL SECURITY;  -- keine Policies: nur über SECURITY-DEFINER-Funktionen
REVOKE ALL ON public.game_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._trg_log_game_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l record;
  v_kind text;
  v_ms integer;
begin
  begin
    select match_id, series_index, round_number, topic_selected, current_song_id,
           current_song_started_at, holder_since, holder_player_id
      into l
    from public.lobbies where id = NEW.lobby_id;

    if NEW.song_points > OLD.song_points then
      v_kind := case when NEW.song_points - OLD.song_points >= 1 then 'title' else 'artist' end;
      v_ms := (extract(epoch from (now() - coalesce(l.current_song_started_at, l.holder_since, now()))) * 1000)::int;
    elsif NEW.last_wrong_guess_at is not null and NEW.last_wrong_guess_at is distinct from OLD.last_wrong_guess_at then
      v_kind := 'wrong';
      v_ms := (extract(epoch from (now() - coalesce(l.current_song_started_at, l.holder_since, now()))) * 1000)::int;
    elsif OLD.is_alive and not NEW.is_alive then
      v_kind := case when coalesce(NEW.status, 'active') = 'active' then 'exploded' else 'left' end;
      v_ms := case when l.holder_player_id = NEW.player_id
                   then (extract(epoch from (now() - coalesce(l.holder_since, now()))) * 1000)::int end;
    else
      return NEW;
    end if;

    insert into public.game_events
      (lobby_id, match_id, series_index, round_number, player_id, user_id, is_bot, bot_skill,
       kind, song_id, playlist, ms, combo, alive_count, players_count)
    values
      (NEW.lobby_id, l.match_id, l.series_index, l.round_number, NEW.player_id, NEW.user_id,
       coalesce(NEW.is_bot, false), NEW.bot_skill, v_kind, l.current_song_id, l.topic_selected,
       greatest(v_ms, 0), NEW.combo,
       (select count(*) from public.players p where p.lobby_id = NEW.lobby_id and p.status = 'active' and p.is_alive),
       (select count(*) from public.players p where p.lobby_id = NEW.lobby_id and p.status = 'active'));
  exception when others then
    -- Protokoll darf das Spiel niemals stören.
    raise warning 'game_events: %', sqlerrm;
  end;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS players_log_game_event ON public.players;
CREATE TRIGGER players_log_game_event
  AFTER UPDATE OF song_points, last_wrong_guess_at, is_alive ON public.players
  FOR EACH ROW
  WHEN (NEW.song_points > OLD.song_points
        OR (NEW.last_wrong_guess_at IS NOT NULL AND NEW.last_wrong_guess_at IS DISTINCT FROM OLD.last_wrong_guess_at)
        OR (OLD.is_alive AND NOT NEW.is_alive))
  EXECUTE FUNCTION public._trg_log_game_event();

-- ------------------------------------------------------------
-- 3) Konto-Verlauf (A, B, C, F) – dauerhaft
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_rounds (
  id               bigserial PRIMARY KEY,
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  match_id         uuid NOT NULL,
  lobby_code       text,
  round_index      integer NOT NULL,
  rounds_total     integer NOT NULL,
  played_at        timestamptz NOT NULL DEFAULT now(),
  playlist         text,
  place            integer,
  players_count    integer,
  humans_count     integer,
  bots_count       integer,
  arena_points     integer,
  song_points      numeric,
  title_hits       integer NOT NULL DEFAULT 0,
  artist_hits      integer NOT NULL DEFAULT 0,
  wrong_guesses    integer NOT NULL DEFAULT 0,
  answer_ms_sum    bigint NOT NULL DEFAULT 0,
  answer_count     integer NOT NULL DEFAULT 0,
  fastest_title_ms integer,
  best_combo       integer NOT NULL DEFAULT 0,
  ranked           boolean NOT NULL,
  UNIQUE (user_id, match_id, round_index)
);
CREATE INDEX IF NOT EXISTS account_rounds_user_idx ON public.account_rounds (user_id, played_at DESC);

CREATE TABLE IF NOT EXISTS public.account_matches (
  user_id        uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  match_id       uuid NOT NULL,
  lobby_code     text,
  finished_at    timestamptz NOT NULL DEFAULT now(),
  rounds_total   integer NOT NULL,
  place          integer NOT NULL,
  players_count  integer NOT NULL,
  humans_count   integer NOT NULL,
  bots_count     integer NOT NULL,
  total_points   integer NOT NULL,
  round_wins     integer NOT NULL,
  playlists      text[],
  title_hits     integer NOT NULL DEFAULT 0,
  artist_hits    integer NOT NULL DEFAULT 0,
  wrong_guesses  integer NOT NULL DEFAULT 0,
  ranked         boolean NOT NULL,
  PRIMARY KEY (user_id, match_id)
);
CREATE INDEX IF NOT EXISTS account_matches_user_idx ON public.account_matches (user_id, finished_at DESC);
CREATE INDEX IF NOT EXISTS account_matches_match_idx ON public.account_matches (match_id);

ALTER TABLE public.account_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_matches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_rounds_own ON public.account_rounds;
CREATE POLICY account_rounds_own ON public.account_rounds FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS account_matches_own ON public.account_matches;
CREATE POLICY account_matches_own ON public.account_matches FOR SELECT USING (auth.uid() = user_id);
REVOKE ALL ON public.account_rounds, public.account_matches FROM anon, authenticated;
GRANT SELECT ON public.account_rounds, public.account_matches TO authenticated;

-- ------------------------------------------------------------
-- 4) Achievements (D, F)
-- ------------------------------------------------------------
-- Unpassend fürs Musik-Spiel (0x freigeschaltet): Pass in < 500 ms ist mit Titel-Eintippen
-- kaum möglich, Pass-Zähler/Haltezeit ersetzt durch Musik-Achievements.
DELETE FROM public.achievements WHERE code IN ('speed_demon', 'first_pass', 'passes_100', 'passes_500', 'iron_lung');

-- games_played/wins zählen seit den Runden-Matches einzelne RUNDEN.
UPDATE public.achievements SET description = 'Gewinne deine erste Runde.' WHERE code = 'first_win';
UPDATE public.achievements SET description = 'Gewinne 5 Runden.' WHERE code = 'wins_5';
UPDATE public.achievements SET description = 'Gewinne 25 Runden.' WHERE code = 'wins_25';
UPDATE public.achievements SET description = 'Gewinne 100 Runden.' WHERE code = 'wins_100';
UPDATE public.achievements SET description = 'Spiele 10 Runden zu Ende.' WHERE code = 'games_10';
UPDATE public.achievements SET description = 'Spiele 50 Runden zu Ende.' WHERE code = 'games_50';

INSERT INTO public.achievements (code, title, description, icon, tier) VALUES
  ('music_first_title', 'Ohrwurm',        'Erkenne deinen ersten Songtitel.',                           '🎵', 'bronze'),
  ('music_titles_50',   'Plattensammler', 'Erkenne insgesamt 50 Songtitel.',                            '💿', 'silver'),
  ('music_titles_250',  'Musiklexikon',   'Erkenne insgesamt 250 Songtitel.',                           '📚', 'gold'),
  ('music_combo_5',     'Lauf',           'Erkenne 5 Titel in Folge in einer Runde.',                   '🔥', 'silver'),
  ('music_quick_ear',   'Blitzohr',       'Erkenne einen Titel in unter 3 Sekunden.',                   '⚡', 'silver'),
  ('music_genre_50',    'Genre-Kenner',   'Erkenne 50 Titel aus derselben Playlist.',                   '🎧', 'silver'),
  ('music_all_lists',   'Allrounder',     'Gewinne in jeder der 6 Playlists mindestens eine Runde.',    '🌈', 'gold'),
  ('match_win_3',       'Matchwinner',    'Gewinne ein Match über 3 Runden.',                           '🏁', 'silver'),
  ('match_win_5',       'Serienmeister',  'Gewinne ein Match über 5 Runden.',                           '👑', 'gold')
ON CONFLICT (code) DO UPDATE
  SET title = EXCLUDED.title, description = EXCLUDED.description, icon = EXCLUDED.icon, tier = EXCLUDED.tier;

CREATE OR REPLACE FUNCTION public._award_history_achievements(p_user_id uuid, p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_titles int; v_combo int; v_fastest int; v_genre int; v_lists int; v_win3 int; v_win5 int;
begin
  -- Nur gewertete Spiele (mind. 2 Menschen, siehe 075).
  select coalesce(sum(title_hits), 0), coalesce(max(best_combo), 0), min(fastest_title_ms)
    into v_titles, v_combo, v_fastest
  from public.account_rounds where user_id = p_user_id and ranked;

  select coalesce(max(t), 0) into v_genre
  from (select sum(title_hits) t from public.account_rounds
        where user_id = p_user_id and ranked group by playlist) x;

  select count(distinct playlist) into v_lists
  from public.account_rounds where user_id = p_user_id and ranked and place = 1 and playlist is not null;

  select count(*) filter (where rounds_total >= 3), count(*) filter (where rounds_total >= 5)
    into v_win3, v_win5
  from public.account_matches where user_id = p_user_id and ranked and place = 1;

  insert into public.player_achievements (user_id, achievement_code, lobby_id)
  select p_user_id, a.code, p_lobby_id
  from public.achievements a
  where (a.code = 'music_first_title' and v_titles >= 1)
     or (a.code = 'music_titles_50'   and v_titles >= 50)
     or (a.code = 'music_titles_250'  and v_titles >= 250)
     or (a.code = 'music_combo_5'     and v_combo >= 5)
     or (a.code = 'music_quick_ear'   and v_fastest is not null and v_fastest < 3000)
     or (a.code = 'music_genre_50'    and v_genre >= 50)
     or (a.code = 'music_all_lists'   and v_lists >= 6)
     or (a.code = 'match_win_3'       and v_win3 >= 1)
     or (a.code = 'match_win_5'       and v_win5 >= 1)
  on conflict (user_id, achievement_code) do nothing;
end;
$function$;

-- ------------------------------------------------------------
-- 5) Verlauf beim Rundenende schreiben
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._record_round_history(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l record;
  v_match uuid;
  v_idx int; v_total int;
  v_humans int; v_bots int; v_n int;
  v_ranked boolean;
  u record;
begin
  select id, code, series_index, series_total, topic_selected, match_id into l
  from public.lobbies where id = p_lobby_id;
  if not found then return; end if;

  v_idx := coalesce(l.series_index, 1);
  v_total := coalesce(l.series_total, 1);
  v_match := l.match_id;
  if v_match is null then
    -- Lobby lief schon vor Migration 076: ID nachträglich vergeben.
    v_match := gen_random_uuid();
    update public.lobbies set match_id = v_match where id = p_lobby_id;
  end if;

  v_humans := public._lobby_human_count(p_lobby_id);
  select count(*) filter (where coalesce(is_bot, false)), count(*)
    into v_bots, v_n
  from public.players where lobby_id = p_lobby_id and status = 'active';
  v_ranked := v_humans >= 2;

  insert into public.account_rounds
    (user_id, match_id, lobby_code, round_index, rounds_total, playlist, place, players_count,
     humans_count, bots_count, arena_points, song_points, title_hits, artist_hits, wrong_guesses,
     answer_ms_sum, answer_count, fastest_title_ms, best_combo, ranked)
  select p.user_id, v_match, l.code, v_idx, v_total, l.topic_selected, sr.place, v_n,
         v_humans, v_bots, sr.arena_points, sr.song_points,
         coalesce(e.titles, 0), coalesce(e.artists, 0), coalesce(e.wrongs, 0),
         coalesce(e.ms_sum, 0), coalesce(e.ms_n, 0), e.fastest, coalesce(e.combo, 0), v_ranked
  from public.players p
  join public.profiles pr on pr.id = p.user_id
  join public.series_results sr
    on sr.lobby_id = p.lobby_id and sr.player_id = p.player_id and sr.set_index = v_idx
  left join lateral (
    select count(*) filter (where ge.kind = 'title')  as titles,
           count(*) filter (where ge.kind = 'artist') as artists,
           count(*) filter (where ge.kind = 'wrong')  as wrongs,
           sum(ge.ms) filter (where ge.kind in ('title', 'artist')) as ms_sum,
           count(ge.ms) filter (where ge.kind in ('title', 'artist')) as ms_n,
           min(ge.ms) filter (where ge.kind = 'title') as fastest,
           max(ge.combo) filter (where ge.kind = 'title') as combo
    from public.game_events ge
    where ge.lobby_id = p_lobby_id and ge.match_id = v_match
      and ge.series_index = v_idx and ge.player_id = p.player_id
  ) e on true
  where p.lobby_id = p_lobby_id and p.user_id is not null and not coalesce(p.is_bot, false)
  on conflict (user_id, match_id, round_index) do nothing;

  -- Letzte Runde des Matches: Match-Platz über alle Runden (wie die Anzeige im Spiel:
  -- Punkte, dann Rundensiege, dann besserer Ø-Platz).
  if v_idx >= v_total then
    insert into public.account_matches
      (user_id, match_id, lobby_code, rounds_total, place, players_count, humans_count, bots_count,
       total_points, round_wins, playlists, title_hits, artist_hits, wrong_guesses, ranked)
    select p.user_id, v_match, l.code, v_total, rk.mplace, rk.n, v_humans, v_bots,
           rk.total, rk.wins,
           (select array_agg(ar.playlist order by ar.round_index) from public.account_rounds ar
             where ar.user_id = p.user_id and ar.match_id = v_match),
           coalesce((select sum(ar.title_hits) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           coalesce((select sum(ar.artist_hits) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           coalesce((select sum(ar.wrong_guesses) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           v_ranked
    from (
      select t.player_id, t.total, t.wins,
             row_number() over (order by t.total desc, t.wins desc, t.avgp asc)::int as mplace,
             count(*) over ()::int as n
      from (
        select sr.player_id, sum(sr.arena_points)::int as total,
               count(*) filter (where sr.place = 1)::int as wins, avg(sr.place) as avgp
        from public.series_results sr
        where sr.lobby_id = p_lobby_id and sr.set_index <= v_total
        group by sr.player_id
      ) t
    ) rk
    join public.players p on p.lobby_id = p_lobby_id and p.player_id = rk.player_id
    join public.profiles pr on pr.id = p.user_id
    where p.user_id is not null and not coalesce(p.is_bot, false)
    on conflict (user_id, match_id) do nothing;
  end if;

  if v_ranked then
    for u in
      select distinct p.user_id from public.players p
      where p.lobby_id = p_lobby_id and p.user_id is not null and not coalesce(p.is_bot, false)
    loop
      perform public._award_history_achievements(u.user_id, p_lobby_id);
    end loop;
  end if;
end;
$function$;

-- _finish_round: identisch zu 075, nur EIN abgesicherter Aufruf mehr (vor dem Phasenwechsel).
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  v_ranked boolean := public._lobby_human_count(p_lobby_id) >= 2;
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.clutch * 10,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.is_bot, false) as is_bot
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler und nur, wenn mind. 2 Menschen mitspielen (075).
  if v_ranked then
    for r in
      select p.user_id, sr.arena_points, sr.place
      from public.series_results sr
      join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
      where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
    loop
      insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
      values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
      on conflict (user_id, season) do update
        set arena_points = public.season_points.arena_points + excluded.arena_points,
            sets_played = public.season_points.sets_played + 1,
            set_wins = public.season_points.set_wins + excluded.set_wins,
            updated_at = now();
    end loop;
  end if;

  -- Konto-Verlauf (076). Darf das Rundenende niemals blockieren.
  begin
    perform public._record_round_history(p_lobby_id);
  exception when others then
    raise warning 'record_round_history: %', sqlerrm;
  end;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    if v_ranked then
      begin
        perform public.aggregate_player_stats(p_lobby_id);
      exception when others then
        null;
      end;
    end if;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public._record_round_history(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._award_history_achievements(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_log_game_event() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 6) Profil-Statistik für das eigene Konto (A, B, C, E, F)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_profile_stats(p_season text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_season text := coalesce(p_season, to_char(now(), 'YYYY-MM'));
  v_from timestamptz;
  v_to timestamptz;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  v_from := to_date(v_season || '-01', 'YYYY-MM-DD')::timestamptz;
  v_to := v_from + interval '1 month';

  return jsonb_build_object(
    -- F: Matches und Runden getrennt (nur gewertete Spiele)
    'totals', (
      select jsonb_build_object(
        'matches', (select count(*) from account_matches where user_id = v_uid and ranked),
        'matchWins', (select count(*) from account_matches where user_id = v_uid and ranked and place = 1),
        'rounds', (select count(*) from account_rounds where user_id = v_uid and ranked),
        'roundWins', (select count(*) from account_rounds where user_id = v_uid and ranked and place = 1),
        'practiceMatches', (select count(*) from account_matches where user_id = v_uid and not ranked)
      )
    ),
    -- B: Musik (alle Runden inkl. Übung – es geht ums eigene Song-Wissen)
    'music', (
      select jsonb_build_object(
        'titles', coalesce(sum(title_hits), 0),
        'artists', coalesce(sum(artist_hits), 0),
        'wrong', coalesce(sum(wrong_guesses), 0),
        'avgAnswerMs', case when sum(answer_count) > 0 then round(sum(answer_ms_sum)::numeric / sum(answer_count)) end,
        'fastestTitleMs', min(fastest_title_ms),
        'bestCombo', coalesce(max(best_combo), 0)
      ) from account_rounds where user_id = v_uid
    ),
    'playlists', coalesce((
      select jsonb_agg(x order by x.rounds desc) from (
        select playlist, count(*)::int as rounds,
               sum(title_hits)::int as titles, sum(artist_hits)::int as artists, sum(wrong_guesses)::int as wrong,
               count(*) filter (where place = 1)::int as wins
        from account_rounds where user_id = v_uid and playlist is not null
        group by playlist
      ) x
    ), '[]'::jsonb),
    -- A: letzte 20 Matches
    'recent', coalesce((
      select jsonb_agg(m order by m.finished_at desc) from (
        select finished_at, rounds_total, place, players_count, humans_count, bots_count,
               total_points, round_wins, playlists, title_hits, artist_hits, wrong_guesses, ranked
        from account_matches where user_id = v_uid
        order by finished_at desc limit 20
      ) m
    ), '[]'::jsonb),
    -- C: häufigste Gegner (nur Konten)
    'opponents', coalesce((
      select jsonb_agg(o order by o.matches desc, o.username) from (
        select pr.username, count(*)::int as matches,
               count(*) filter (where me.place < op.place)::int as wins,
               count(*) filter (where me.place > op.place)::int as losses
        from account_matches me
        join account_matches op on op.match_id = me.match_id and op.user_id <> me.user_id
        join profiles pr on pr.id = op.user_id
        where me.user_id = v_uid and pr.username is not null
        group by pr.username
        order by count(*) desc, pr.username
        limit 5
      ) o
    ), '[]'::jsonb),
    -- E: Monats-Rückblick
    'recap', jsonb_build_object(
      'season', v_season,
      'rank', (select rank from season_leaderboard_view where season = v_season and user_id = v_uid),
      'seasonPoints', (select arena_points from season_points where season = v_season and user_id = v_uid),
      'matches', (select count(*) from account_matches where user_id = v_uid and finished_at >= v_from and finished_at < v_to),
      'matchWins', (select count(*) from account_matches where user_id = v_uid and ranked and place = 1 and finished_at >= v_from and finished_at < v_to),
      'rounds', (select count(*) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'titles', (select coalesce(sum(title_hits), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'artists', (select coalesce(sum(artist_hits), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'wrong', (select coalesce(sum(wrong_guesses), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'bestRoundPoints', (select max(arena_points) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'fastestTitleMs', (select min(fastest_title_ms) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'favoritePlaylist', (
        select playlist from account_rounds
        where user_id = v_uid and played_at >= v_from and played_at < v_to and playlist is not null
        group by playlist order by count(*) desc, playlist limit 1
      ),
      'bestPlaylist', (
        select playlist from account_rounds
        where user_id = v_uid and played_at >= v_from and played_at < v_to and playlist is not null
        group by playlist
        having sum(title_hits + artist_hits + wrong_guesses) >= 5
        order by sum(title_hits)::numeric / nullif(sum(title_hits + artist_hits + wrong_guesses), 0) desc, playlist
        limit 1
      )
    )
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.get_my_profile_stats(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_profile_stats(text) TO authenticated;

-- ------------------------------------------------------------
-- 7) Admin-Auswertungen (G, H, I) – nur Platform-Admins, Prüfung über auth.uid()
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._require_platform_admin()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where id = auth.uid() and coalesce(is_platform_admin, false)
  ) then
    raise exception 'not_authorized';
  end if;
end;
$function$;
REVOKE ALL ON FUNCTION public._require_platform_admin() FROM PUBLIC, anon, authenticated;

-- G: Wie gut wird jeder Song erkannt? (nur Menschen)
CREATE OR REPLACE FUNCTION public.admin_song_stats(p_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public._require_platform_admin();
  return coalesce((
    select jsonb_agg(s order by s.rate nulls first, s.plays desc) from (
      select tp.text as playlist, sp.title, sp.artist, sp.plays, sp.hits,
             case when sp.plays > 0 then round(100.0 * sp.hits / sp.plays) end as rate,
             coalesce(e.artists, 0) as artists, coalesce(e.wrong, 0) as wrong, e.avg_ms
      from public.song_pool sp
      join public.topic_pool tp on tp.id = sp.topic_pool_id
      left join (
        select song_id,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong,
               round(avg(ms) filter (where kind = 'title'))::int as avg_ms
        from public.game_events
        where not is_bot and created_at > now() - make_interval(days => greatest(1, p_days))
        group by song_id
      ) e on e.song_id = sp.id
      where sp.plays > 0
    ) s
  ), '[]'::jsonb);
end;
$function$;

-- H: Balance aus echten Spielen
CREATE OR REPLACE FUNCTION public.admin_balance_stats(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from timestamptz := now() - make_interval(days => greatest(1, p_days));
begin
  perform public._require_platform_admin();
  return jsonb_build_object(
    'days', greatest(1, p_days),
    'groups', coalesce((
      select jsonb_agg(g order by g.who) from (
        select case when is_bot then 'Bot Stärke ' || coalesce(bot_skill, 0) else 'Menschen' end as who,
               count(*) filter (where kind = 'title')::int as titles,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong,
               count(*) filter (where kind = 'exploded')::int as exploded,
               round(avg(ms) filter (where kind in ('title', 'artist')))::int as avg_answer_ms,
               round(avg(ms) filter (where kind = 'exploded'))::int as avg_hold_before_boom_ms
        from public.game_events where created_at > v_from
        group by 1
      ) g
    ), '[]'::jsonb),
    'byAlive', coalesce((
      select jsonb_agg(a order by a.bucket) from (
        select case when alive_count <= 2 then '1 Duell (2 übrig)'
                    when alive_count <= 4 then '2 · 3–4 übrig'
                    else '3 · 5+ übrig' end as bucket,
               count(*) filter (where kind in ('title', 'artist'))::int as answers,
               round(avg(ms) filter (where kind in ('title', 'artist')))::int as avg_answer_ms,
               count(*) filter (where kind = 'exploded')::int as exploded,
               round(avg(ms) filter (where kind = 'exploded'))::int as avg_hold_before_boom_ms
        from public.game_events where created_at > v_from and not is_bot
        group by 1
      ) a
    ), '[]'::jsonb),
    -- Durchprobieren: wie viele Fehlversuche vor einem Treffer (pro Mensch, Zug, Song)
    'wrongBeforeHit', coalesce((
      select jsonb_agg(w order by w.wrong_tries) from (
        select least(t.wrongs, 5) as wrong_tries, count(*)::int as turns
        from (
          select lobby_id, player_id, round_number, song_id,
                 count(*) filter (where kind = 'wrong') as wrongs
          from public.game_events
          where created_at > v_from and not is_bot
          group by lobby_id, match_id, series_index, round_number, player_id, song_id
          having count(*) filter (where kind in ('title', 'artist')) > 0
        ) t
        group by 1
      ) w
    ), '[]'::jsonb),
    'playlists', coalesce((
      select jsonb_agg(p order by p.playlist) from (
        select playlist,
               count(*) filter (where kind = 'title')::int as titles,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong
        from public.game_events where created_at > v_from and not is_bot and playlist is not null
        group by playlist
      ) p
    ), '[]'::jsonb)
  );
end;
$function$;

-- I: Weg der Spieler – anonyme Nutzungs-Ereignisse
CREATE TABLE IF NOT EXISTS public.funnel_events (
  id         bigserial PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  event      text NOT NULL,
  anon_id    text,
  props      jsonb
);
CREATE INDEX IF NOT EXISTS funnel_events_created_idx ON public.funnel_events (created_at);
CREATE INDEX IF NOT EXISTS funnel_events_anon_idx ON public.funnel_events (anon_id, created_at);
ALTER TABLE public.funnel_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.funnel_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.log_event(p_event text, p_anon text, p_props jsonb DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_event not in (
    'home_view', 'solo_start', 'solo_game_started', 'host_created', 'join_success', 'spectate',
    'game_finished', 'invite_share', 'invite_copy', 'invite_qr', 'result_share',
    'install_click', 'lang_en', 'register_success'
  ) then return; end if;
  if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;
  -- einfache Bremse gegen Spam: max. 120 Ereignisse pro Gerät und Stunde
  if (select count(*) from public.funnel_events
      where anon_id = p_anon and created_at > now() - interval '1 hour') >= 120 then
    return;
  end if;
  insert into public.funnel_events (event, anon_id, props)
  values (p_event, p_anon, case when p_props is null or pg_column_size(p_props) > 400 then null else p_props end);
end;
$function$;
REVOKE ALL ON FUNCTION public.log_event(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_event(text, text, jsonb) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_funnel(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public._require_platform_admin();
  return coalesce((
    select jsonb_agg(f order by f.devices desc) from (
      select event, count(*)::int as total, count(distinct anon_id)::int as devices
      from public.funnel_events
      where created_at > now() - make_interval(days => greatest(1, p_days))
        and coalesce(props ->> 'dev', 'false') <> 'true'
      group by event
    ) f
  ), '[]'::jsonb);
end;
$function$;

REVOKE ALL ON FUNCTION public.admin_song_stats(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_balance_stats(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_funnel(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_song_stats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_balance_stats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_funnel(integer) TO authenticated;

-- ------------------------------------------------------------
-- 8) Sicherheitsfix: rpc_get_admin_stats vertraute der mitgeschickten p_user_id.
--    Die Nutzer-IDs sind öffentlich lesbar (profiles.id) -> jeder konnte die Admin-Zahlen abrufen.
--    Jetzt muss p_user_id der eingeloggte Nutzer sein. Rest der Funktion unverändert.
-- ------------------------------------------------------------
DO $$
declare
  d text;
begin
  select pg_get_functiondef('public.rpc_get_admin_stats(uuid)'::regprocedure) into d;
  if position('if p_user_id is null then' in d) = 0 then
    raise exception 'rpc_get_admin_stats: erwartete Prüfung nicht gefunden';
  end if;
  d := replace(d, 'if p_user_id is null then', 'if p_user_id is null or p_user_id is distinct from auth.uid() then');
  execute d;
end $$;

-- ------------------------------------------------------------
-- 9) Aufräumen nach 90 Tagen (Rohdaten; Konto-Verlauf bleibt)
-- ------------------------------------------------------------
DO $$
begin
  if exists (select 1 from cron.job where jobname = 'kumpir-analytics-retention') then
    perform cron.unschedule('kumpir-analytics-retention');
  end if;
  perform cron.schedule(
    'kumpir-analytics-retention', '17 3 * * *',
    $job$delete from public.game_events where created_at < now() - interval '90 days';
         delete from public.funnel_events where created_at < now() - interval '90 days';$job$
  );
end $$;

COMMIT;

-- >>> 077_account_settings.sql <<<
-- ============================================================
-- Migration 077: Konto-Einstellungen + Login-Robustheit + Sicherheitsfix
-- ============================================================
-- 1) SICHERHEIT: anon/authenticated hatten UPDATE/INSERT auf ALLE Spalten von
--    profiles (inkl. is_platform_admin) und die Policy "profiles_update_own" –
--    jeder Eingeloggte konnte sich per API selbst zum Admin machen oder Username/
--    E-Mail ohne Prüfung ändern. Ab jetzt: nur noch Lesen; Änderungen nur über
--    geprüfte RPCs unten.
-- 2) Neue Profilfelder: Spielername, Avatar (Emoji + Farbe), Vorlieben (jsonb).
-- 3) RPCs: get_my_settings, set_my_username, update_my_profile,
--    set_my_preferences, delete_my_account.
-- 4) Login: Konten ohne Profilzeile (z. B. vor dem Profil-Trigger angelegt)
--    werden nachgetragen; handle_new_user bricht eine Registrierung nicht mehr
--    ab, wenn der Wunsch-Username inzwischen vergeben/ungültig ist.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Rechte auf profiles: nur noch lesen
-- ------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.profiles FROM anon, authenticated;
DROP POLICY IF EXISTS profiles_update_own ON public.profiles;

-- ------------------------------------------------------------
-- 2) Neue Spalten
-- ------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS display_name text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_emoji text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_color text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS preferences jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS username_changed_at timestamptz;

-- Öffentlich sichtbar (Bestenliste/Freunde): Name + Avatar. Vorlieben/E-Mail nur über RPC.
GRANT SELECT (display_name, avatar_emoji, avatar_color) ON public.profiles TO anon, authenticated;

-- ------------------------------------------------------------
-- Prüf-Hilfen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._valid_username(p text)
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$
  select p is not null and p ~ '^[a-z0-9._-]{3,20}$';
$function$;

-- Spielername wie beim Beitreten: nur Buchstaben (inkl. Umlaute), 2–12 Zeichen
CREATE OR REPLACE FUNCTION public._valid_display_name(p text)
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$
  select p is not null and p ~ '^[A-Za-zÄÖÜäöüß]{2,12}$';
$function$;

-- Grobe Schimpfwort-Sperre (gleiche Liste wie lib/profanity.ts, Kurzfassung)
CREATE OR REPLACE FUNCTION public._is_profane(p text)
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$
  select lower(coalesce(p, '')) ~ '(arschloch|fotze|hurensohn|missgeburt|nazi|neger|schlampe|schwuchtel|wichser|bitch|cunt|faggot|kike|nigger|nigga|retard|whore)';
$function$;

-- ------------------------------------------------------------
-- 4a) Registrierung robust: vergebener/ungültiger Wunsch-Username -> NULL statt Fehler
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_username text := nullif(public.normalize_username(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if v_username is not null and (
       not public._valid_username(v_username)
       or public._is_profane(v_username)
       or exists (select 1 from public.profiles p where lower(p.username) = v_username and p.id <> new.id)
     ) then
    v_username := null;  -- Konto trotzdem anlegen; Username wählt man dann im Profil
  end if;

  insert into public.profiles (id, username, email, created_at)
  values (new.id, v_username, new.email, now())
  on conflict (id) do update set
    username = coalesce(public.profiles.username, excluded.username),
    email = coalesce(excluded.email, public.profiles.email);

  return new;
end;
$function$;

-- 4b) Fehlende Profile nachtragen (z. B. Konto "medo" von Feb. 2026 ohne Profilzeile)
INSERT INTO public.profiles (id, username, email, email_verified_at, created_at)
SELECT u.id,
       case
         when public._valid_username(public.normalize_username(u.raw_user_meta_data->>'username'))
              and not exists (select 1 from public.profiles p
                              where lower(p.username) = public.normalize_username(u.raw_user_meta_data->>'username'))
         then public.normalize_username(u.raw_user_meta_data->>'username')
       end,
       u.email, u.email_confirmed_at, coalesce(u.created_at, now())
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id)
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------
-- 3) Einstellungen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  select username, display_name, avatar_emoji, avatar_color, preferences, email, username_changed_at
    into r from public.profiles where id = v_uid;
  if not found then
    -- Sicherheitsnetz: Profil fehlt -> jetzt anlegen (ohne Username)
    insert into public.profiles (id, email, created_at)
    select id, email, now() from auth.users where id = v_uid
    on conflict (id) do nothing;
    return jsonb_build_object('username', null, 'displayName', null, 'avatarEmoji', null,
                              'avatarColor', null, 'preferences', '{}'::jsonb);
  end if;
  return jsonb_build_object(
    'username', r.username,
    'displayName', r.display_name,
    'avatarEmoji', r.avatar_emoji,
    'avatarColor', r.avatar_color,
    'preferences', coalesce(r.preferences, '{}'::jsonb),
    'usernameChangedAt', r.username_changed_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_username(p_username text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v text := public.normalize_username(p_username);
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if not public._valid_username(v) then raise exception 'username_invalid'; end if;
  if public._is_profane(v) then raise exception 'username_profane'; end if;
  if exists (select 1 from public.profiles where lower(username) = v and id <> v_uid) then
    raise exception 'username_taken';
  end if;
  update public.profiles
     set username = v,
         username_changed_at = case when username is distinct from v then now() else username_changed_at end
   where id = v_uid;
  return v;
exception when unique_violation then
  raise exception 'username_taken';
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_my_profile(p_display_name text, p_avatar_emoji text, p_avatar_color text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_name text := nullif(trim(coalesce(p_display_name, '')), '');
  v_emoji text := nullif(trim(coalesce(p_avatar_emoji, '')), '');
  v_color text := nullif(trim(coalesce(p_avatar_color, '')), '');
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if v_name is not null and (not public._valid_display_name(v_name) or public._is_profane(v_name)) then
    raise exception 'display_name_invalid';
  end if;
  -- Emoji: ein einzelnes Zeichen bzw. eine kurze Emoji-Sequenz, keine Buchstaben/Ziffern
  if v_emoji is not null and (char_length(v_emoji) > 8 or v_emoji ~ '[A-Za-z0-9<>"''&]') then
    raise exception 'avatar_invalid';
  end if;
  if v_color is not null and v_color !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'avatar_invalid';
  end if;
  update public.profiles
     set display_name = v_name, avatar_emoji = v_emoji, avatar_color = lower(v_color)
   where id = v_uid;
end;
$function$;

-- Vorlieben: nur bekannte Schlüssel mit gültigen Werten werden übernommen.
CREATE OR REPLACE FUNCTION public.set_my_preferences(p_prefs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  p jsonb := coalesce(p_prefs, '{}'::jsonb);
  h jsonb := coalesce(p_prefs -> 'host', '{}'::jsonb);
  s jsonb := coalesce(p_prefs -> 'solo', '{}'::jsonb);
  out jsonb := '{}'::jsonb;
  host_out jsonb := '{}'::jsonb;
  solo_out jsonb := '{}'::jsonb;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'prefs_invalid'; end if;

  if p ->> 'lang' in ('de', 'en') then out := out || jsonb_build_object('lang', p ->> 'lang'); end if;
  if jsonb_typeof(p -> 'muted') = 'boolean' then out := out || jsonb_build_object('muted', (p ->> 'muted')::boolean); end if;
  if jsonb_typeof(p -> 'volume') = 'number' and (p ->> 'volume')::numeric between 0 and 1 then
    out := out || jsonb_build_object('volume', round((p ->> 'volume')::numeric, 2));
  end if;

  if jsonb_typeof(h -> 'maxPlayers') = 'number' and (h ->> 'maxPlayers')::numeric between 2 and 12 then
    host_out := host_out || jsonb_build_object('maxPlayers', (h ->> 'maxPlayers')::numeric::int);
  end if;
  if h ->> 'speed' in ('fast', 'normal', 'calm') then host_out := host_out || jsonb_build_object('speed', h ->> 'speed'); end if;
  if h ->> 'rounds' in ('1', '3', '5') then host_out := host_out || jsonb_build_object('rounds', (h ->> 'rounds')::int); end if;
  if h ->> 'answerMode' in ('text', 'voice') then host_out := host_out || jsonb_build_object('answerMode', h ->> 'answerMode'); end if;
  if host_out <> '{}'::jsonb then out := out || jsonb_build_object('host', host_out); end if;

  if jsonb_typeof(s -> 'bots') = 'number' and (s ->> 'bots')::numeric between 1 and 5 then
    solo_out := solo_out || jsonb_build_object('bots', (s ->> 'bots')::numeric::int);
  end if;
  if s ->> 'skill' in ('mixed', '1', '2', '3') then solo_out := solo_out || jsonb_build_object('skill', s ->> 'skill'); end if;
  if solo_out <> '{}'::jsonb then out := out || jsonb_build_object('solo', solo_out); end if;

  update public.profiles set preferences = out where id = v_uid;
  return out;
end;
$function$;

-- Konto löschen: entfernt den Auth-Nutzer; Profil, Verlauf, Achievements, Freunde
-- fallen per Fremdschlüssel (ON DELETE CASCADE) weg, Spieler-Zeilen verlieren die Verknüpfung.
CREATE OR REPLACE FUNCTION public.delete_my_account()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from public.profiles where id = v_uid and coalesce(is_platform_admin, false)) then
    raise exception 'admin_cannot_delete';  -- Admin-Konto nicht versehentlich verlieren
  end if;
  delete from auth.users where id = v_uid;
end;
$function$;

REVOKE ALL ON FUNCTION public.get_my_settings() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_my_username(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_my_profile(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_my_preferences(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_username(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_my_profile(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_preferences(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

-- Username-Verfügbarkeit auch für die Profil-Seite (eigener Name zählt als frei)
CREATE OR REPLACE FUNCTION public.is_username_available(p_username text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._valid_username(public.normalize_username(p_username))
     and not public._is_profane(p_username)
     and not exists (
       select 1 from public.profiles
       where lower(username) = public.normalize_username(p_username)
         and id is distinct from auth.uid()
     );
$function$;

-- Saison-Bestenliste mit Avatar (Spalten nur hinten anhängen)
CREATE OR REPLACE VIEW public.season_leaderboard_view
  WITH (security_invoker = true) AS
SELECT sp.season, sp.user_id, pr.username, sp.arena_points, sp.sets_played, sp.set_wins,
       rank() OVER (PARTITION BY sp.season ORDER BY sp.arena_points DESC, sp.set_wins DESC) AS rank,
       pr.avatar_emoji, pr.avatar_color
FROM public.season_points sp
JOIN public.profiles pr ON pr.id = sp.user_id
WHERE pr.username IS NOT NULL;

COMMIT;

-- >>> 078_admin_panel_roles.sql <<<
-- ============================================================
-- Migration 078: Admin-Panel, Rollen, Löschanträge, Playlist-Auswahl
-- ============================================================
-- Rollen (profiles.role):  user | supporter | admin
--   supporter: Nutzer ansehen/sperren/entsperren (nur normale Nutzer), Namen/Avatar
--              zurücksetzen, Löschanträge sehen und ablehnen, Lobbys schließen, Protokoll
--   admin:     zusätzlich Konten endgültig löschen, Rollen vergeben, Songs archivieren,
--              Statistik/Auswertung
-- Konto-Status (profiles.status): active | suspended | deletion_requested
--   Löschantrag durch den Spieler: Zugang sofort zu (Auth-Sperre + alle Sitzungen beendet),
--   endgültig gelöscht wird nur durch einen Admin. Bis dahin kann das Team ihn ablehnen.
-- Playlists: Abstimmung nur noch aus Musik-Playlists (vorher konnten bei leerem Filter
--   56 alte Nicht-Musik-Themen gezogen werden -> Runde ohne Song). Leerer Filter = alle.
-- Alle Admin-Aktionen landen im Protokoll (admin_audit).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Spalten
-- ------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'user';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status_reason text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status_changed_at timestamptz;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status_changed_by uuid;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS deletion_requested_at timestamptz;

DO $$ begin
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check CHECK (role IN ('user', 'supporter', 'admin'));
exception when duplicate_object then null; end $$;
DO $$ begin
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_status_check CHECK (status IN ('active', 'suspended', 'deletion_requested'));
exception when duplicate_object then null; end $$;

UPDATE public.profiles SET role = 'admin' WHERE coalesce(is_platform_admin, false) AND role <> 'admin';

ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS archived_from text;

-- Protokoll
CREATE TABLE IF NOT EXISTS public.admin_audit (
  id           bigserial PRIMARY KEY,
  created_at   timestamptz NOT NULL DEFAULT now(),
  actor_id     uuid,
  actor_name   text,
  action       text NOT NULL,
  target_id    uuid,
  target_label text,
  details      jsonb
);
CREATE INDEX IF NOT EXISTS admin_audit_created_idx ON public.admin_audit (created_at DESC);
ALTER TABLE public.admin_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_audit FROM anon, authenticated;

-- ------------------------------------------------------------
-- Rollen-Hilfen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_role()
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select case when p.role in ('admin', 'supporter') and p.status = 'active' then p.role end
  from public.profiles p where p.id = auth.uid();
$function$;

-- p_min = 'supporter' (Supporter oder Admin) | 'admin'
CREATE OR REPLACE FUNCTION public._require_staff(p_min text)
 RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r text := public._staff_role();
begin
  if r is null or (p_min = 'admin' and r <> 'admin') then
    raise exception 'not_authorized';
  end if;
  return r;
end;
$function$;

-- Bestehende Admin-Auswertungen (076) laufen weiter über diese Funktion
CREATE OR REPLACE FUNCTION public._require_platform_admin()
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('admin');
end;
$function$;

CREATE OR REPLACE FUNCTION public._audit(p_action text, p_target uuid, p_label text, p_details jsonb DEFAULT NULL)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  insert into public.admin_audit (actor_id, actor_name, action, target_id, target_label, details)
  values (auth.uid(), (select coalesce(username, email) from public.profiles where id = auth.uid()), p_action, p_target, p_label, p_details);
$function$;

-- Zugang sperren/öffnen (Auth-Ebene). Sperre bis 2999 statt "infinity" (wird von der Auth-API sicher gelesen).
CREATE OR REPLACE FUNCTION public._set_login_blocked(p_user_id uuid, p_blocked boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  update auth.users set banned_until = case when p_blocked then '2999-12-31 00:00:00+00'::timestamptz end where id = p_user_id;
  if p_blocked then
    delete from auth.sessions where user_id = p_user_id;  -- alle Geräte sofort abmelden (Refresh-Tokens fallen mit)
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public._staff_role() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._require_staff(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._audit(text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_login_blocked(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Spieler: Löschung beantragen (ersetzt das sofortige Selbst-Löschen)
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.delete_my_account() FROM authenticated;

CREATE OR REPLACE FUNCTION public.request_account_deletion(p_reason text DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from public.profiles where id = v_uid and role = 'admin') then
    raise exception 'admin_cannot_delete';
  end if;
  update public.profiles
     set status = 'deletion_requested', deletion_requested_at = now(),
         status_reason = nullif(left(trim(coalesce(p_reason, '')), 300), ''),
         status_changed_at = now(), status_changed_by = v_uid
   where id = v_uid;
  perform public._audit('deletion_requested', v_uid, (select coalesce(username, email) from public.profiles where id = v_uid), null);
  perform public._set_login_blocked(v_uid, true);
end;
$function$;
REVOKE ALL ON FUNCTION public.request_account_deletion(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(text) TO authenticated;

-- Eigene Einstellungen liefern zusätzlich Rolle + Status (Client meldet gesperrte Konten ab).
-- VOLATILE (nicht STABLE): legt im Notfall ein fehlendes Profil an – das war in 077 als STABLE markiert.
CREATE OR REPLACE FUNCTION public.get_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  select username, display_name, avatar_emoji, avatar_color, preferences, email, username_changed_at, role, status
    into r from public.profiles where id = v_uid;
  if not found then
    insert into public.profiles (id, username, email, created_at)
    select id, public._unique_username(split_part(email, '@', 1)), email, now() from auth.users where id = v_uid
    on conflict (id) do nothing;
    return jsonb_build_object('username', (select username from public.profiles where id = v_uid), 'displayName', null, 'avatarEmoji', null,
                              'avatarColor', null, 'preferences', '{}'::jsonb, 'role', 'user', 'status', 'active');
  end if;
  return jsonb_build_object(
    'username', r.username,
    'displayName', r.display_name,
    'avatarEmoji', r.avatar_emoji,
    'avatarColor', r.avatar_color,
    'preferences', coalesce(r.preferences, '{}'::jsonb),
    'usernameChangedAt', r.username_changed_at,
    'role', r.role,
    'status', r.status
  );
end;
$function$;

-- ------------------------------------------------------------
-- Playlists: nur Musik-Playlists, leerer Filter = alle
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._vote_topic_pool(p_filter text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(t.text), '{}')
  from public.topic_pool t
  where t.active is true and t.is_song_category is true
    and (p_filter is null or cardinality(p_filter) = 0 or t.text = any(p_filter));
$function$;

CREATE OR REPLACE FUNCTION public.set_lobby_topic_filter(p_lobby_id uuid, p_me_player_id uuid, p_categories text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

  -- Nur echte, aktive Musik-Playlists übernehmen; nichts ausgewählt = alle (NULL).
  select coalesce(array_agg(distinct tp.text), '{}')
    into v_clean
  from public.topic_pool tp
  where tp.active is true and tp.is_song_category is true and tp.text = any(coalesce(p_categories, '{}'));

  update public.lobbies
  set topic_filter = nullif(v_clean, '{}'),
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

-- Alle Musik-Playlists mit Songanzahl (für die Auswahl in Host/Lobby/Profil)
CREATE OR REPLACE FUNCTION public.get_song_playlists()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('name', t.text, 'songs', t.n) order by t.text), '[]'::jsonb)
  from (
    select tp.text, count(sp.id)::int as n
    from public.topic_pool tp
    left join public.song_pool sp on sp.topic_pool_id = tp.id
    where tp.active is true and tp.is_song_category is true
    group by tp.text
  ) t;
$function$;
GRANT EXECUTE ON FUNCTION public.get_song_playlists() TO anon, authenticated;

-- Vorlieben: zusätzlich host.excludedPlaylists (rausgenommene Playlists; neue Playlists sind automatisch drin)
CREATE OR REPLACE FUNCTION public.set_my_preferences(p_prefs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  p jsonb := coalesce(p_prefs, '{}'::jsonb);
  h jsonb := coalesce(p_prefs -> 'host', '{}'::jsonb);
  s jsonb := coalesce(p_prefs -> 'solo', '{}'::jsonb);
  out jsonb := '{}'::jsonb;
  host_out jsonb := '{}'::jsonb;
  solo_out jsonb := '{}'::jsonb;
  v_ex jsonb;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'prefs_invalid'; end if;

  if p ->> 'lang' in ('de', 'en') then out := out || jsonb_build_object('lang', p ->> 'lang'); end if;
  if jsonb_typeof(p -> 'muted') = 'boolean' then out := out || jsonb_build_object('muted', (p ->> 'muted')::boolean); end if;
  if jsonb_typeof(p -> 'volume') = 'number' and (p ->> 'volume')::numeric between 0 and 1 then
    out := out || jsonb_build_object('volume', round((p ->> 'volume')::numeric, 2));
  end if;

  if jsonb_typeof(h -> 'maxPlayers') = 'number' and (h ->> 'maxPlayers')::numeric between 2 and 12 then
    host_out := host_out || jsonb_build_object('maxPlayers', (h ->> 'maxPlayers')::numeric::int);
  end if;
  if h ->> 'speed' in ('fast', 'normal', 'calm') then host_out := host_out || jsonb_build_object('speed', h ->> 'speed'); end if;
  if h ->> 'rounds' in ('1', '3', '5') then host_out := host_out || jsonb_build_object('rounds', (h ->> 'rounds')::int); end if;
  if h ->> 'answerMode' in ('text', 'voice') then host_out := host_out || jsonb_build_object('answerMode', h ->> 'answerMode'); end if;
  if jsonb_typeof(h -> 'excludedPlaylists') = 'array' then
    select coalesce(jsonb_agg(distinct tp.text), '[]'::jsonb) into v_ex
    from public.topic_pool tp
    where tp.is_song_category is true
      and tp.text in (select jsonb_array_elements_text(h -> 'excludedPlaylists'));
    host_out := host_out || jsonb_build_object('excludedPlaylists', v_ex);
  end if;
  if host_out <> '{}'::jsonb then out := out || jsonb_build_object('host', host_out); end if;

  if jsonb_typeof(s -> 'bots') = 'number' and (s ->> 'bots')::numeric between 1 and 5 then
    solo_out := solo_out || jsonb_build_object('bots', (s ->> 'bots')::numeric::int);
  end if;
  if s ->> 'skill' in ('mixed', '1', '2', '3') then solo_out := solo_out || jsonb_build_object('skill', s ->> 'skill'); end if;
  if solo_out <> '{}'::jsonb then out := out || jsonb_build_object('solo', solo_out); end if;

  update public.profiles set preferences = out where id = v_uid;
  return out;
end;
$function$;

-- ------------------------------------------------------------
-- Admin-Panel: Übersicht / Nutzer
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_whoami()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r text := public._require_staff('supporter');
begin
  return jsonb_build_object(
    'role', r,
    'counts', jsonb_build_object(
      'users', (select count(*) from auth.users),
      'deletionRequests', (select count(*) from public.profiles where status = 'deletion_requested'),
      'suspended', (select count(*) from public.profiles where status = 'suspended'),
      'staff', (select count(*) from public.profiles where role in ('admin', 'supporter')),
      'activeLobbies', (select count(*) from public.lobbies where last_activity_at > now() - interval '30 minutes'),
      'runningGames', (select count(*) from public.lobbies where phase in ('topic_vote', 'countdown', 'running', 'set_summary')),
      'newUsers7d', (select count(*) from auth.users where created_at > now() - interval '7 days')
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_users(p_search text DEFAULT NULL, p_filter text DEFAULT 'all', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(x) from (
      select u.id, p.username, p.display_name as "displayName", p.avatar_emoji as "avatarEmoji", p.avatar_color as "avatarColor",
             coalesce(p.role, 'user') as role, coalesce(p.status, 'active') as status, p.status_reason as "statusReason",
             p.deletion_requested_at as "deletionRequestedAt", u.email, u.created_at as "createdAt",
             u.last_sign_in_at as "lastSignInAt", (u.email_confirmed_at is not null) as confirmed,
             (select count(*) from public.account_matches m where m.user_id = u.id)::int as matches
      from auth.users u
      left join public.profiles p on p.id = u.id
      where (v_q is null
             or p.username ilike '%' || v_q || '%'
             or p.display_name ilike '%' || v_q || '%'
             or u.email ilike '%' || v_q || '%'
             or u.id::text = v_q)
        and (coalesce(p_filter, 'all') = 'all'
             or (p_filter = 'deletion' and p.status = 'deletion_requested')
             or (p_filter = 'suspended' and p.status = 'suspended')
             or (p_filter = 'staff' and p.role in ('admin', 'supporter')))
      order by (p.status = 'deletion_requested') desc nulls last, u.created_at desc
      limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(0, coalesce(p_offset, 0))
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_user(p_user_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return (
    select jsonb_build_object(
      'id', u.id, 'email', u.email, 'createdAt', u.created_at, 'lastSignInAt', u.last_sign_in_at,
      'confirmed', u.email_confirmed_at is not null, 'bannedUntil', u.banned_until,
      'username', p.username, 'displayName', p.display_name, 'avatarEmoji', p.avatar_emoji, 'avatarColor', p.avatar_color,
      'role', coalesce(p.role, 'user'), 'status', coalesce(p.status, 'active'), 'statusReason', p.status_reason,
      'statusChangedAt', p.status_changed_at, 'deletionRequestedAt', p.deletion_requested_at,
      'stats', jsonb_build_object(
        'matches', (select count(*) from public.account_matches where user_id = u.id),
        'matchWins', (select count(*) from public.account_matches where user_id = u.id and place = 1 and ranked),
        'rounds', (select count(*) from public.account_rounds where user_id = u.id),
        'titles', (select coalesce(sum(title_hits), 0) from public.account_rounds where user_id = u.id),
        'achievements', (select count(*) from public.player_achievements where user_id = u.id),
        'lastPlayed', (select max(finished_at) from public.account_matches where user_id = u.id)
      ),
      'audit', coalesce((
        select jsonb_agg(a order by a.created_at desc) from (
          select created_at, actor_name, action, details from public.admin_audit
          where target_id = u.id order by created_at desc limit 20
        ) a
      ), '[]'::jsonb)
    )
    from auth.users u left join public.profiles p on p.id = u.id
    where u.id = p_user_id
  );
end;
$function$;

-- Sperren / Entsperren / Löschantrag ablehnen
CREATE OR REPLACE FUNCTION public.admin_set_user_status(p_user_id uuid, p_status text, p_reason text DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  me text := public._require_staff('supporter');
  t record;
begin
  if p_status not in ('active', 'suspended') then raise exception 'status_invalid'; end if;
  if p_user_id = auth.uid() then raise exception 'not_on_self'; end if;
  select coalesce(p.role, 'user') as role, coalesce(p.status, 'active') as status, coalesce(p.username, u.email) as label
    into t from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  if t.role <> 'user' and me <> 'admin' then raise exception 'not_authorized'; end if;  -- Supporter dürfen kein Team-Konto sperren

  update public.profiles
     set status = p_status,
         status_reason = case when p_status = 'active' then null else nullif(left(trim(coalesce(p_reason, '')), 300), '') end,
         deletion_requested_at = case when p_status = 'active' then null else deletion_requested_at end,
         status_changed_at = now(), status_changed_by = auth.uid()
   where id = p_user_id;
  perform public._set_login_blocked(p_user_id, p_status <> 'active');
  perform public._audit(
    case when p_status = 'active' then (case when t.status = 'deletion_requested' then 'deletion_rejected' else 'unsuspended' end) else 'suspended' end,
    p_user_id, t.label, jsonb_build_object('reason', p_reason, 'previous', t.status));
end;
$function$;

-- Endgültig löschen (nur Admin, nie Team-Konten, nie sich selbst)
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare t record;
begin
  perform public._require_staff('admin');
  if p_user_id = auth.uid() then raise exception 'not_on_self'; end if;
  select coalesce(p.role, 'user') as role, coalesce(p.status, 'active') as status, coalesce(p.username, u.email) as label, u.email
    into t from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  if t.role <> 'user' then raise exception 'staff_cannot_be_deleted'; end if;
  perform public._audit('deleted', p_user_id, t.label, jsonb_build_object('status', t.status, 'email', t.email));
  delete from auth.users where id = p_user_id;  -- Profil, Verlauf, Achievements, Freunde per CASCADE
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_role(p_user_id uuid, p_role text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare t record;
begin
  perform public._require_staff('admin');
  if p_role not in ('user', 'supporter', 'admin') then raise exception 'role_invalid'; end if;
  if p_user_id = auth.uid() then raise exception 'not_on_self'; end if;  -- verhindert, dass man sich selbst aussperrt
  select coalesce(role, 'user') as role, coalesce(username, email) as label into t from public.profiles where id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  update public.profiles set role = p_role, is_platform_admin = (p_role = 'admin') where id = p_user_id;
  perform public._audit('role_changed', p_user_id, t.label, jsonb_build_object('from', t.role, 'to', p_role));
end;
$function$;

-- Moderation: Benutzername ändern, Spielername/Avatar zurücksetzen
CREATE OR REPLACE FUNCTION public.admin_update_user_profile(p_user_id uuid, p_username text DEFAULT NULL, p_reset_display_name boolean DEFAULT false, p_reset_avatar boolean DEFAULT false)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  me text := public._require_staff('supporter');
  t record;
  v text := nullif(public.normalize_username(coalesce(p_username, '')), '');
begin
  select coalesce(role, 'user') as role, coalesce(username, email) as label, username into t from public.profiles where id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  if t.role <> 'user' and me <> 'admin' then raise exception 'not_authorized'; end if;
  if v is not null and v is distinct from t.username then
    if not public._valid_username(v) then raise exception 'username_invalid'; end if;
    if exists (select 1 from public.profiles where lower(username) = v and id <> p_user_id) then raise exception 'username_taken'; end if;
    update public.profiles set username = v, username_changed_at = now() where id = p_user_id;
  end if;
  if p_reset_display_name then update public.profiles set display_name = null where id = p_user_id; end if;
  if p_reset_avatar then update public.profiles set avatar_emoji = null, avatar_color = null where id = p_user_id; end if;
  perform public._audit('profile_moderated', p_user_id, t.label,
    jsonb_build_object('username', v, 'resetDisplayName', p_reset_display_name, 'resetAvatar', p_reset_avatar));
end;
$function$;

-- Für den Passwort-Reset aus dem Panel: E-Mail eines Nutzers (wird im Panel ohnehin angezeigt) + Protokoll
CREATE OR REPLACE FUNCTION public.admin_log_password_reset(p_user_id uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_email text; v_label text;
begin
  perform public._require_staff('supporter');
  select u.email, coalesce(p.username, u.email) into v_email, v_label from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;
  if v_email is null then raise exception 'user_not_found'; end if;
  perform public._audit('password_reset_sent', p_user_id, v_label, null);
  return v_email;
end;
$function$;

-- ------------------------------------------------------------
-- Lobbys
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_lobbies()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(x order by x."lastActivityAt" desc) from (
      select l.id, l.code, l.phase, l.locked, l.created_at as "createdAt", l.last_activity_at as "lastActivityAt",
             l.series_index as "roundIndex", l.series_total as "roundsTotal", l.topic_selected as playlist,
             (select name from public.players h where h.lobby_id = l.id and h.player_id = l.host_player_id) as host,
             (select count(*) from public.players p where p.lobby_id = l.id and p.status = 'active' and not coalesce(p.is_bot, false))::int as humans,
             (select count(*) from public.players p where p.lobby_id = l.id and p.status = 'active' and coalesce(p.is_bot, false))::int as bots,
             (select count(*) from public.players p where p.lobby_id = l.id and p.status = 'active' and p.user_id is not null)::int as accounts
      from public.lobbies l
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_close_lobby(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_code text;
begin
  perform public._require_staff('supporter');
  select code into v_code from public.lobbies where id = p_lobby_id;
  if v_code is null then raise exception 'lobby_not_found'; end if;
  perform public._audit('lobby_closed', null, v_code, jsonb_build_object('lobbyId', p_lobby_id));
  delete from public.lobbies where id = p_lobby_id;  -- Spieler etc. per CASCADE; Clients sehen "Lobby nicht gefunden"
end;
$function$;

-- ------------------------------------------------------------
-- Songs (nur Admin): archivieren statt löschen -> wird nie mehr gezogen, jederzeit zurückholbar
-- ------------------------------------------------------------
INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Archiv (deaktivierte Songs)', false, false
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)');

CREATE OR REPLACE FUNCTION public.admin_list_songs(p_playlist text DEFAULT NULL, p_search text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform public._require_staff('admin');
  return coalesce((
    select jsonb_agg(x order by x.playlist, x.rate nulls last, x.title) from (
      select sp.id, sp.title, sp.artist, tp.text as playlist, sp.archived_from as "archivedFrom", sp.plays, sp.hits,
             case when sp.plays > 0 then round(100.0 * sp.hits / sp.plays) end as rate
      from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id
      where (tp.is_song_category is true or sp.archived_from is not null)
        and (p_playlist is null or tp.text = p_playlist or sp.archived_from = p_playlist)
        and (v_q is null or sp.title ilike '%' || v_q || '%' or sp.artist ilike '%' || v_q || '%')
      limit 500
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_song_archived(p_song_id uuid, p_archived boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare s record; v_archive uuid; v_target uuid;
begin
  perform public._require_staff('admin');
  select sp.title, sp.artist, sp.archived_from, tp.text as playlist into s
  from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id where sp.id = p_song_id;
  if not found then raise exception 'song_not_found'; end if;
  select id into v_archive from public.topic_pool where text = 'Archiv (deaktivierte Songs)';
  if p_archived then
    if s.archived_from is not null then return; end if;
    update public.song_pool set archived_from = s.playlist, topic_pool_id = v_archive where id = p_song_id;
  else
    if s.archived_from is null then return; end if;
    select id into v_target from public.topic_pool where text = s.archived_from;
    if v_target is null then raise exception 'playlist_missing'; end if;
    update public.song_pool set archived_from = null, topic_pool_id = v_target where id = p_song_id;
  end if;
  perform public._audit(case when p_archived then 'song_archived' else 'song_restored' end, null,
    s.title || ' – ' || s.artist, jsonb_build_object('playlist', coalesce(s.archived_from, s.playlist)));
end;
$function$;

-- ------------------------------------------------------------
-- Protokoll
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_audit(p_limit integer DEFAULT 100)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(a order by a."createdAt" desc) from (
      select id, created_at as "createdAt", actor_name as "actorName", action, target_id as "targetId", target_label as "targetLabel", details
      from public.admin_audit order by created_at desc limit greatest(1, least(coalesce(p_limit, 100), 500))
    ) a
  ), '[]'::jsonb);
end;
$function$;

-- Rechte: alle admin_* nur für eingeloggte (Prüfung der Rolle passiert in der Funktion)
DO $$
declare f text;
begin
  foreach f in array array[
    'admin_whoami()', 'admin_list_users(text, text, integer, integer)', 'admin_get_user(uuid)',
    'admin_set_user_status(uuid, text, text)', 'admin_delete_user(uuid)', 'admin_set_role(uuid, text)',
    'admin_update_user_profile(uuid, text, boolean, boolean)', 'admin_log_password_reset(uuid)',
    'admin_list_lobbies()', 'admin_close_lobby(uuid)', 'admin_list_songs(text, text)',
    'admin_set_song_archived(uuid, boolean)', 'admin_list_audit(integer)'
  ] loop
    execute format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    execute format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  end loop;
end $$;

-- ------------------------------------------------------------
-- profiles.username ist Pflicht (NOT NULL): bei vergebenem/ungültigem Wunschnamen
-- automatisch einen freien Namen vergeben (z. B. "spieler4821"), statt die Registrierung
-- scheitern zu lassen. Der Name lässt sich danach im Profil ändern.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._unique_username(p_base text)
 RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  b text := left(regexp_replace(public.normalize_username(coalesce(p_base, '')), '[^a-z0-9._-]', '', 'g'), 14);
  c text;
  i int := 0;
begin
  if not public._valid_username(b) or public._is_profane(b) then b := 'spieler'; end if;
  c := b;
  while exists (select 1 from public.profiles where lower(username) = c) loop
    i := i + 1;
    c := b || (1000 + floor(random() * 9000))::int::text;
    if i > 50 then c := 'spieler' || floor(random() * 100000000)::bigint::text; end if;
  end loop;
  return c;
end;
$function$;
REVOKE ALL ON FUNCTION public._unique_username(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_username text := nullif(public.normalize_username(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if v_username is null
     or not public._valid_username(v_username)
     or public._is_profane(v_username)
     or exists (select 1 from public.profiles p where lower(p.username) = v_username and p.id <> new.id) then
    v_username := public._unique_username(coalesce(v_username, split_part(new.email, '@', 1)));
  end if;

  insert into public.profiles (id, username, email, created_at)
  values (new.id, v_username, new.email, now())
  on conflict (id) do update set
    email = coalesce(excluded.email, public.profiles.email);

  return new;
end;
$function$;

COMMIT;

-- >>> 079_deutschrap_aktuell.sql <<<
-- Generiert von db/scripts/build-deutschrap.mjs (2026-10-06)
-- Playlist "Deutschrap aktuell": 240 Songs seit 2022-10-06, Beliebtheit laut Deezer, Vorschau/Datum laut iTunes
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap aktuell', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap aktuell');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Gut Genug', 'KITSCHKRIEG, Blumengarten & Shirin David', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9d/1a/c7/9d1ac7fb-4f41-b49d-566a-dc88ca1be86d/mzaf_11071714867058821724.plus.aac.p.m4a'),
    ('Porzellan', 'Kontra K & NESS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/69/39/04/693904af-52fb-386b-c9ef-840f243e4a52/mzaf_13745215967692581806.plus.aac.p.m4a'),
    ('Verschwommen', 'Ski Aggu & Ericson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bf/8c/f8/bf8cf884-8a45-363a-34d3-646414b5e629/mzaf_4888429572532983792.plus.aac.p.m4a'),
    ('Inundauswendig', 'makko & The Chainsmokers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/48/b9/ac/48b9ac31-3bc6-83ff-5175-ce7ab3262edf/mzaf_1629216403122461481.plus.aac.p.m4a'),
    ('Fata Morgana', 'Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e4/4c/c2/e44cc297-38bc-54dc-4885-fc082d006237/mzaf_3434201997175103673.plus.aac.p.m4a'),
    ('Ms. Jackson', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/2a/f7/3f/2af73f29-291b-bf3c-368d-8916c904c69b/mzaf_294562369076133843.plus.aac.p.m4a'),
    ('Wenn das Liebe ist', 'Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/60/5e/4d/605e4de9-d23d-3962-2a56-b56c8e9abccd/mzaf_7259883427764745208.plus.aac.p.m4a'),
    ('Bauch Beine Po', 'Shirin David', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/40/0c/06/400c06d1-c60d-d88a-74d2-64c2a3763ecb/mzaf_11253638869592011591.plus.aac.p.m4a'),
    ('Mittelmeer', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c1/cd/33/c1cd33cc-c718-5a4b-2bfe-06655f316444/mzaf_11466832732093531899.plus.aac.p.m4a'),
    ('Adrenalin 2.0', 'Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/88/9f/10/889f109f-00fd-ad26-fcaf-d291b1c00e6c/mzaf_10224991738305173916.plus.aac.p.m4a'),
    ('9 bis 9', 'SIRA, Bausa & badchieff', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/02/e9/2b/02e92b13-c166-bada-125f-71e6d456afcb/mzaf_2449515519834266891.plus.aac.p.m4a'),
    ('Du liebst mich nicht', 'Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c7/bb/f9/c7bbf9bc-4228-2550-5108-b4965607d8ee/mzaf_8743775124680988454.plus.aac.p.m4a'),
    ('Mein Leben', 'Milonair, Kool Savas & 1986zig', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b0/25/d6/b025d647-40a6-70fd-ec5a-ffdb3d76c29f/mzaf_16168988464388679062.plus.aac.p.m4a'),
    ('Chaos', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/3b/3f/5a3b3f8b-e370-5a97-d806-cbf95d77b3c9/mzaf_15555307926128862577.plus.aac.p.m4a'),
    ('Seite an Seite', 'Gzuz, Sido & JBS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/be/a2/5abea297-e1e3-cfc7-19b9-63f3e7a594d6/mzaf_17474436214410174220.plus.aac.p.m4a'),
    ('Unsicher', 'Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8a/08/24/8a0824dd-415c-c662-6a1c-f5997e8090a6/mzaf_13190071927585873340.plus.aac.p.m4a'),
    ('Stille Kämpfe', 'NESS & Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1b/70/12/1b7012ae-c85c-9c75-42ce-959f2d05daf9/mzaf_8412258602555781707.plus.aac.p.m4a'),
    ('Geboren um zu leben', 'Kontra K & NESS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e1/06/17/e10617f0-45d1-34a3-1f7a-3587a6bea1f7/mzaf_9407329305232413418.plus.aac.p.m4a'),
    ('Miami', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c5/1b/48/c51b4815-77f4-c6db-9688-1aaa10cce30b/mzaf_2294655937865324949.plus.aac.p.m4a'),
    ('NINA', 'Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/66/93/ec66930f-9f9e-4b47-fd54-94d844c090ad/mzaf_5743344748476458737.plus.aac.p.m4a'),
    ('Breaking your heart', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/96/e7/02/96e702d6-1166-5275-fc58-38eb199456c6/mzaf_10767789362673437085.plus.aac.p.m4a'),
    ('Morgen', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ed/fc/04/edfc04e8-6686-9b48-ad87-5e61b83cd828/mzaf_7976620730799509042.plus.aac.p.m4a'),
    ('Heb ab', 'Miami Yacine & Nash', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/96/4b/93/964b9392-fceb-1702-3513-d370971172cd/mzaf_3561495639029066177.plus.aac.p.m4a'),
    ('Niemals', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/44/b3/fe/44b3fee5-c732-b2db-4fe2-7d911219e0b3/mzaf_13839186796549365331.plus.aac.p.m4a'),
    ('Sonne geht auf', 'Klangkuenstler & Ski Aggu', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/25/fc/f9/25fcf95f-f908-5cac-500d-2e38a986fc32/mzaf_10055703047460517308.plus.aac.p.m4a'),
    ('Sera', 'Monet192 & Morpheuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6b/b0/c6/6bb0c6e3-0a1c-fdf1-b840-85aad56ec321/mzaf_2552833689754388946.plus.aac.p.m4a'),
    ('Siamo Tutti', 'Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6f/9a/e2/6f9ae2c3-49b0-d2b4-fedb-7ab2114bcfa7/mzaf_3013218681037788806.plus.aac.p.m4a'),
    ('wie du manchmal fehlst', 'Zartmann, Ski Aggu & Dauner', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b9/1a/e8/b91ae8cc-31ab-7b2c-0034-41b3310bc3f2/mzaf_2423422106350016622.plus.aac.p.m4a'),
    ('LICHTER AUS', 'makko & Miksu / Macloud', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1a/bb/5d/1abb5db4-6b88-f0ed-9629-046c58e1e711/mzaf_6984748052884293392.plus.aac.p.m4a'),
    ('SABÍA QUE NO', 'reezy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7a/8a/00/7a8a0064-85a6-a677-7184-ced3a3721b0c/mzaf_9845888720648186930.plus.aac.p.m4a'),
    ('3 Uhr Nachts', 'Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/48/15/ef/4815ef04-021f-7720-ba6f-2574ffd59516/mzaf_17798370620895464801.plus.aac.p.m4a'),
    ('Geschlossene Augen', 'SANTOS & Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/72/9f/7b/729f7b5a-1c67-e776-ba57-c583b5478a20/mzaf_8482383590484032979.plus.aac.p.m4a'),
    ('Glaubst du nicht auch', 'Montez & benno!', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c0/d6/78/c0d678af-1627-e5e6-233d-e73c9ef19857/mzaf_7322820852338695723.plus.aac.p.m4a'),
    ('Summertime', 'Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/da/37/cb/da37cb51-738f-7660-ef29-a9c6d5a0fc0b/mzaf_14689037774858078423.plus.aac.p.m4a'),
    ('Fliegen', 'Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/58/35/fc/5835fc11-6677-1a04-2c68-ca81037560c4/mzaf_8818190584931767983.plus.aac.p.m4a'),
    ('Herzensmensch', 'Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/93/3b/45/933b458d-5b17-edb3-aadc-9b34ee0ad40a/mzaf_13642646097106439366.plus.aac.p.m4a'),
    ('Anders', '01099, Paul & Ski Aggu', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/cf/d1/94/cfd1949f-c4b2-ae0e-a76c-3afcee799bf5/mzaf_10662486572971687182.plus.aac.p.m4a'),
    ('Wolke 4', 'Bausa & Philipp Dittberner', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/98/d9/09/98d909af-7201-6096-e6cb-07a1bdc2ea0f/mzaf_11895189561437217440.plus.aac.p.m4a'),
    ('Abschied nehmen', 'Miksu / Macloud, Ufo361 & Trettmann', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d0/19/7d/d0197dd1-19c8-dd98-a346-e9e768510483/mzaf_27521769021213406.plus.aac.p.m4a'),
    ('Was weißt du schon', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/f1/12/4cf112c9-9542-a5c3-1a15-670df740252c/mzaf_14031678196973356104.plus.aac.p.m4a'),
    ('Loser', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5d/70/e4/5d70e4ff-9d84-274d-653e-ece6da7990e2/mzaf_11480468985571129709.plus.aac.p.m4a'),
    ('Mann muss', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/19/ec/9019ec13-9bb5-3f5f-6a10-3d8a0e65ffbb/mzaf_9428726307364356336.plus.aac.p.m4a'),
    ('Wer liebt dich jetzt?', 'SANTOS & Shirin David', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/21/ef/77/21ef773f-1521-554e-9382-f83d0ecae2e5/mzaf_8613022754343284356.plus.aac.p.m4a'),
    ('mietfrei', 'Ski Aggu & SIRA', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b5/4c/eb/b54cebdd-820b-3645-02c8-1843b95aeddc/mzaf_9580286508681835921.plus.aac.p.m4a'),
    ('Panzer', 'Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/53/56/bb/5356bb40-9bc2-7ee2-d2a2-eae799a5e57c/mzaf_17117219345529140574.plus.aac.p.m4a'),
    ('Bisschen kaputt', 'Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/98/7f/c8/987fc8d0-061d-5d45-28fe-2df939b9a412/mzaf_14309518196377176511.plus.aac.p.m4a'),
    ('Fallen in Liebe', 'Kraftklub & Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/2a/73/b6/2a73b6d3-3b23-7e6d-f615-2f466327a3b5/mzaf_6376487067152467491.plus.aac.p.m4a'),
    ('Wenn du mich fragst', 'Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/90/6f/75/906f759f-66ae-d2a6-bef1-f21e02ba7c5c/mzaf_15412137686471298836.plus.aac.p.m4a'),
    ('Randali', 'Chapo102 & Nina Chuba', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ba/89/ac/ba89ac06-5083-67e6-56b1-a39aab1c3139/mzaf_7875020477834356039.plus.aac.p.m4a'),
    ('Gift', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/44/81/f9/4481f964-0b7f-94e0-35d7-565d86a6a57c/mzaf_13676693610091644511.plus.aac.p.m4a'),
    ('Deutsche & Kanaken', 'Lupo Kadafi, Gzuz & Don Alfonso', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e2/fe/01/e2fe0135-e797-7bf8-d3e6-5ead76a8d31b/mzaf_14097492907906165785.plus.aac.p.m4a'),
    ('Kalter Krieg', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c8/d3/15/c8d315a3-3809-23c2-5d20-722fe9fd0757/mzaf_9027970081424340429.plus.aac.p.m4a'),
    ('Liebst du mich', 'Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5f/b9/50/5fb9502e-7996-c74b-0737-191308af4913/mzaf_4061295676032510236.plus.aac.p.m4a'),
    ('Cold as Ice', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/54/3a/94/543a94c5-270a-a542-0b99-98b617ce825b/mzaf_9177537511829347062.plus.aac.p.m4a'),
    ('erstersommerohnedich', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/4e/71/2d/4e712de0-8df8-7401-72cf-70c7f35b8d10/mzaf_17239724651625407627.plus.aac.p.m4a'),
    ('Starboy', 'Luciano & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bc/dd/b5/bcddb5ad-25b3-a5eb-d151-92d5aa72236d/mzaf_11953846642540958986.plus.aac.p.m4a'),
    ('Boss Green', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/12/73/f0/1273f0a9-3cbf-30af-f5aa-ec2b1e0c6215/mzaf_6347397956660115687.plus.aac.p.m4a'),
    ('Blue Porsche', 'Luciano & Niska', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c3/03/04/c3030497-71ce-9419-6e17-9247790757e0/mzaf_662272406190326409.plus.aac.p.m4a'),
    ('Das Leben ruft', 'SANTOS & Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5e/cd/09/5ecd09df-27b7-4d49-5dbf-2beceba68ee4/mzaf_5693835237996222563.plus.aac.p.m4a'),
    ('tempo', 'Sampagne, badchieff & CRO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/7c/08/ed/7c08ed81-d964-414a-401e-ef3343edb018/mzaf_4357345807541363084.plus.aac.p.m4a'),
    ('Überfall', 'Montez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/16/37/6c/16376cd5-c3fe-ac34-4e08-859b818fee10/mzaf_1856355464926081602.plus.aac.p.m4a'),
    ('CONNECTED', 'RAF Camora & reezy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5e/69/15/5e6915d3-b776-a840-916e-e8b4f2b2cf37/mzaf_11291496925532574361.plus.aac.p.m4a'),
    ('Bagchaser Can', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/54/e0/c654e0d0-90f9-3b6a-2fb2-f6ba2462aba6/mzaf_4691043868260671611.plus.aac.p.m4a'),
    ('Airplanes', 'badmómzjay & Kool Savas', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d8/b9/fb/d8b9fb1c-972e-52bf-576e-333bd5d9ae89/mzaf_12419201844840696248.plus.aac.p.m4a'),
    ('Liebe ist ein Dieb', 'Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0b/d5/7c/0bd57c12-e19e-8e6d-14b2-d5a7746c4339/mzaf_878484346853559415.plus.aac.p.m4a'),
    ('Count your blessings', 'Sa4 & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d2/af/44/d2af4402-ce9f-b9bf-7610-d99282427cb5/mzaf_3905975321627425060.plus.aac.p.m4a'),
    ('OCEAN', 'RAF Camora & Ufo361', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/ac/66/dfac669a-9c2d-0b4c-86b6-70f8d97b8476/mzaf_12513037025792429953.plus.aac.p.m4a'),
    ('Maradona', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/70/78/3e/70783e4c-0ee5-a498-3de8-175fdc909179/mzaf_12449780446517498820.plus.aac.p.m4a'),
    ('RondoNumbaNine', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bb/7a/0d/bb7a0d77-12a6-edf4-fe9d-6fa4a6510dc8/mzaf_6282613174733622030.plus.aac.p.m4a'),
    ('Moonlight Dreams', 'YAKARY & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/50/19/20/50192055-4ae8-5949-7542-9b10239c0782/mzaf_17242896264389125404.plus.aac.p.m4a'),
    ('so heiß', '01099 & CRO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/88/f7/93/88f793d3-85d8-b6dd-a5bc-f5922fd7f00c/mzaf_16899593750433088719.plus.aac.p.m4a'),
    ('Keine Helden', 'Kontra K & SDP', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9d/d6/67/9dd66777-f121-e419-56a2-f61cd87a9293/mzaf_4056555212515593402.plus.aac.p.m4a'),
    ('schwarzer toyota', 'skrt cobain, Mark Forster & Ski Aggu', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/3d/22/4b/3d224b61-d514-587e-f71c-9fd84583fc8d/mzaf_3581718853474504087.plus.aac.p.m4a'),
    ('All Night', 'Luciano & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/47/bf/0e/47bf0e37-81e8-ecab-d6b6-3dbc016f21c6/mzaf_17394255442885241084.plus.aac.p.m4a'),
    ('Wenn Du Mich Vergisst', 'Mark Forster & Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d9/8d/1b/d98d1b32-8ac0-5bf0-6bfb-7c647f8b6101/mzaf_4883425644321434790.plus.aac.p.m4a'),
    ('Hinter den Kulissen', 'Shindy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/97/9c/6d/979c6d29-c25f-e8d7-2a65-ca543e240745/mzaf_6883108174636372586.plus.aac.p.m4a'),
    ('QUALITÄT', 'Sonus030 & AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/50/cc/55/50cc5540-27da-7df3-0504-917104a66a9f/mzaf_8507909491805445600.plus.aac.p.m4a'),
    ('Ich bring dir keine Blumen', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/46/e0/7b/46e07b3f-6db0-05d6-ee5f-6f6235268f84/mzaf_9947818941896906192.plus.aac.p.m4a'),
    ('Another Vibe', 'Luciano & OMAH LAY', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/79/34/ad/7934ad7c-6673-f7cd-db0b-b3e2d52e2153/mzaf_15466577134704794977.plus.aac.p.m4a'),
    ('Pa Mu', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/3a/f6/c63af622-f445-b3e5-c112-1cd7ac6a8e7f/mzaf_3790178152675825614.plus.aac.p.m4a'),
    ('Wenn der Himmel weint', 'Bausa & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b0/5b/83/b05b8329-32c6-e042-71d6-95fd02e4cd4f/mzaf_17672995787847521681.plus.aac.p.m4a'),
    ('Schlaf', 'BUNT. & Bausa', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8a/77/75/8a777566-039c-e9c2-5745-08508d8334fa/mzaf_681973870751065250.plus.aac.p.m4a'),
    ('MOUNT OLYMPUS', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fd/d7/02/fdd70222-f8e9-c4cd-a5a6-24d54399bb46/mzaf_17064011775218990603.plus.aac.p.m4a'),
    ('APRES SKI', 'Tream & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/bc/92/92/bc929291-9570-b23f-54a9-97fa9ca5bee5/mzaf_10615365935077484116.plus.aac.p.m4a'),
    ('VACATION', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/57/c4/e5/57c4e5a5-084d-3133-5f06-49c40fd60a43/mzaf_17719970761118631110.plus.aac.p.m4a'),
    ('Narben', 'Kontra K & Anna Grey', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0b/77/ea/0b77eae2-6e60-aea3-ccd4-36b09f4f1113/mzaf_3992708533927282232.plus.aac.p.m4a'),
    ('Flasche kreist', '01099 & Ski Aggu', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d2/82/4f/d2824fd3-bc6f-6f7c-faae-181d62d125c6/mzaf_16294471615927821814.plus.aac.p.m4a'),
    ('Gesegnet', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ea/5b/73/ea5b7364-d204-2ca2-ae7e-729246e92f1f/mzaf_7356541788179685318.plus.aac.p.m4a'),
    ('nie wieder normal', 'CRO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ad/49/7b/ad497bf7-5eb3-0eec-3b80-8bfa380cefb9/mzaf_488893895131206172.plus.aac.p.m4a'),
    ('Plug', 'Monet192 & Morpheuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/de/2b/4a/de2b4a51-7148-9841-5d5c-90a081e7ba66/mzaf_14584971965753249554.plus.aac.p.m4a'),
    ('HOLD ME DOWN', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ad/f3/69/adf3699b-0c2d-0a93-84ac-dd403485c236/mzaf_11582948286059152582.plus.aac.p.m4a'),
    ('Ich Liebe Dich', 'Samra & Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ad/ee/30/adee30bf-2313-1314-4f15-88648ac72162/mzaf_479953202844730391.plus.aac.p.m4a'),
    ('Nur die Nacht', 'Kool Savas', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/86/5c/ce/865ccefb-f39a-d280-96df-55960c68570d/mzaf_9352879442123479200.plus.aac.p.m4a'),
    ('2 Germans', 'Luciano & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f3/d9/5f/f3d95f31-2c0a-98b0-16a8-0adeca3c71d5/mzaf_8928989082293985026.plus.aac.p.m4a'),
    ('nimm mit', 'Paula Hartmann & makko', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3c/9b/9a/3c9b9a35-2779-eaad-6084-8f9de16cdc7c/mzaf_9564608667756975318.plus.aac.p.m4a'),
    ('Berlin', 'Kool Savas & Kaiserbase', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b8/fc/2d/b8fc2d0f-a618-ac5b-60d4-a5d88116523a/mzaf_3628957481198177500.plus.aac.p.m4a'),
    ('Malli', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/63/c3/df63c3a6-c4ac-ce85-ea3e-4af63b069230/mzaf_15135499478839051035.plus.aac.p.m4a'),
    ('Nie', 'Tom Hengst & Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f8/43/9d/f8439dbe-784d-3643-dea4-7a3382c71ea4/mzaf_8947531899469189754.plus.aac.p.m4a'),
    ('LOWLIFE', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/95/fb/34/95fb340c-e2df-4d30-d41e-9e0644955e7f/mzaf_1348284490872911620.plus.aac.p.m4a'),
    ('Liebe in Stereo', 'Baby B3ns & Yung Hurn', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b9/f5/cf/b9f5cfe2-6205-740f-38d9-4626738983b6/mzaf_17750551988276817278.plus.aac.p.m4a'),
    ('Gib uns niemals auf', 'Hava & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/49/7f/be/497fbefc-57c9-abd7-c3da-5e11cd4d3a88/mzaf_3320579638543591468.plus.aac.p.m4a'),
    ('Simpel', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/60/8f/48/608f48bc-6597-e943-b484-6da8193f2117/mzaf_1009043656935833073.plus.aac.p.m4a'),
    ('IM GLASHAUS MIT SCHEINEN WERFEN', 'makko & lucidbeatz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/e5/d1/ece5d130-da61-a290-34fb-28c756fa7a37/mzaf_2334331961118598898.plus.aac.p.m4a'),
    ('Blanco', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7c/08/e3/7c08e334-425a-6061-a76d-eed07a417212/mzaf_12155294836401644578.plus.aac.p.m4a'),
    ('HERZ', 'CRO & BUNT.', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/04/bf/3a/04bf3af0-642d-7afa-4ca9-8911015a852a/mzaf_13992800212340248212.plus.aac.p.m4a'),
    ('sommer', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8d/f8/d4/8df8d484-c8c5-9464-90c6-b9a849da9543/mzaf_11601608387678515218.plus.aac.p.m4a'),
    ('Tour de Berlin', 'Ski Aggu, Domiziana & Replay Okay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/23/42/19/2342193a-39ce-537d-2d7f-d0dcf8051953/mzaf_2923308696450837367.plus.aac.p.m4a'),
    ('TRACKIES', '6PM RECORDS, reezy & Stickle', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/9c/c3/a59cc3d3-d580-da00-7bd3-6cacf3bdb5ef/mzaf_8765326400641025498.plus.aac.p.m4a'),
    ('40 Tage', 'Shindy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d9/7f/3c/d97f3c08-1ed3-a74e-37d3-8ca2660777b3/mzaf_13769364787174570077.plus.aac.p.m4a'),
    ('Zeiten ändern nichts', '1986zig & Kool Savas', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/92/09/dc/9209dccd-44ed-eb62-578e-ba07f278f2c5/mzaf_8914049550332445608.plus.aac.p.m4a'),
    ('Doktor', 'PA Sports, Sido, Haftbefehl & Alies', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/40/15/4c401580-708e-8d4e-d1a4-fe9c7a08af66/mzaf_12482896108109383756.plus.aac.p.m4a'),
    ('Gebete', 'RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/91/d8/0091d803-c040-58c2-1f44-8e053f31db5d/mzaf_7572544460874239446.plus.aac.p.m4a'),
    ('BIG STEPPER', 'KALIM & Shindy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b6/86/f0/b686f014-146f-9ff1-d40c-0261daeea073/mzaf_8321862367818634105.plus.aac.p.m4a'),
    ('DER SONNE IMMER NÄHER', 'Tream & Bausa', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/25/04/fa/2504fac5-06c2-c1ac-cba7-bdffb0f0a96c/mzaf_16009638849762350432.plus.aac.p.m4a'),
    ('BOOM', 'CRO & BUNT.', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/52/27/ce/5227cef1-eece-b2fe-2b25-69f24633192c/mzaf_14207168984434788261.plus.aac.p.m4a'),
    ('Leben leben', 'ELDENO & Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f7/55/87/f75587ab-61d3-e616-62d9-4cffa685401f/mzaf_6134551435808098344.plus.aac.p.m4a'),
    ('Pass auf mich auf', 'LEA & LUVRE47', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/d1/51/e9/d151e923-513b-8a41-a54a-e42ce2327cbb/mzaf_13902516344354913755.plus.aac.p.m4a'),
    ('EL FENOMENO', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/ed/9c/00ed9c75-a8f1-46f7-8282-1340dc9a1c6b/mzaf_3715258946467331101.plus.aac.p.m4a'),
    ('LOVEBOMB', 'Jamule, Sido & Miksu / Macloud', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1c/5e/ba/1c5eba83-fa65-2e92-550b-9939c4f657fc/mzaf_12278393253279906826.plus.aac.p.m4a'),
    ('Dreckig & Gemein', 'Kontra K & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a6/92/90/a692903f-d0fb-ed0a-6b4a-c4c83c02b8c5/mzaf_4353049620056260625.plus.aac.p.m4a'),
    ('Body', 'Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f0/98/67/f0986774-208a-0897-f051-f89f84ca09a6/mzaf_12092212383950218275.plus.aac.p.m4a'),
    ('Sterne', 'Sido & Bozza', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/ff/c9/40/ffc94011-2eef-d4a9-b07a-94b29a298518/mzaf_5124059784996150562.plus.aac.p.m4a'),
    ('Number One', 'Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9f/c7/15/9fc71572-1ed9-5b7a-ba61-b89a978f29d6/mzaf_12375733836247617546.plus.aac.p.m4a'),
    ('Kaum Vertrauen', 'Bazzazian, Blumengarten & Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1a/a1/02/1aa10282-fc5a-32b7-8f84-ec3f73a7ee38/mzaf_8779638921087420342.plus.aac.p.m4a'),
    ('WEISSE ZÄHNE', 'Alligatoah & Bausa', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/65/d0/c7/65d0c73c-b60b-042c-4e11-4429f63de8c4/mzaf_15834295098868407201.plus.aac.p.m4a'),
    ('$HORTY', 'Juju', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/41/45/c6/4145c6f6-364c-fedc-1528-a70550de2769/mzaf_11515401940968669699.plus.aac.p.m4a'),
    ('Vorbei', 'Robin Schulz, RAF Camora, Montez & Dario Rodriguez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/87/9b/3e/879b3e1c-8cb4-a6bb-aff2-8f07403ba177/mzaf_1516059861525404433.plus.aac.p.m4a'),
    ('Schatten', 'Morpheuz & Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7f/f2/41/7ff24172-329b-281f-2e97-9fd21612be1b/mzaf_16657858169553146552.plus.aac.p.m4a'),
    ('Bei Nacht', 'RAF Camora & CRO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/49/ab/0e/49ab0e07-ad8a-d950-9a58-6e4147ed7174/mzaf_15822838437961511033.plus.aac.p.m4a'),
    ('Wie viel', 'Disarstar & Pöbel MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/55/d9/ed/55d9edbe-8c4f-0d0b-1d87-b2c98b2136cb/mzaf_13062509664844668786.plus.aac.p.m4a'),
    ('WENDEKiND', 'FiNCH, Marteria & Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/93/2d/b6/932db621-15f0-f049-bb89-a0097b7b8388/mzaf_18424245054592230174.plus.aac.p.m4a'),
    ('Maschinenraum', 'Bausa & BIBIZA', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/93/d3/e7/93d3e795-a275-aa90-8c1d-97c60bdf71d5/mzaf_8491901308052201957.plus.aac.p.m4a'),
    ('Let''s Go', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/07/ae/57/07ae573e-222f-a123-bae2-2d8863ae93be/mzaf_7309876885742509461.plus.aac.p.m4a'),
    ('Tekken 6', 'Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7a/18/bc/7a18bcc6-2494-2306-3000-3710f0079e5c/mzaf_9260934701666026572.plus.aac.p.m4a'),
    ('PROBLEMARTEN', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ba/16/6f/ba166f5e-e667-4b31-f850-378adc0094ea/mzaf_15790710103670194318.plus.aac.p.m4a'),
    ('Monumente', 'Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a7/6e/a1/a76ea1a1-7981-f845-bea6-c24a56c16145/mzaf_16859766131340319567.plus.aac.p.m4a'),
    ('Frühling im Viertel 2.0', 'Bausa', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b8/f9/89/b8f9893e-3f74-5d91-92df-052e75a2797d/mzaf_7985683493256518013.plus.aac.p.m4a'),
    ('Pelzmäntel & Schufa', 'RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/17/43/5d/17435d43-63ef-43be-1f54-12d1451d4e39/mzaf_7715681122599300042.plus.aac.p.m4a'),
    ('Hade', 'KC Rebell, Eno & Hakim Lokman', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a5/7c/af/a57caf64-4dde-9fde-d58d-7e0b456bb576/mzaf_11383866726658884140.plus.aac.p.m4a'),
    ('HEUTE NACHT', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b3/ea/e9/b3eae99b-5092-3d3d-4a3c-9b96386d65e2/mzaf_1441601545411226452.plus.aac.p.m4a'),
    ('IN MEINER DNA', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/dc/bb/e1/dcbbe133-0c47-6f8d-368f-cfab6cf27214/mzaf_12546886472788241672.plus.aac.p.m4a'),
    ('My life', 'Kool Savas & Alies', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7d/1e/e6/7d1ee647-7702-b5fb-9150-d3ee8335b54c/mzaf_10693587054116402733.plus.aac.p.m4a'),
    ('Samurai Schwert', 'Yung Hurn', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/65/28/fa/6528fa1a-bac2-ebd4-1f49-73839cdcc005/mzaf_7922599051713498545.plus.aac.p.m4a'),
    ('Whip', 'Trettmann & RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/04/23/9a/04239aef-83e5-83a6-88e7-d6c277190630/mzaf_4471899707115688960.plus.aac.p.m4a'),
    ('CTG', 'RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ca/7d/5a/ca7d5a8c-639c-05b9-69f0-e3f8cd3e534a/mzaf_13549382546183534315.plus.aac.p.m4a'),
    ('Happy Birthday', 'SANNA & KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview123/v4/0c/4d/ce/0c4dce3c-da9a-304e-d1f1-97394fcb96e3/mzaf_484295918791478171.plus.aac.p.m4a'),
    ('Zeit x RIN', 'ENNIO & RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/7d/43/3b/7d433b6b-64fd-ad6a-1bea-8c11844aea9d/mzaf_8921864642550605751.plus.aac.p.m4a'),
    ('MIND ON MY $$$', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6e/85/1b/6e851bfb-03dd-6679-c22f-d82364a909b4/mzaf_3366244369010142205.plus.aac.p.m4a'),
    ('Manchmal', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/37/2a/dd/372add09-902b-7c3e-b8be-c5e2079c196b/mzaf_9984244776565485716.plus.aac.p.m4a'),
    ('Pasha Nanen', 'Zuna & THIS IS DARDY', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/85/db/06/85db06fc-189b-b0de-d814-b4587486c6d0/mzaf_338615190257956012.plus.aac.p.m4a'),
    ('Bei dir', 'Jamule & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0d/56/f7/0d56f774-5530-c710-eafb-21b4cea67b77/mzaf_3093789863475407207.plus.aac.p.m4a'),
    ('Herz aus Stein', 'Estikay, Samra & SANTOS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/77/c0/d4/77c0d42f-d0b5-6d67-6392-9674fd05fef0/mzaf_9099777111903076764.plus.aac.p.m4a'),
    ('Mariah Carey', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/02/77/81/02778125-ec66-cee1-74e3-80e2cfc370b0/mzaf_17714884005959782414.plus.aac.p.m4a'),
    ('HOKUS POKUS', 'Kurdo & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/69/a1/d7/69a1d7ab-1a75-ad76-4c2f-4fadbd16b429/mzaf_15620536077385099501.plus.aac.p.m4a'),
    ('Maria', 'Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fb/bc/62/fbbc62fb-8612-cdb7-a904-dbcbb9dad3a3/mzaf_9626992019895341326.plus.aac.p.m4a'),
    ('Irgendwann', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6f/ef/4a/6fef4aae-9508-50d1-c9d9-ee18d3b3526a/mzaf_7920455585732442865.plus.aac.p.m4a'),
    ('WHY', 'Juju', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0f/5d/3c/0f5d3c11-3497-d202-3555-29a730b2e36b/mzaf_8060288651996409567.plus.aac.p.m4a'),
    ('Mungu', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d4/e2/12/d4e212c8-a81d-eaba-ca24-d2262b07fc47/mzaf_13904135254925487554.plus.aac.p.m4a'),
    ('Babylonia', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/eb/0f/7a/eb0f7a44-8c0c-f00f-fb05-f70e0704cc68/mzaf_13028556774020347213.plus.aac.p.m4a'),
    ('GEIST', 'makko & Miksu / Macloud', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/72/a8/4a/72a84a32-8e0a-b7da-7c2b-a096bcd67182/mzaf_14926406848920545682.plus.aac.p.m4a'),
    ('L.I.E.B.', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/69/51/ee/6951ee32-29af-65df-b86a-6e2600ef948b/mzaf_14975031103675385678.plus.aac.p.m4a'),
    ('Wahnsinn', '01099, RIN & Gustav', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/03/c0/85/03c085d4-b87b-6b2c-3aa4-b43ee0c5db9b/mzaf_7357784700022138849.plus.aac.p.m4a'),
    ('prelude allein', 'Juju', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f3/3e/a4/f33ea422-1b38-a00d-1cdd-226e34cb12a2/mzaf_13437837933474497448.plus.aac.p.m4a'),
    ('Ti Amo', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f8/e4/98/f8e4982a-2bda-ddc2-8170-c77c6c3086a9/mzaf_4522595372364098278.plus.aac.p.m4a'),
    ('Normal zu lieben', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview123/v4/7c/21/83/7c218369-aea0-4812-6846-55bc2f1dc43e/mzaf_13093781519628213744.plus.aac.p.m4a'),
    ('Barbie & Ken', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/99/69/04/996904c7-b9a1-4a8b-ddda-e7534bab9e89/mzaf_2524642872684901284.plus.aac.p.m4a'),
    ('Weiße Orchideen', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a7/76/d1/a776d1a8-58b2-5a56-8683-580a147f029c/mzaf_11956202380289994444.plus.aac.p.m4a'),
    ('Beretta', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/fb/62/87/fb628789-b7ca-e377-dbd7-614d42a75add/mzaf_10549660590872910506.plus.aac.p.m4a'),
    ('Wunderschön', '1986zig & Bozza', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/87/38/b0/8738b0cb-1b81-47e2-5b54-f3591c0599b0/mzaf_16183288924600578677.plus.aac.p.m4a'),
    ('Strassenmelodie', 'Miami Yacine & SRNO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/40/e5/fb/40e5fb69-fe30-efdc-29d2-8615de161d5b/mzaf_13602128457672147082.plus.aac.p.m4a'),
    ('SOBER', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/55/6d/1f/556d1f5d-473d-bc0b-dede-8110ff3fa2a3/mzaf_14782195066701509251.plus.aac.p.m4a'),
    ('STERNHIMMELDACH', 'BOJAN & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e4/73/58/e4735896-0800-4517-8f11-e6e6d6465e67/mzaf_18283054740411781302.plus.aac.p.m4a'),
    ('Bladerunner', 'RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/42/e6/46/42e646c7-6ada-d07f-2d4c-212aad165003/mzaf_10080647612663281592.plus.aac.p.m4a'),
    ('Valium', '1986zig & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/98/10/de/9810de2f-5eb2-d7c3-4a01-ac1a33898a7e/mzaf_10166741569885775122.plus.aac.p.m4a'),
    ('Memos', 'Symba & makko', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b9/7e/8e/b97e8e5b-16ab-972a-7806-c623fda30ac1/mzaf_11305103443969938710.plus.aac.p.m4a'),
    ('Asozialer Araber', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/06/c9/32/06c93209-0b8c-856c-d752-32a611806f4c/mzaf_6983262192757295817.plus.aac.p.m4a'),
    ('Dale', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/65/44/7e/65447e38-3b73-4c3d-3f52-7db8bd18b00d/mzaf_5785039631957696441.plus.aac.p.m4a'),
    ('GLAUB NICHT ALLES WAS DU SIEHST', 'Ufo361 & makko', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7c/db/5a/7cdb5ab5-f704-3cfa-d280-0e5b91d46992/mzaf_3029268985862018080.plus.aac.p.m4a'),
    ('WATCH THE BODY DROP', 'KALIM & OG Keemo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/44/aa/e8/44aae862-4b00-2308-7dc7-45bbe738eaf8/mzaf_15142285644777361439.plus.aac.p.m4a'),
    ('MAKE LOVE', 'BOJAN & Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/83/43/2d/83432dbd-f5e5-0a8b-7f0e-35d63032d739/mzaf_1118586564814111836.plus.aac.p.m4a'),
    ('Get it On', 'Shindy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/71/97/f3/7197f331-bcd3-da69-4953-a92b3788b239/mzaf_9467222381849914090.plus.aac.p.m4a'),
    ('Baby Mama', 'Saliou & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/45/ed/60/45ed6082-5f22-65a3-987c-8b0bc9b64e6a/mzaf_286500367577267129.plus.aac.p.m4a'),
    ('ICH MACH ES', 'AK AUSSERKONTROLLE & Undacava', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/87/03/17/87031742-614f-f5ff-da36-dd53a0559d4a/mzaf_16238059611758974715.plus.aac.p.m4a'),
    ('Familienchronik', 'Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/02/62/04/0262046f-6eb6-a9d7-8b7c-103e750b8569/mzaf_14583618234552277672.plus.aac.p.m4a'),
    ('Angel Eyes', 'RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f9/af/04/f9af0400-eb42-532b-6ac0-766dbf13ede3/mzaf_8179435132545092598.plus.aac.p.m4a'),
    ('Magnolien', 'Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/6b/9c/5d/6b9c5d8f-7d73-298b-d4a0-24b51b60c9b9/mzaf_876312391880639996.plus.aac.p.m4a'),
    ('Plaza', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/31/7b/f5/317bf58a-0ca0-ad37-4cee-3bcc7d53354f/mzaf_2357910546520271752.plus.aac.p.m4a'),
    ('emma', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b3/b4/0d/b3b40d04-a88d-4f14-cb56-72a4e54d0cbf/mzaf_10308902677634306436.plus.aac.p.m4a'),
    ('5 Uhr', 'Disarstar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/4a/a8/b5/4aa8b512-434a-595f-a33b-c099e567ddac/mzaf_16150532389011706679.plus.aac.p.m4a'),
    ('BETTER DAYZ', 'Summer Cem & Geenaro & Ghana Beats', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/29/b9/9029b96f-d613-0b83-78e8-79fa02fefb36/mzaf_17349856476015755068.plus.aac.p.m4a'),
    ('Captain Europa', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/29/6d/f6/296df65a-954a-7487-8b36-9b3b4c165911/mzaf_14047372802388432379.plus.aac.p.m4a'),
    ('warum??', 'Haaland936 & Loredana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/75/1a/73/751a733c-27eb-0616-b21a-8e88bbeebe49/mzaf_18301944448786279400.plus.aac.p.m4a'),
    ('Tagebuch', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/52/e2/6a52e21f-ddf8-da3e-3ec4-84c6fffedbfa/mzaf_11363355878459504484.plus.aac.p.m4a'),
    ('UMARMUNG', 'OVE & makko', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/44/77/da/4477da87-3dab-20f6-3448-3194bf5932d5/mzaf_1495938876356813874.plus.aac.p.m4a'),
    ('IMMER UNTERWEGS', 'AK AUSSERKONTROLLE & Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cc/4c/ef/cc4cefcc-76c0-ba28-c727-3f6b27107a87/mzaf_1171581247820736063.plus.aac.p.m4a'),
    ('Papaya', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d0/1c/ae/d01cae60-fcfc-b68d-bd26-4385f02b3ffa/mzaf_6945943440048941783.plus.aac.p.m4a'),
    ('Komm mit', 'badmómzjay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a1/36/08/a1360874-180c-e2f9-6d12-71bced9ad9da/mzaf_16870706632721125190.plus.aac.p.m4a'),
    ('Der Mensch stammt von Waffen ab', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/7e/4d/dd/7e4dddb2-f267-8ae8-ddbe-723a5e28b6d9/mzaf_14027299131946370188.plus.aac.p.m4a'),
    ('SAYFA', 'KC Rebell, ERAY067 & MANSUR', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/c4/32/adc43260-2cca-1ae7-d2c6-8e91690fad03/mzaf_14594639550616219058.plus.aac.p.m4a'),
    ('Aspirin', 'Yung Yury, Edo Saiya & Damn Yury', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/ce/65/90ce65bb-cc5e-e729-7980-f0284b2511d8/mzaf_3740146048078422205.plus.aac.p.m4a'),
    ('EXIT THROUGH THE GIFT SHOP', 'RIN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/95/1d/51/951d5134-c63b-76e6-a7d7-77f2b435c94c/mzaf_3404703661459502538.plus.aac.p.m4a'),
    ('eine nase', 'Yung Hurn', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/09/92/90/099290d5-e5c1-a754-9110-5b8ee30b38b5/mzaf_7079122834616214020.plus.aac.p.m4a'),
    ('Bang', 'Avie, Delil & Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9a/54/5f/9a545f35-04b6-ce4b-e77c-ad9fa62fdc80/mzaf_5353498550943481217.plus.aac.p.m4a'),
    ('WEEKEND', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/50/62/d2/5062d2fc-2dc6-426d-cb14-f115402d2e2a/mzaf_13257673340527140850.plus.aac.p.m4a'),
    ('Platz für uns beide', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/63/e2/aa/63e2aa30-637c-0816-3c53-f3a875f6abd7/mzaf_16058545136298639516.plus.aac.p.m4a'),
    ('immer noch nervös', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c9/59/db/c959db7e-abc5-2292-3ee1-5ad704a3e504/mzaf_9029150265252792545.plus.aac.p.m4a'),
    ('4 Life', 'badmómzjay, Takt32 & vito', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8b/3f/37/8b3f371a-4e9b-769e-f15c-11b2e3fbf57a/mzaf_555848743556415473.plus.aac.p.m4a'),
    ('Rottweiler', 'Bazzazian, OG Keemo & Schmyt', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/02/57/1c/02571c87-56ac-c389-507c-e4ab2c2418b3/mzaf_15882141566670147924.plus.aac.p.m4a'),
    ('HABIBI', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bc/ab/a8/bcaba8ac-d2d0-5d3d-2c3c-6bc62be4e4aa/mzaf_1142964363303506908.plus.aac.p.m4a'),
    ('BIELEFELD', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/cc/11/58/cc11588c-a34f-34f4-61a4-a674b4636717/mzaf_16263017425410838093.plus.aac.p.m4a'),
    ('DU FEHLST', 'Kurdo & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1b/6f/a6/1b6fa625-fa7e-380f-cfd7-5fbd69c6ee2a/mzaf_17553965928552408157.plus.aac.p.m4a'),
    ('luft holen', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a6/04/db/a604dbcb-4710-351f-09a7-05f2383d0375/mzaf_16645538316960149673.plus.aac.p.m4a'),
    ('Gebetet', 'Bushido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0d/11/f8/0d11f8f8-8ed7-19b5-c292-ac58635dc1d9/mzaf_16396795649931743582.plus.aac.p.m4a'),
    ('falsche zeit, falscher ort', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d6/35/34/d63534b3-e027-d653-c018-09538a229ab0/mzaf_11511854140979319769.plus.aac.p.m4a'),
    ('Wenn Ich Ehrlich Bin', 'Liaze & Bozza', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/cc/cb/41/cccb41c9-d9c5-61d9-f5ed-df33b0dc78d7/mzaf_16351749874733587778.plus.aac.p.m4a'),
    ('Sie', 'CRO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a2/33/5d/a2335d7f-b87b-e9e2-439f-51bb89ea249e/mzaf_5111078218532236988.plus.aac.p.m4a'),
    ('La 3youne', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/75/24/c4/7524c492-177a-32ef-cf47-3bceea835803/mzaf_12543184924114294351.plus.aac.p.m4a'),
    ('Buonasera', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c4/f7/65/c4f765c3-42b9-1e1d-17f8-3562239d0ac4/mzaf_8614215666656592719.plus.aac.p.m4a'),
    ('Sommerregen', 'SRNO & Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8c/c3/82/8cc3827d-8b10-64f5-7819-483ab1ab937f/mzaf_9003414316984527837.plus.aac.p.m4a'),
    ('Ozean', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d9/a6/fc/d9a6fc1a-d4f0-258c-1582-eb41171a37a0/mzaf_3715534556376139007.plus.aac.p.m4a'),
    ('BMJ', 'badmómzjay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5f/16/79/5f1679e9-e3a9-a5ec-7482-012e31252b36/mzaf_292088097617968224.plus.aac.p.m4a'),
    ('LOVE & DRAMA', 'Loredana & JUGGLERZ', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/46/a3/58/46a35889-72a5-c0d2-2aca-0a40a8703cfd/mzaf_6790072026466316596.plus.aac.p.m4a'),
    ('HDF HOTBOX', 'Marvin Game, LIZ, Super Static, KASIMIR1441, KDM Shey, FGUN $HAKI, CHANLE, CIIIO, Jaill, Lugatti, 9inebro, Tom Hengst, beslik, Ruski53, Chefket, Big Toe, Shippie Talls, Joshi Mizu & XAVER', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/01/24/4e/01244eee-2bfe-3520-254a-8f85802c85c4/mzaf_3780145828612828950.plus.aac.p.m4a'),
    ('STRESS OHNE GRUND', 'Majoe, Zombic & District Red', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f4/b0/45/f4b045da-fda7-083d-f049-85c3a6a28d94/mzaf_3949487449278880155.plus.aac.p.m4a'),
    ('HOLLISTER', 'Yung Hurn', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/00/7c/ca/007cca58-1071-b11d-46f7-22c08b714ab6/mzaf_9408837777068289740.plus.aac.p.m4a'),
    ('Welt Bereisen', 'Edo Saiya & lityway', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/4c/53/1e/4c531e85-aedb-1db2-3f12-12820aac9040/mzaf_15585865197459514316.plus.aac.p.m4a'),
    ('7 Leben', 'Montez & Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/3d/c2/cb/3dc2cb26-64ef-b642-33e3-c270b6c0f4e4/mzaf_6336427740678532291.plus.aac.p.m4a'),
    ('Warum bin ich so', 'badmómzjay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/34/a8/0c/34a80cec-0385-b74d-9ddf-2ace388bd75c/mzaf_18085213520916567190.plus.aac.p.m4a'),
    ('INTO YOU', 'Yung Hurn', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/23/dd/dd/23ddddb0-2cbc-1d7e-09b4-72cbe828b8bf/mzaf_107932633331029386.plus.aac.p.m4a'),
    ('LOVESONG', 'Loredana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/da/43/5e/da435e55-23c7-26b2-292a-ec39e67c5c19/mzaf_15989431391312284613.plus.aac.p.m4a'),
    ('Ring Ring', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/83/f4/d283f42b-171b-98ab-9740-ac70abdafd57/mzaf_6864107917543808666.plus.aac.p.m4a'),
    ('90 Kilo', 'Apsilon & LUVRE47', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/5d/93/15/5d93153d-e3d0-aff8-b2ea-b1ce7ecc64ea/mzaf_13879822072369134955.plus.aac.p.m4a'),
    ('DTB', 'badmómzjay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/77/91/f8/7791f84c-61a7-3b46-0810-56632cfa51cc/mzaf_1537827524468829766.plus.aac.p.m4a'),
    ('Hallelujah', 'badmómzjay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/68/1d/b7/681db7e5-dfde-3b2b-8172-862f7b389601/mzaf_2732634179904593962.plus.aac.p.m4a'),
    ('SONNE & REGEN', 'Yung Hurn', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/fc/33/d2/fc33d299-d30c-4b2b-08f4-dda846d2636d/mzaf_5766852245104896479.plus.aac.p.m4a'),
    ('Bis du gehst', 'Bozza', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/de/c9/13/dec91330-d6db-765c-5ec3-417821b27bae/mzaf_7861168893359015278.plus.aac.p.m4a'),
    ('Wiedaa', 'Stickle, Yung Hurn & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/af/fb/b1/affbb172-182a-46f0-532b-d8ea253e0d11/mzaf_15386972584494573688.plus.aac.p.m4a'),
    ('Sommerhaus', 'Sharaktah & Edo Saiya', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/6d/ba/fd/6dbafd80-7312-8fd2-2a38-889602d2956d/mzaf_2253648611170589705.plus.aac.p.m4a'),
    ('RIP', 'Takt32 & badmómzjay', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/74/6f/cb/746fcb7b-3640-494f-50e4-4c3ebfe82a36/mzaf_405870471310985519.plus.aac.p.m4a'),
    ('camel gelb', 'Edo Saiya', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/86/4c/3b/864c3ba3-79a6-599d-612f-1aaf5eb1aa8e/mzaf_16320364589705271719.plus.aac.p.m4a')
) AS v(title, artist, url)
JOIN public.topic_pool tp ON tp.text = 'Deutschrap aktuell'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

COMMIT;


-- >>> 080_security_hardening.sql <<<
-- ============================================================
-- Migration 080: Sicherheits-Härtung (Ergebnis des Angriffs-Tests db/scripts/security-attack.mjs)
-- ============================================================
-- Gefunden und behoben:
--  1. Supabase vergibt per Voreinstellung an JEDE Funktion/Tabelle Rechte für Gäste. Über 60 interne
--     Funktionen waren für jeden aufrufbar (z. B. aggregate_player_stats = Statistik aufblähen,
--     rpc_clear_lobby_to_waiting = fremde Lobbys zurücksetzen). Jetzt: alles gesperrt, nur eine
--     Whitelist der wirklich genutzten Funktionen ist freigegeben; neue Funktionen sind standardmäßig zu.
--  2. IDOR: Freundschaften/gemerkte Lobbys/Beitritt/Lobby-Erstellung nahmen die Nutzer-ID als Parameter
--     (jeder konnte als jemand anderes handeln). Jetzt muss sie der eingeloggten Person gehören.
--  3. _verify_session ließ Spieler ohne Sitzungs-Token durch (jeder konnte sie steuern). Jetzt abgewiesen.
--  4. Tabellen: Schreibrechte für anon/authenticated komplett entzogen (Spiel schreibt nur über RPCs);
--     gemerkte Lobbys/Freundschaften nur noch für Beteiligte lesbar; riskante Alt-Policies entfernt.
--  5. cleanup_lobby(…, 0) konnte alle Spieler rauswerfen -> Mindestzeit; rpc_heartbeat prüft Sitzung.
--  6. Zeit-Schutz: Themenwahl/Countdown/Rematch ließen sich von außen vorzeitig auslösen.
--  7. Missbrauchsbremse: Lobby-Erstellung und Tracking pro IP begrenzt, harte Obergrenzen.
--  8. Admin-Aussperr-Schutz: der letzte aktive Admin kann nie gesperrt/herabgestuft/gelöscht werden.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Hilfen: Client-IP, Rate-Limit, Code-Patch
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rate_limits (
  key          text NOT NULL,
  window_start timestamptz NOT NULL,
  n            integer NOT NULL DEFAULT 0,
  PRIMARY KEY (key, window_start)
);
ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rate_limits FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._client_ip()
 RETURNS text LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select coalesce(
    nullif(h ->> 'cf-connecting-ip', ''),
    nullif(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1), ''),
    nullif(h ->> 'x-real-ip', ''),
    'unknown')
  from (select coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json) as h) x;
$function$;

-- Zählt einen Versuch; wirft 'rate_limited', wenn das Limit im Zeitfenster überschritten ist.
-- Interne Aufrufe (ohne HTTP-Anfrage, z. B. pg_cron) werden nicht begrenzt.
CREATE OR REPLACE FUNCTION public._rate_limit(p_key text, p_max integer, p_seconds integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_w timestamptz := date_bin(make_interval(secs => p_seconds), now(), '2000-01-01'::timestamptz);
  v_n integer;
begin
  if coalesce(current_setting('request.headers', true), '') = '' then return; end if;
  insert into public.rate_limits (key, window_start, n) values (p_key, v_w, 1)
  on conflict (key, window_start) do update set n = public.rate_limits.n + 1
  returning n into v_n;
  if v_n > p_max then raise exception 'rate_limited'; end if;
end;
$function$;

-- Ersetzt GENAU EIN Vorkommen von p_anchor (einzeilig!) in der Funktionsdefinition durch p_replacement
-- und spielt sie neu ein. Bricht ab, wenn der Anker fehlt (Schutz vor stillem Fehlschlag).
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(p_sig regprocedure, p_anchor text, p_replacement text)
 RETURNS void LANGUAGE plpgsql
AS $function$
declare d text; i int;
begin
  d := pg_get_functiondef(p_sig);
  i := position(p_anchor in d);
  if i = 0 then raise exception 'Anker nicht gefunden in %: %', p_sig, p_anchor; end if;
  d := substr(d, 1, i - 1) || p_replacement || substr(d, i + length(p_anchor));
  execute d;
end;
$function$;

-- ------------------------------------------------------------
-- 1) Funktionen: alles zu, dann Whitelist
-- ------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

DO $$
declare
  f record;
  -- Spiel-Funktionen: Gäste UND eingeloggte (Sitzungs-Token bzw. Zeit-Prüfung steckt in den Funktionen)
  guest_ok text[] := array[
    'cleanup_lobby', 'get_song_playlists', 'is_username_available', 'kick_player', 'log_event',
    'rpc_add_bot', 'rpc_advance_from_countdown', 'rpc_attempt_pass', 'rpc_begin_topic_vote', 'rpc_create_lobby',
    'rpc_finalize_topic_vote', 'rpc_heartbeat', 'rpc_host_kick_during_round', 'rpc_join_lobby', 'rpc_leave_lobby',
    'rpc_maybe_shorten_topic_vote', 'rpc_rematch', 'rpc_remove_bot', 'rpc_reset_lobby', 'rpc_resolve_stale_attempt',
    'rpc_revenge_flip', 'rpc_server_time', 'rpc_skip_song', 'rpc_start_next_set', 'rpc_start_rematch_if_ready',
    'rpc_tick_game', 'rpc_toggle_ready', 'rpc_vote_topic', 'rpc_vote_answer',
    'set_lobby_answer_mode', 'set_lobby_lock', 'set_lobby_mode', 'set_lobby_series', 'set_lobby_song_answer_mode',
    'set_lobby_topic', 'set_lobby_topic_filter', 'set_max_players', 'transfer_host'
  ];
  -- Konto-Funktionen: nur eingeloggte
  auth_ok text[] := array[
    'admin_whoami', 'admin_list_users', 'admin_get_user', 'admin_set_user_status', 'admin_delete_user', 'admin_set_role',
    'admin_update_user_profile', 'admin_log_password_reset', 'admin_list_lobbies', 'admin_close_lobby',
    'admin_list_songs', 'admin_set_song_archived', 'admin_list_audit', 'admin_song_stats', 'admin_balance_stats',
    'admin_funnel', 'rpc_get_admin_stats', 'get_my_settings', 'get_my_profile_stats', 'set_my_username',
    'update_my_profile', 'set_my_preferences', 'request_account_deletion',
    'rpc_send_friend_request', 'rpc_accept_friend_request', 'rpc_remove_friend', 'rpc_save_lobby', 'rpc_unsave_lobby'
  ];
begin
  for f in
    select p.oid::regprocedure as sig, p.proname, p.pronargs
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
  loop
    -- Alt-Überladungen bleiben gesperrt (nur die neuen Varianten werden von der App genutzt)
    if f.proname = 'rpc_join_lobby' and f.pronargs <> 4 then continue; end if;
    if f.proname = 'rpc_reset_lobby' and f.pronargs <> 2 then continue; end if;
    if f.proname = ANY (guest_ok) then
      execute format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
    elsif f.proname = ANY (auth_ok) then
      execute format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    end if;
  end loop;
end $$;

-- Künftige Funktionen sind standardmäßig NICHT aufrufbar (neue Migrationen müssen bewusst freigeben)
DO $$
begin
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
exception when others then
  raise notice 'Default-Privileges (postgres): %', sqlerrm;
end $$;
DO $$
begin
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
exception when others then
  raise notice 'Default-Privileges (supabase_admin) übersprungen: %', sqlerrm;
end $$;

-- ------------------------------------------------------------
-- 2) Tabellen: keine Schreibrechte für Clients, Lesen nur wo nötig
-- ------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
-- Spalten-Rechte (falls einzeln vergeben) ebenfalls entfernen
DO $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'v', 'p') loop
    execute format('REVOKE INSERT (%1$s), UPDATE (%1$s) ON public.%2$I FROM anon, authenticated',
      (select string_agg(quote_ident(a.attname), ', ') from pg_attribute a where a.attrelid = ('public.' || quote_ident(t.relname))::regclass and a.attnum > 0 and not a.attisdropped),
      t.relname);
  end loop;
end $$;
-- Nie vom Client genutzt (kein Zugriff, auch nicht lesend)
REVOKE ALL ON public.kv_store_8e1b0e4b, public.staff_roles, public.lobby_admin_logs, public.lobby_admin_sessions FROM anon, authenticated;

-- Riskante Alt-Policies (erlaubten theoretisch Schreiben für jeden) entfernen
DO $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies where schemaname = 'public' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL') loop
    execute format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- Gemerkte Lobbys: nur die eigenen; Freundschaften: nur Beteiligte
DROP POLICY IF EXISTS saved_lobbies_read ON public.saved_lobbies;
DO $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies where schemaname = 'public' and tablename in ('saved_lobbies', 'friendships') and cmd = 'SELECT' loop
    execute format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, p.tablename);
  end loop;
end $$;
DROP POLICY IF EXISTS saved_lobbies_own ON public.saved_lobbies;
CREATE POLICY saved_lobbies_own ON public.saved_lobbies FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS friendships_participants ON public.friendships;
CREATE POLICY friendships_participants ON public.friendships FOR SELECT TO authenticated USING (auth.uid() = user_id OR auth.uid() = friend_user_id);
REVOKE SELECT ON public.saved_lobbies, public.friendships FROM anon;

-- ------------------------------------------------------------
-- 3) IDOR-Fixes: Handeln nur als man selbst
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_send_friend_request(p_from_user_id uuid, p_to_username text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_to_id UUID;
BEGIN
    IF auth.uid() IS NULL OR p_from_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    PERFORM public._rate_limit('friendreq:' || auth.uid()::text, 30, 3600);

    SELECT id INTO v_to_id FROM public.profiles
    WHERE LOWER(username) = LOWER(TRIM(p_to_username)) LIMIT 1;

    IF v_to_id IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
    IF v_to_id = p_from_user_id THEN RAISE EXCEPTION 'cannot_befriend_self'; END IF;

    INSERT INTO public.friendships (user_id, friend_user_id, status)
    VALUES (p_from_user_id, v_to_id, 'pending')
    ON CONFLICT (user_id, friend_user_id) DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_accept_friend_request(p_me_user_id uuid, p_from_user_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_me_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;

    UPDATE public.friendships SET status = 'accepted', accepted_at = NOW()
    WHERE user_id = p_from_user_id AND friend_user_id = p_me_user_id AND status = 'pending';
    IF NOT FOUND THEN RAISE EXCEPTION 'request_not_found'; END IF;

    INSERT INTO public.friendships (user_id, friend_user_id, status, accepted_at)
    VALUES (p_me_user_id, p_from_user_id, 'accepted', NOW())
    ON CONFLICT (user_id, friend_user_id) DO UPDATE SET status = 'accepted', accepted_at = NOW();
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_remove_friend(p_me_user_id uuid, p_friend_user_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_me_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    DELETE FROM public.friendships
    WHERE (user_id = p_me_user_id AND friend_user_id = p_friend_user_id)
       OR (user_id = p_friend_user_id AND friend_user_id = p_me_user_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_save_lobby(p_user_id uuid, p_lobby_code text, p_nickname text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    PERFORM public._rate_limit('savelobby:' || auth.uid()::text, 60, 3600);
    INSERT INTO public.saved_lobbies (user_id, lobby_code, nickname, last_used)
    VALUES (p_user_id, UPPER(LEFT(TRIM(p_lobby_code), 12)), LEFT(TRIM(p_nickname), 40), NOW())
    ON CONFLICT (user_id, lobby_code) DO UPDATE SET nickname = EXCLUDED.nickname, last_used = NOW();
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_unsave_lobby(p_user_id uuid, p_lobby_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    DELETE FROM public.saved_lobbies WHERE user_id = p_user_id AND lobby_code = UPPER(TRIM(p_lobby_code));
END;
$function$;

-- Beitritt: Konto-ID muss die eigene sein; fremde, tokenlose Plätze nicht übernehmbar
SELECT pg_temp.patch_fn(
  'public.rpc_join_lobby(text, uuid, text, uuid)'::regprocedure,
  'if v_locked then raise exception ''lobby_locked''; end if;',
  'if v_locked then raise exception ''lobby_locked''; end if;
  if p_user_id is not null and p_user_id is distinct from auth.uid() then raise exception ''user_mismatch''; end if;
  perform public._rate_limit(''join:'' || public._client_ip(), 120, 600);');
SELECT pg_temp.patch_fn(
  'public.rpc_join_lobby(text, uuid, text, uuid)'::regprocedure,
  'if v_existing is not null and v_token is distinct from v_existing then',
  'if v_existing is null and exists (select 1 from public.players where lobby_id = v_lobby_id and player_id = p_player_id and user_id is not null and user_id is distinct from auth.uid()) then
    raise exception ''identity_taken'';
  end if;
  if v_existing is not null and v_token is distinct from v_existing then');

-- Lobby erstellen: eigene Konto-ID, Rate-Limit pro IP, harte Obergrenze
SELECT pg_temp.patch_fn(
  'public.rpc_create_lobby(text, text, integer, integer, uuid, text)'::regprocedure,
  'v_code := public.generate_lobby_code(4);',
  'if p_user_id is not null and p_user_id is distinct from auth.uid() then raise exception ''user_mismatch''; end if;
  perform public._rate_limit(''createlobby:'' || public._client_ip(), 20, 600);
  if (select count(*) from public.lobbies) >= 1000 then raise exception ''rate_limited''; end if;
  v_code := public.generate_lobby_code(4);');

-- ------------------------------------------------------------
-- 4) Sitzung: kein Durchwinken mehr für Spieler ohne Token
-- ------------------------------------------------------------
SELECT pg_temp.patch_fn(
  'public._verify_session(uuid, uuid)'::regprocedure,
  'if v_stored is null then return true; end if;',
  'if v_stored is null then return false; end if;  -- 080: Plätze ohne Token sind nicht steuerbar');

CREATE OR REPLACE FUNCTION public.rpc_heartbeat(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public._verify_session(p_lobby_id, p_player_id) then return; end if;  -- still ignorieren, kein Fehler im Hintergrund
  update public.players
  set last_seen_at = now(), status = 'active'
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';
end;
$function$;

-- cleanup_lobby: Mindestzeit, damit niemand alle Spieler per "0 Sekunden" rauswerfen kann
SELECT pg_temp.patch_fn(
  'public.cleanup_lobby(uuid, integer)'::regprocedure,
  'declare',
  'declare
  p_stale_seconds_eff integer;');
SELECT pg_temp.patch_fn(
  'public.cleanup_lobby(uuid, integer)'::regprocedure,
  'select host_player_id, phase',
  'p_stale_seconds_eff := greatest(coalesce(p_stale_seconds, 60), 30);
  select host_player_id, phase');
SELECT pg_temp.patch_fn(
  'public.cleanup_lobby(uuid, integer)'::regprocedure,
  'last_seen_at < (now() - make_interval(secs => p_stale_seconds))',
  'last_seen_at < (now() - make_interval(secs => p_stale_seconds_eff))');

-- ------------------------------------------------------------
-- 5) Zeit-Schutz: nur von außen (HTTP) nicht vor Ablauf auslösbar; pg_cron/intern unverändert
-- ------------------------------------------------------------
SELECT pg_temp.patch_fn(
  'public.rpc_finalize_topic_vote(uuid)'::regprocedure,
  'if not found then return; end if;',
  'if not found then return; end if;
  if coalesce(current_setting(''request.headers'', true), '''') <> '''' and exists (select 1 from public.lobbies where id = p_lobby_id and topic_vote_ends_at > now() + interval ''1 second'') then return; end if;');
SELECT pg_temp.patch_fn(
  'public.rpc_advance_from_countdown(uuid)'::regprocedure,
  'if v_phase is distinct from ''countdown'' then return; end if;',
  'if v_phase is distinct from ''countdown'' then return; end if;
  if coalesce(current_setting(''request.headers'', true), '''') <> '''' and exists (select 1 from public.lobbies where id = p_lobby_id and countdown_ends_at > now() + interval ''1 second'') then return; end if;');
SELECT pg_temp.patch_fn(
  'public.rpc_start_rematch_if_ready(text)'::regprocedure,
  'if v_lobby_id is null then raise exception ''Lobby nicht gefunden''; end if;',
  'if v_lobby_id is null then raise exception ''Lobby nicht gefunden''; end if;
  if coalesce(current_setting(''request.headers'', true), '''') <> '''' and exists (select 1 from public.lobbies where id = v_lobby_id and countdown_ends_at > now() + interval ''1 second'') then return; end if;');

-- Tracking: Obergrenze pro IP (verhindert Datenmüll-Flut)
SELECT pg_temp.patch_fn(
  'public.log_event(text, text, jsonb)'::regprocedure,
  'if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;',
  'if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;
  begin perform public._rate_limit(''log:'' || public._client_ip(), 300, 60); exception when others then return; end;');

-- Hygiene: fester search_path für alle SECURITY-DEFINER-Funktionen
DO $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('ALTER FUNCTION %s SET search_path TO ''public''', f.sig);
  end loop;
end $$;

-- Aufräumen der Rate-Limit-Tabelle (stündlich)
DO $$
begin
  if exists (select 1 from cron.job where jobname = 'kumpir-ratelimit-cleanup') then perform cron.unschedule('kumpir-ratelimit-cleanup'); end if;
  perform cron.schedule('kumpir-ratelimit-cleanup', '23 * * * *', $job$delete from public.rate_limits where window_start < now() - interval '2 hours'$job$);
end $$;

-- ------------------------------------------------------------
-- 6) Admin-Aussperr-Schutz
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._protect_last_admin()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if OLD.role = 'admin' and OLD.status = 'active'
     and (TG_OP = 'DELETE' or NEW.role is distinct from 'admin' or NEW.status is distinct from 'active')
     and not exists (select 1 from public.profiles p where p.id <> OLD.id and p.role = 'admin' and p.status = 'active') then
    raise exception 'last_admin_protected';
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end;
$function$;
DROP TRIGGER IF EXISTS profiles_protect_last_admin ON public.profiles;
CREATE TRIGGER profiles_protect_last_admin BEFORE UPDATE OF role, status OR DELETE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public._protect_last_admin();

-- Admin-Konten werden nie per Auth-Sperre blockiert (auch nicht durch Supporter-/Admin-Aktionen anderer)
SELECT pg_temp.patch_fn(
  'public._set_login_blocked(uuid, boolean)'::regprocedure,
  'update auth.users set banned_until',
  'if p_blocked and exists (select 1 from public.profiles where id = p_user_id and role = ''admin'') then
    raise exception ''admin_cannot_be_blocked'';
  end if;
  update auth.users set banned_until');

COMMIT;


-- >>> 081_sanitize_names.sql <<<
-- ============================================================
-- Migration 081: Spielernamen und Lobby-Themen säubern (Schutz in der Tiefe)
-- ============================================================
-- React zeigt Namen bereits sicher an (kein HTML-Rendering). Damit aber auch künftige
-- Ausgabewege (Bilder, Mails, Admin-Exporte …) nie HTML/Steuerzeichen aus Nutzereingaben
-- bekommen, werden < > " ` \ und Steuerzeichen schon beim Speichern entfernt.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._clean_text(p text, p_max integer)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public'
AS $function$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[<>"`\\]', '', 'g'), '[[:cntrl:]]', '', 'g')), p_max);
$function$;
REVOKE ALL ON FUNCTION public._clean_text(text, integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._trg_clean_player_name()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
begin
  NEW.name := public._clean_text(NEW.name, 24);
  if NEW.name = '' then NEW.name := 'Spieler'; end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS players_clean_name ON public.players;
CREATE TRIGGER players_clean_name BEFORE INSERT OR UPDATE OF name ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_clean_player_name();

CREATE OR REPLACE FUNCTION public._trg_clean_lobby_topic()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
begin
  if NEW.topic is not null then NEW.topic := nullif(public._clean_text(NEW.topic, 60), ''); end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS lobbies_clean_topic ON public.lobbies;
CREATE TRIGGER lobbies_clean_topic BEFORE INSERT OR UPDATE OF topic ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_clean_lobby_topic();

-- Bestehende Namen einmalig säubern
UPDATE public.players SET name = name WHERE name ~ '[<>"`\\[:cntrl:]]';

COMMIT;


-- >>> 082_admin_never_locked_out.sql <<<
-- ============================================================
-- Migration 082: Admins werden nie ausgebremst
-- ============================================================
-- Eingeloggte, aktive Admins sind von allen Rate-Limits ausgenommen (z. B. viele Testlobbys hintereinander).
-- Zusammen mit 080 (letzter Admin nicht sperr-/herabstufbar, Admins nie per Login-Sperre blockierbar)
-- und dem Notfall-Skript db/scripts/restore-admin.mjs (direkter DB-Zugang vom eigenen Rechner)
-- kann sich der Besitzer nicht aussperren.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._rate_limit(p_key text, p_max integer, p_seconds integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_w timestamptz := date_bin(make_interval(secs => p_seconds), now(), '2000-01-01'::timestamptz);
  v_n integer;
begin
  if coalesce(current_setting('request.headers', true), '') = '' then return; end if;  -- intern (pg_cron)
  if auth.uid() is not null and exists (
    select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'active'
  ) then
    return;  -- Admins nie ausbremsen
  end if;
  insert into public.rate_limits (key, window_start, n) values (p_key, v_w, 1)
  on conflict (key, window_start) do update set n = public.rate_limits.n + 1
  returning n into v_n;
  if v_n > p_max then raise exception 'rate_limited'; end if;
end;
$function$;
REVOKE ALL ON FUNCTION public._rate_limit(text, integer, integer) FROM PUBLIC, anon, authenticated;

COMMIT;


-- >>> 083_audit_everything.sql <<<
-- ============================================================
-- 083: Protokoll ohne Ausnahmen
-- ============================================================
-- Bisher stand im Protokoll (admin_audit) nur, was über Admin-Panel-Funktionen lief.
-- Jetzt hängt die Protokollierung an den Tabellen selbst – egal ob Admin-Panel, Einstellungen
-- eines Spielers, Skript oder SQL: Konto angelegt/gelöscht, Benutzername, Anzeigename, Avatar,
-- Einstellungen, E-Mail, Passwort, Rolle, Sperre, Songs, Playlists, abgelaufene Lobbys.
--
-- Doppelte Einträge werden vermieden: Aktionen, die schon eine Admin-Funktion mit Namen
-- festhält (auth.uid() gesetzt und ≠ betroffenes Konto), protokolliert der Trigger nicht noch einmal.
-- Das Protokoll selbst ist manipulationssicher (kein UPDATE/DELETE/TRUNCATE, außer mit Wartungs-Schalter).
-- Spielzüge einzelner Runden gehören nicht hierher (die stehen im Spielprotokoll game_events).
-- ============================================================

BEGIN;

ALTER TABLE public.admin_audit ADD COLUMN IF NOT EXISTS txid bigint;
CREATE INDEX IF NOT EXISTS admin_audit_tx_idx ON public.admin_audit (txid, action) WHERE txid IS NOT NULL;

-- ---------- Schreiben (nie das Hauptgeschehen stören) ----------
CREATE OR REPLACE FUNCTION public._audit_write(p_action text, p_target uuid, p_label text, p_details jsonb DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  insert into public.admin_audit (actor_id, actor_name, action, target_id, target_label, details, txid)
  values (v_uid, (select coalesce(username, email) from public.profiles where id = v_uid),
          p_action, p_target, p_label, p_details, txid_current());
exception when others then
  raise warning 'audit: %', sqlerrm;
end;
$function$;

-- Sammel-Eintrag: viele gleichartige Änderungen in EINER Transaktion (z. B. 240 neue Songs) = ein Eintrag mit Anzahl
CREATE OR REPLACE FUNCTION public._audit_bump(p_action text, p_playlist text, p_sample text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
  d jsonb;
  pl jsonb;
  smp jsonb;
begin
  select id, details into r from public.admin_audit
  where txid = txid_current() and action = p_action and coalesce(actor_id, '00000000-0000-0000-0000-000000000000') = coalesce(v_uid, '00000000-0000-0000-0000-000000000000')
  order by id desc limit 1;
  if found then
    d := coalesce(r.details, '{}'::jsonb);
    pl := coalesce(d -> 'playlists', '{}'::jsonb);
    pl := jsonb_set(pl, array[coalesce(p_playlist, '?')], to_jsonb(coalesce((pl ->> coalesce(p_playlist, '?'))::int, 0) + 1));
    smp := coalesce(d -> 'sample', '[]'::jsonb);
    if jsonb_array_length(smp) < 5 and p_sample is not null then smp := smp || to_jsonb(p_sample); end if;
    d := jsonb_build_object('count', coalesce((d ->> 'count')::int, 0) + 1, 'playlists', pl, 'sample', smp);
    perform set_config('kumpir.audit_maint', '1', true);
    update public.admin_audit set details = d where id = r.id;
    perform set_config('kumpir.audit_maint', '', true);
  else
    perform public._audit_write(p_action, null, null,
      jsonb_build_object('count', 1, 'playlists', jsonb_build_object(coalesce(p_playlist, '?'), 1),
                         'sample', case when p_sample is null then '[]'::jsonb else jsonb_build_array(p_sample) end));
  end if;
exception when others then
  perform set_config('kumpir.audit_maint', '', true);
  raise warning 'audit_bump: %', sqlerrm;
end;
$function$;

-- ---------- Manipulationsschutz ----------
CREATE OR REPLACE FUNCTION public._audit_immutable()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if coalesce(current_setting('kumpir.audit_maint', true), '') = '1' then
    return coalesce(NEW, OLD);
  end if;
  raise exception 'audit_immutable';
end;
$function$;
DROP TRIGGER IF EXISTS admin_audit_immutable ON public.admin_audit;
CREATE TRIGGER admin_audit_immutable BEFORE UPDATE OR DELETE ON public.admin_audit
  FOR EACH ROW EXECUTE FUNCTION public._audit_immutable();
DROP TRIGGER IF EXISTS admin_audit_no_truncate ON public.admin_audit;
CREATE TRIGGER admin_audit_no_truncate BEFORE TRUNCATE ON public.admin_audit
  FOR EACH STATEMENT EXECUTE FUNCTION public._audit_immutable();

-- ---------- Konten (profiles) ----------
CREATE OR REPLACE FUNCTION public._trg_audit_profile()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_other boolean;   -- jemand anderes (Admin-Funktion) ändert das Konto: die Funktion protokolliert selbst
  k text;
  keys text[] := '{}';
begin
  begin
    if TG_OP = 'INSERT' then
      perform public._audit_write('account_created', NEW.id, NEW.username,
        jsonb_build_object('email', NEW.email, 'role', NEW.role));
      return NEW;
    end if;

    if TG_OP = 'DELETE' then
      if v_uid is null then  -- über Admin-Funktion gelöscht = dort schon protokolliert
        perform public._audit_write('account_deleted', OLD.id, OLD.username,
          jsonb_build_object('email', OLD.email, 'role', OLD.role, 'status', OLD.status));
      end if;
      return OLD;
    end if;

    v_other := v_uid is not null and v_uid <> NEW.id;

    if not v_other then
      if NEW.username is distinct from OLD.username then
        perform public._audit_write('username_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.username, 'to', NEW.username));
      end if;
      if NEW.display_name is distinct from OLD.display_name then
        perform public._audit_write('display_name_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.display_name, 'to', NEW.display_name));
      end if;
      if NEW.avatar_emoji is distinct from OLD.avatar_emoji or NEW.avatar_color is distinct from OLD.avatar_color then
        perform public._audit_write('avatar_changed', NEW.id, NEW.username,
          jsonb_build_object('from', concat_ws(' ', OLD.avatar_emoji, OLD.avatar_color), 'to', concat_ws(' ', NEW.avatar_emoji, NEW.avatar_color)));
      end if;
      if NEW.preferences is distinct from OLD.preferences then
        for k in select distinct key from (
          select key from jsonb_each(coalesce(OLD.preferences, '{}'::jsonb)) o
            where coalesce(NEW.preferences, '{}'::jsonb) -> o.key is distinct from o.value
          union
          select key from jsonb_each(coalesce(NEW.preferences, '{}'::jsonb)) n
            where coalesce(OLD.preferences, '{}'::jsonb) -> n.key is distinct from n.value
        ) x loop keys := keys || k; end loop;
        perform public._audit_write('preferences_changed', NEW.id, NEW.username, jsonb_build_object('bereiche', to_jsonb(keys)));
      end if;
    end if;

    if NEW.email is distinct from OLD.email then
      perform public._audit_write('email_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.email, 'to', NEW.email));
    end if;
    if NEW.is_platform_admin is distinct from OLD.is_platform_admin then
      perform public._audit_write('platform_admin_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.is_platform_admin, 'to', NEW.is_platform_admin));
    end if;
    -- Rolle/Status: über Admin-Funktion/Löschantrag (auth.uid() gesetzt) steht es dort schon mit Namen im Protokoll;
    -- hier die Änderungen per Skript/SQL (z. B. restore-admin.mjs)
    if v_uid is null then
      if NEW.role is distinct from OLD.role then
        perform public._audit_write('role_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.role, 'to', NEW.role, 'via', 'Datenbank/Skript'));
      end if;
      if NEW.status is distinct from OLD.status then
        perform public._audit_write('status_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.status, 'to', NEW.status, 'via', 'Datenbank/Skript'));
      end if;
    end if;
  exception when others then
    raise warning 'audit profile: %', sqlerrm;
  end;
  return coalesce(NEW, OLD);
end;
$function$;

DROP TRIGGER IF EXISTS profiles_audit_ins ON public.profiles;
CREATE TRIGGER profiles_audit_ins AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public._trg_audit_profile();
DROP TRIGGER IF EXISTS profiles_audit_upd ON public.profiles;
CREATE TRIGGER profiles_audit_upd AFTER UPDATE ON public.profiles FOR EACH ROW
  WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION public._trg_audit_profile();
DROP TRIGGER IF EXISTS profiles_audit_del ON public.profiles;
CREATE TRIGGER profiles_audit_del AFTER DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public._trg_audit_profile();

-- ---------- Passwort (auth.users) ----------
CREATE OR REPLACE FUNCTION public._trg_audit_password()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  begin
    if NEW.encrypted_password is distinct from OLD.encrypted_password then
      perform public._audit_write('password_changed', NEW.id, (select username from public.profiles where id = NEW.id), null);
    end if;
  exception when others then
    raise warning 'audit password: %', sqlerrm;
  end;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS auth_users_audit_password ON auth.users;
CREATE TRIGGER auth_users_audit_password AFTER UPDATE OF encrypted_password ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public._trg_audit_password();

-- ---------- Songs ----------
CREATE OR REPLACE FUNCTION public._trg_audit_song()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_pl text;
  v_row record;
begin
  begin
    v_row := case when TG_OP = 'DELETE' then OLD else NEW end;
    select text into v_pl from public.topic_pool where id = v_row.topic_pool_id;
    if TG_OP = 'INSERT' then
      perform public._audit_bump('songs_added', v_pl, NEW.artist || ' – ' || NEW.title);
    elsif TG_OP = 'DELETE' then
      perform public._audit_bump('songs_removed', v_pl, OLD.artist || ' – ' || OLD.title);
    elsif auth.uid() is null then
      -- Archivieren/Zurückholen über das Admin-Panel steht dort schon mit Namen im Protokoll
      perform public._audit_bump('songs_changed', v_pl, NEW.artist || ' – ' || NEW.title);
    end if;
  exception when others then
    raise warning 'audit song: %', sqlerrm;
  end;
  return coalesce(NEW, OLD);
end;
$function$;
DROP TRIGGER IF EXISTS song_pool_audit_ins ON public.song_pool;
CREATE TRIGGER song_pool_audit_ins AFTER INSERT ON public.song_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_song();
DROP TRIGGER IF EXISTS song_pool_audit_del ON public.song_pool;
CREATE TRIGGER song_pool_audit_del AFTER DELETE ON public.song_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_song();
-- Nur echte Inhaltsänderungen (nicht die Zähler plays/hits, die bei jedem Spiel hochlaufen)
DROP TRIGGER IF EXISTS song_pool_audit_upd ON public.song_pool;
CREATE TRIGGER song_pool_audit_upd AFTER UPDATE OF topic_pool_id, title, artist, preview_url ON public.song_pool FOR EACH ROW
  WHEN (OLD.topic_pool_id IS DISTINCT FROM NEW.topic_pool_id OR OLD.title IS DISTINCT FROM NEW.title
        OR OLD.artist IS DISTINCT FROM NEW.artist OR OLD.preview_url IS DISTINCT FROM NEW.preview_url)
  EXECUTE FUNCTION public._trg_audit_song();

-- ---------- Playlists / Themen ----------
CREATE OR REPLACE FUNCTION public._trg_audit_playlist()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  begin
    if TG_OP = 'INSERT' then
      perform public._audit_write('playlist_changed', null, NEW.text, jsonb_build_object('aktion', 'angelegt', 'aktiv', NEW.active));
    elsif TG_OP = 'DELETE' then
      perform public._audit_write('playlist_changed', null, OLD.text, jsonb_build_object('aktion', 'gelöscht'));
    else
      perform public._audit_write('playlist_changed', null, NEW.text,
        jsonb_build_object('aktion', 'geändert', 'from', jsonb_build_object('name', OLD.text, 'aktiv', OLD.active),
                           'to', jsonb_build_object('name', NEW.text, 'aktiv', NEW.active)));
    end if;
  exception when others then
    raise warning 'audit playlist: %', sqlerrm;
  end;
  return coalesce(NEW, OLD);
end;
$function$;
DROP TRIGGER IF EXISTS topic_pool_audit_ins ON public.topic_pool;
CREATE TRIGGER topic_pool_audit_ins AFTER INSERT ON public.topic_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_playlist();
DROP TRIGGER IF EXISTS topic_pool_audit_del ON public.topic_pool;
CREATE TRIGGER topic_pool_audit_del AFTER DELETE ON public.topic_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_playlist();
DROP TRIGGER IF EXISTS topic_pool_audit_upd ON public.topic_pool;
CREATE TRIGGER topic_pool_audit_upd AFTER UPDATE OF text, active ON public.topic_pool FOR EACH ROW
  WHEN (OLD.text IS DISTINCT FROM NEW.text OR OLD.active IS DISTINCT FROM NEW.active)
  EXECUTE FUNCTION public._trg_audit_playlist();

-- ---------- Abgelaufene Lobbys (Aufräum-Aufgabe alle 10 Minuten) ----------
CREATE OR REPLACE FUNCTION public.cleanup_expired_lobbies()
 RETURNS void LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare n int;
begin
  delete from public.lobbies where last_activity_at < now() - interval '60 minutes';
  get diagnostics n = row_count;
  if n > 0 then
    perform public._audit_write('lobbies_expired', null, n || ' Lobby(s) nach 60 Min. ohne Aktivität', jsonb_build_object('count', n));
  end if;
end;
$function$;

-- ---------- Protokoll lesen: bis zu 2000 Einträge, mit Zeitstempel ----------
CREATE OR REPLACE FUNCTION public.admin_list_audit(p_limit integer DEFAULT 100)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return jsonb_build_object(
    'total', (select count(*) from public.admin_audit),
    'rows', coalesce((
      select jsonb_agg(a order by a."createdAt" desc, a.id desc) from (
        select id, created_at as "createdAt", actor_name as "actorName", action, target_id as "targetId", target_label as "targetLabel", details
        from public.admin_audit order by created_at desc, id desc limit greatest(1, least(coalesce(p_limit, 100), 2000))
      ) a
    ), '[]'::jsonb)
  );
end;
$function$;

-- Hilfsfunktionen sind intern
REVOKE ALL ON FUNCTION public._audit_write(text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._audit_bump(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._audit_immutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_profile() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_password() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_song() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_playlist() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cleanup_expired_lobbies() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_list_audit(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_audit(integer) TO authenticated;

COMMIT;


-- >>> 084_vote_card_count.sql <<<
-- ============================================================
-- 084: Playlist-Abstimmung passt sich der Zahl der gewählten Playlists an
-- ============================================================
--   3 oder mehr Playlists: wie bisher (Playlist A, Playlist B, Zufall-Karte)
--   genau 2 Playlists:     nur die beiden Karten A und B (keine Zufall-Karte)
--   genau 1 Playlist:      keine Abstimmung – es geht sofort in den Countdown
--
-- Umsetzung: lobbies.topic_vote_cards (1, 2 oder 3) wird gesetzt, sobald die Lobby in die Phase
-- 'topic_vote' wechselt (egal ob Start, nächste Runde oder Revanche). Bei einer Karte endet die
-- Abstimmung sofort; der Server-Takt bzw. jeder Client wertet aus. Spielregeln sonst unverändert.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS topic_vote_cards smallint NOT NULL DEFAULT 3;

CREATE OR REPLACE FUNCTION public._trg_vote_cards()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare n int;
begin
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from 'topic_vote' then
    n := coalesce(cardinality(public._vote_topic_pool(NEW.topic_filter)), 0);
    NEW.topic_vote_cards := least(3, greatest(n, 1));
    if n <= 1 then
      NEW.topic_vote_ends_at := now();   -- nur eine Playlist: nichts abzustimmen
      NEW.topic_b := NEW.topic_a;
    end if;
  end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS lobbies_vote_cards ON public.lobbies;
CREATE TRIGGER lobbies_vote_cards BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_vote_cards();

-- Stimme nur für vorhandene Karten
CREATE OR REPLACE FUNCTION public.rpc_vote_topic(p_lobby_id uuid, p_player_id uuid, p_choice integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cards int;
begin
  if p_choice not in (1,2,3) then raise exception 'Invalid choice %', p_choice; end if;

  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select topic_vote_cards into v_cards from public.lobbies where id = p_lobby_id;
  if p_choice > coalesce(v_cards, 3) then raise exception 'Invalid choice %', p_choice; end if;

  insert into public.topic_votes (lobby_id, player_id, choice)
  values (p_lobby_id, p_player_id, p_choice)
  on conflict (lobby_id, player_id)
  do update set choice = excluded.choice;
end;
$function$;

-- Auswertung: nur die vorhandenen Karten zählen
CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a text; v_b text; v_filter text[]; v_played text[]; v_starters uuid[]; v_cards int;
  v_cnt int[] := array[0, 0, 0];
  v_best int; v_tied int[] := '{}'; v_fresh int[] := '{}';
  v_pick int; v_selected text; v_choices int[]; v_starter uuid;
  v_rest text[]; i int; v_n int;
begin
  select topic_a, topic_b, topic_filter, series_topics, series_starters, topic_vote_cards
    into v_a, v_b, v_filter, v_played, v_starters, v_cards
  from public.lobbies where id = p_lobby_id and phase = 'topic_vote' for update;
  if not found then return; end if;
  if coalesce(current_setting('request.headers', true), '') <> '' and exists (select 1 from public.lobbies where id = p_lobby_id and topic_vote_ends_at > now() + interval '1 second') then return; end if;

  v_cards := least(3, greatest(coalesce(v_cards, 3), 1));
  if v_a is null then v_a := 'Thema A'; end if;
  if v_b is null then v_b := 'Thema B'; end if;

  for i in 1..v_cards loop
    select count(*) into v_n from public.topic_votes where lobby_id = p_lobby_id and choice = i;
    v_cnt[i] := v_n;
  end loop;

  v_best := greatest(v_cnt[1], v_cnt[2], case when v_cards >= 3 then v_cnt[3] else 0 end);
  for i in 1..v_cards loop
    if v_cnt[i] = v_best then v_tied := array_append(v_tied, i); end if;
  end loop;

  -- Zufalls-Karte: Themen außerhalb der beiden Karten (gibt es keine, bleibt A/B)
  v_rest := array(select x from unnest(public._vote_topic_pool(v_filter)) x where x <> v_a and x <> v_b);

  if v_cards = 1 then
    v_pick := 1;
    v_choices := null;
  elsif array_length(v_tied, 1) = 1 then
    v_pick := v_tied[1];
    v_choices := null;
  else
    -- Gleichstand: bevorzugt Optionen mit noch nicht gespieltem Thema
    foreach i in array v_tied loop
      if (i = 1 and not (v_a = any(v_played)))
         or (i = 2 and not (v_b = any(v_played)))
         or (i = 3 and (array_length(v_rest, 1) is null or exists (select 1 from unnest(v_rest) r where not (r = any(v_played)))))
      then v_fresh := array_append(v_fresh, i); end if;
    end loop;
    if array_length(v_fresh, 1) is null then v_fresh := v_tied; end if;
    v_pick := v_fresh[1 + floor(random() * array_length(v_fresh, 1))::int];
    v_choices := v_tied;
  end if;

  if v_pick = 1 then v_selected := v_a;
  elsif v_pick = 2 then v_selected := v_b;
  else
    v_selected := public._weighted_topic(v_rest, v_played);
    if v_selected is null then
      v_selected := public._weighted_topic(array[v_a, v_b], v_played);
    end if;
  end if;

  -- Startspieler: wer in diesem Match schon öfter gestartet hat, wird seltener gezogen
  select p.player_id into v_starter
  from public.players p
  where p.lobby_id = p_lobby_id and p.status = 'active' and p.is_alive = true
  order by -ln(greatest(random(), 1e-12)) * (1 + (select count(*) from unnest(v_starters) s where s = p.player_id))
  limit 1;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      series_topics = array_append(series_topics, v_selected),
      series_starters = case when v_starter is null then series_starters else array_append(series_starters, v_starter) end,
      countdown_starter_player_id = v_starter,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

-- Bots stimmen nur für vorhandene Karten
DO $do$
declare d text;
begin
  select pg_get_functiondef('public._bot_tick()'::regprocedure) into d;
  if position('select l.id as lobby_id, p.player_id, l.topic_vote_started_at' in d) = 0
     or position('1 + (abs(hashtext(''c'' || v_seed)) % 3)' in d) = 0 then
    raise exception '_bot_tick hat sich geändert – Patch prüfen';
  end if;
  d := replace(d, 'select l.id as lobby_id, p.player_id, l.topic_vote_started_at', 'select l.id as lobby_id, p.player_id, l.topic_vote_started_at, l.topic_vote_cards');
  d := replace(d, '1 + (abs(hashtext(''c'' || v_seed)) % 3)', '1 + (abs(hashtext(''c'' || v_seed)) % greatest(1, least(3, r.topic_vote_cards)))');
  execute d;
end
$do$;

COMMIT;


-- >>> 085_admin_quick_panel.sql <<<
-- ============================================================
-- 085: Admin-Schnellmenü (Pop-up)
-- ============================================================
--   admin_online_players()  – wer ist gerade verbunden (Mensch, in einer Lobby, Herzschlag < 90 s)
--   admin_kick_player(...)  – Spieler aus der Lobby werfen (Supporter + Admin), mit Protokoll-Eintrag
-- Sperren eines Kontos läuft weiter über admin_set_user_status (Migration 078).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_online_players()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(x order by x."lobbyCode", x.name) from (
      select p.player_id as "playerId", p.name, l.id as "lobbyId", l.code as "lobbyCode", l.phase,
             (l.host_player_id = p.player_id) as "isHost",
             p.user_id as "userId", pr.username, pr.role, pr.status as "accountStatus",
             p.last_seen_at as "lastSeen"
      from public.players p
      join public.lobbies l on l.id = p.lobby_id
      left join public.profiles pr on pr.id = p.user_id
      where p.status = 'active' and not coalesce(p.is_bot, false)
        and p.last_seen_at > now() - interval '90 seconds'
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_kick_player(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  r text := public._require_staff('supporter');
  v_name text; v_code text; v_user uuid; v_alive boolean; v_target_role text; v_username text;
begin
  select p.name, l.code, p.user_id, p.is_alive into v_name, v_code, v_user, v_alive
  from public.players p join public.lobbies l on l.id = p.lobby_id
  where p.lobby_id = p_lobby_id and p.player_id = p_player_id and p.status = 'active';
  if not found then raise exception 'player_not_found'; end if;

  if v_user is not null then
    select role, username into v_target_role, v_username from public.profiles where id = v_user;
    -- Supporter dürfen keine Admins rauswerfen
    if v_target_role = 'admin' and r <> 'admin' then raise exception 'not_authorized'; end if;
  end if;

  update public.players set status = 'kicked', kicked_at = now(), ready = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';

  perform public._on_player_exit(p_lobby_id, p_player_id, coalesce(v_alive, false));

  perform public._audit('player_kicked', v_user, v_name,
    jsonb_build_object('lobby', v_code, 'konto', v_username));
end;
$function$;

REVOKE ALL ON FUNCTION public.admin_online_players() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_online_players() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_kick_player(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_kick_player(uuid, uuid) TO authenticated;

COMMIT;


-- >>> 086_friends_presence.sql <<<
-- ============================================================
-- 086: Freunde mit Online-Status
-- ============================================================
--   user_presence        – wann war ein Konto zuletzt auf der Seite (nur über Funktionen les-/schreibbar)
--   touch_presence()     – "ich bin da" (Browser meldet sich ca. jede Minute)
--   get_friends_status() – meine Freunde mit Avatar, Online-Status und (falls in einer offenen Lobby) Lobby-Code
-- Online = in den letzten 150 s gemeldet ODER gerade in einer Lobby verbunden. Nur Freunde sehen das voneinander.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_presence (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_presence ENABLE ROW LEVEL SECURITY;  -- keine Policies: nur über Funktionen
REVOKE ALL ON public.user_presence FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.touch_presence()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then return; end if;
  insert into public.user_presence (user_id, last_seen_at) values (auth.uid(), now())
  on conflict (user_id) do update set last_seen_at = now()
  where public.user_presence.last_seen_at < now() - interval '20 seconds';
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_friends_status()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_me uuid := auth.uid();
begin
  if v_me is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by (x."online") desc, lower(x.username))
    from (
      select pr.id as "userId", pr.username, pr.display_name as "displayName",
             pr.avatar_emoji as "avatarEmoji", pr.avatar_color as "avatarColor",
             coalesce(up.last_seen_at > now() - interval '150 seconds', false) or lob.code is not null as "online",
             greatest(up.last_seen_at, lob.seen) as "lastSeen",
             lob.code as "lobbyCode", lob.phase as "lobbyPhase",
             coalesce(lob.phase = 'waiting' and not coalesce(lob.locked, false) and coalesce(lob.active_players, 0) < coalesce(lob.max_players, 0), false) as "joinable"
      from public.friendships f
      join public.profiles pr on pr.id = f.friend_user_id
      left join public.user_presence up on up.user_id = pr.id
      left join lateral (
        select l.code, l.phase, l.locked, l.max_players, p.last_seen_at as seen,
               (select count(*) from public.players q where q.lobby_id = l.id and q.status = 'active') as active_players
        from public.players p join public.lobbies l on l.id = p.lobby_id
        where p.user_id = pr.id and p.status = 'active' and p.last_seen_at > now() - interval '90 seconds'
        order by p.last_seen_at desc limit 1
      ) lob on true
      where f.user_id = v_me and f.status = 'accepted' and pr.status = 'active'
    ) x
  ), '[]'::jsonb);
end;
$function$;

REVOKE ALL ON FUNCTION public.touch_presence() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_presence() TO authenticated;
REVOKE ALL ON FUNCTION public.get_friends_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_friends_status() TO authenticated;

COMMIT;


-- >>> 087_deutschrap_aktuell_auswahl.sql <<<
-- Generiert von db/scripts/build-deutschrap.mjs (2026-10-07)
-- Playlist "Deutschrap aktuell": 164 Songs seit 2022-10-07, Beliebtheit laut Deezer, Vorschau/Datum laut iTunes
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap aktuell', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap aktuell');

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Archiv (deaktivierte Songs)', false, false
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)');

UPDATE public.song_pool s
SET archived_from = 'Deutschrap aktuell', topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)')
WHERE s.topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Deutschrap aktuell')
  AND lower(s.title) NOT IN ('chaos', 'ma baby', 'miami', 'breaking your heart', 'morgen', 'heb ab', 'niemals', 'seite an seite', 'was weißt du schon', 'loser', 'mann muss', 'rhythm', 'take it', 'gift', 'deutsche & kanaken', 'crazyyy', 'cold as ice', 'starboy', 'wolken', 'kaybeden', 'connected', 'lüg mich an', 'uçurum', 'count your blessings', 'ocean', 'superstars', 'uykusuz geceler', 'unsichtbar', 'moonlight dreams', 'do you lie', 'rücken an rücken', 'klatsch das!', 'all night', 'qualität', 'ich bring dir keine blumen', 'another vibe', 'pa mu', 'blue porsche', 'diamond ring', 'wenn der himmel weint', 'porsche 911', 'mount olympus', 'apres ski', 'vacation', 'immer', 'wenn das so bleibt', 'gesegnet', 'hold me down', 'ich liebe dich', 'blessed', '2 germans', 'malaga', 'dur gitme', 'malli', 'gib uns niemals auf', 'bullet', 'simpel', 'gunshot', 'time', 'bei nacht', 'doktor', 'gebete', 'blanco', 'ice', 'stern', 'el fenomeno', 'lovebomb', 'dreckig & gemein', 'mira', 'vorbei', 'imaginando', 'let''s go', 'mungu', 'lowlife', 'rauch', 'damals', 'hade', 'blutbad', 'heute nacht', 'sor bize', 'in meiner dna', 'happy birthday', 'mind on my $$$', 'manchmal', 'ararım yarın', 'pasha nanen', 'bei dir', 'herz aus stein', 'hokus pokus', 'millieu 26', 'ti amo', 'normal zu lieben', 'barbie & ken', 'weiße orchideen', 'beretta', 'strassenmelodie', 'sober', 'sternhimmeldach', 'valium', 'asozialer araber', 'dale', 'baby mama', 'ich mach es', 'highlight', 'plaza', 'better dayz', 'irgendwann', 'schlechter empfang', 'tagebuch', 'immer unterwegs', 'odyssee', 'papaya', 'sayfa', 'bang', 'weekend', 'plus eins', 'flügel', 'habibi', 'alemania', 'bielefeld', 'du fehlst', 'model', 'la 3youne', 'mahalle', 'vija vija', 'buonasera', 'sommerregen', 'ozean', 'glizzy', 'uuu', 'discokugel', 'planet', '0uhr26', 'usdt', 'drück', 'ring ring', 'mavi', 'stress ohne grund', 'kein geld der welt', 'caliente', 'hol mir deine cousine', 'mailand', 'maghreb united', 'beef', 'el naseeni', 'dilemin', 'lambada', 'la la la', 'primetime', 'jemand wie dich', 'was ist los?!', 'dum dum', 'hautfarbe cappuccino', 'bon voyage ii', 'blockbanden', 'einbahnstrasse', 'classic', 'regen auf der fahrbahn', 'für die kamera', 'unglaublich', 'liebe & hass', 'e jemja', 'i love you', '7 sitzer');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Chaos', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/3b/3f/5a3b3f8b-e370-5a97-d806-cbf95d77b3c9/mzaf_15555307926128862577.plus.aac.p.m4a'),
    ('Ma Baby', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/18/4f/66/184f66fb-5c57-96aa-f728-f3d39bc85e19/mzaf_1352664921887866745.plus.aac.p.m4a'),
    ('Miami', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c5/1b/48/c51b4815-77f4-c6db-9688-1aaa10cce30b/mzaf_2294655937865324949.plus.aac.p.m4a'),
    ('Breaking your heart', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/96/e7/02/96e702d6-1166-5275-fc58-38eb199456c6/mzaf_10767789362673437085.plus.aac.p.m4a'),
    ('Morgen', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ed/fc/04/edfc04e8-6686-9b48-ad87-5e61b83cd828/mzaf_7976620730799509042.plus.aac.p.m4a'),
    ('Heb ab', 'Miami Yacine & Nash', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/96/4b/93/964b9392-fceb-1702-3513-d370971172cd/mzaf_3561495639029066177.plus.aac.p.m4a'),
    ('Niemals', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/44/b3/fe/44b3fee5-c732-b2db-4fe2-7d911219e0b3/mzaf_13839186796549365331.plus.aac.p.m4a'),
    ('Seite an Seite', 'Gzuz, Sido & JBS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/be/a2/5abea297-e1e3-cfc7-19b9-63f3e7a594d6/mzaf_17474436214410174220.plus.aac.p.m4a'),
    ('Was weißt du schon', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/f1/12/4cf112c9-9542-a5c3-1a15-670df740252c/mzaf_14031678196973356104.plus.aac.p.m4a'),
    ('Loser', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5d/70/e4/5d70e4ff-9d84-274d-653e-ece6da7990e2/mzaf_11480468985571129709.plus.aac.p.m4a'),
    ('Mann muss', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/19/ec/9019ec13-9bb5-3f5f-6a10-3d8a0e65ffbb/mzaf_9428726307364356336.plus.aac.p.m4a'),
    ('Rhythm', 'SIRA, Aymen & NiklasWilson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/10/a8/8f/10a88f93-1082-0a00-1bfd-5866e0efb226/mzaf_10604194046169191608.plus.aac.p.m4a'),
    ('Take it', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a3/a6/89/a3a689a3-a202-71c7-3738-b5e90206bd6a/mzaf_3499770739931437883.plus.aac.p.m4a'),
    ('Gift', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/44/81/f9/4481f964-0b7f-94e0-35d7-565d86a6a57c/mzaf_13676693610091644511.plus.aac.p.m4a'),
    ('Deutsche & Kanaken', 'Lupo Kadafi, Gzuz & Don Alfonso', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e2/fe/01/e2fe0135-e797-7bf8-d3e6-5ead76a8d31b/mzaf_14097492907906165785.plus.aac.p.m4a'),
    ('CRAZYYY', 'Jazeek & SAMIRA', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a6/02/4c/a6024c8b-27d2-d1fd-2f5b-f1e7090a39c2/mzaf_12572414024205480940.plus.aac.p.m4a'),
    ('Cold as Ice', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/54/3a/94/543a94c5-270a-a542-0b99-98b617ce825b/mzaf_9177537511829347062.plus.aac.p.m4a'),
    ('Starboy', 'Luciano & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bc/dd/b5/bcddb5ad-25b3-a5eb-d151-92d5aa72236d/mzaf_11953846642540958986.plus.aac.p.m4a'),
    ('Wolken', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b3/ae/a1/b3aea1d0-2ca1-3097-196e-49a967091941/mzaf_18382696023718163837.plus.aac.p.m4a'),
    ('Kaybeden', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/61/f1/61/61f1612e-f0ea-e68b-d16c-eb7b37b8ecac/mzaf_18394005841854612931.plus.aac.p.m4a'),
    ('CONNECTED', 'RAF Camora & reezy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5e/69/15/5e6915d3-b776-a840-916e-e8b4f2b2cf37/mzaf_11291496925532574361.plus.aac.p.m4a'),
    ('Lüg mich an', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a0/08/ab/a008ab21-2a95-9247-216f-76c6b9d5955d/mzaf_2918240860667383299.plus.aac.p.m4a'),
    ('Uçurum', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/70/73/ad/7073ad01-c0e1-9c36-9303-488b93df7e24/mzaf_1402708318679479816.plus.aac.p.m4a'),
    ('Count your blessings', 'Sa4 & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d2/af/44/d2af4402-ce9f-b9bf-7610-d99282427cb5/mzaf_3905975321627425060.plus.aac.p.m4a'),
    ('OCEAN', 'RAF Camora & Ufo361', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/ac/66/dfac669a-9c2d-0b4c-86b6-70f8d97b8476/mzaf_12513037025792429953.plus.aac.p.m4a'),
    ('Superstars', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/63/08/b7/6308b70d-66f5-805e-df93-a8f80ff525a6/mzaf_9432127935537316648.plus.aac.p.m4a'),
    ('Uykusuz Geceler', 'MERO & Ati242', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dc/25/4b/dc254bf2-51a6-0afb-518d-6d3b41799911/mzaf_11278876578683307450.plus.aac.p.m4a'),
    ('Unsichtbar', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ed/ef/dc/edefdcca-fd31-fae5-8c41-41bcdd3ec3ad/mzaf_13331952717199721520.plus.aac.p.m4a'),
    ('Moonlight Dreams', 'YAKARY & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/50/19/20/50192055-4ae8-5949-7542-9b10239c0782/mzaf_17242896264389125404.plus.aac.p.m4a'),
    ('Do you lie', 'Jazeek & Milano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b4/f5/e5/b4f5e54c-f2fa-d305-6eae-1b57960e57c4/mzaf_15871608143001105174.plus.aac.p.m4a'),
    ('Rücken an Rücken', 'Aymo, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a1/a4/78/a1a4789d-af4c-3b34-027c-d9851ab77a26/mzaf_1440609807246252587.plus.aac.p.m4a'),
    ('KLATSCH DAS!', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ca/38/55/ca3855e0-7ae4-e579-095e-059c61ac47b1/mzaf_8076816444243589241.plus.aac.p.m4a'),
    ('All Night', 'Luciano & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/47/bf/0e/47bf0e37-81e8-ecab-d6b6-3dbc016f21c6/mzaf_17394255442885241084.plus.aac.p.m4a'),
    ('QUALITÄT', 'Sonus030 & AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/50/cc/55/50cc5540-27da-7df3-0504-917104a66a9f/mzaf_8507909491805445600.plus.aac.p.m4a'),
    ('Ich bring dir keine Blumen', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/46/e0/7b/46e07b3f-6db0-05d6-ee5f-6f6235268f84/mzaf_9947818941896906192.plus.aac.p.m4a'),
    ('Another Vibe', 'Luciano & OMAH LAY', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/79/34/ad/7934ad7c-6673-f7cd-db0b-b3e2d52e2153/mzaf_15466577134704794977.plus.aac.p.m4a'),
    ('Pa Mu', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/3a/f6/c63af622-f445-b3e5-c112-1cd7ac6a8e7f/mzaf_3790178152675825614.plus.aac.p.m4a'),
    ('Blue Porsche', 'Luciano & Niska', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c3/03/04/c3030497-71ce-9419-6e17-9247790757e0/mzaf_662272406190326409.plus.aac.p.m4a'),
    ('Diamond Ring', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7e/fd/cc/7efdcc5c-bfd3-77f0-2407-1463372f37ad/mzaf_1233320865206940885.plus.aac.p.m4a'),
    ('Wenn der Himmel weint', 'Bausa & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b0/5b/83/b05b8329-32c6-e042-71d6-95fd02e4cd4f/mzaf_17672995787847521681.plus.aac.p.m4a'),
    ('Porsche 911', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/29/ee/9f/29ee9f34-6c83-3487-05a1-4273a3eca0a3/mzaf_8018353666506207557.plus.aac.p.m4a'),
    ('MOUNT OLYMPUS', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fd/d7/02/fdd70222-f8e9-c4cd-a5a6-24d54399bb46/mzaf_17064011775218990603.plus.aac.p.m4a'),
    ('APRES SKI', 'Tream & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/bc/92/92/bc929291-9570-b23f-54a9-97fa9ca5bee5/mzaf_10615365935077484116.plus.aac.p.m4a'),
    ('VACATION', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/57/c4/e5/57c4e5a5-084d-3133-5f06-49c40fd60a43/mzaf_17719970761118631110.plus.aac.p.m4a'),
    ('Immer', 'Jazeek & DYSTINCT', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/14/43/d2144319-cf5b-b769-92c5-b2e941106808/mzaf_595829568338537564.plus.aac.p.m4a'),
    ('Wenn das so bleibt', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/16/2b/1a/162b1a1b-7e1a-b983-3824-41c559013cfe/mzaf_6020846386956878027.plus.aac.p.m4a'),
    ('Gesegnet', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ea/5b/73/ea5b7364-d204-2ca2-ae7e-729246e92f1f/mzaf_7356541788179685318.plus.aac.p.m4a'),
    ('HOLD ME DOWN', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ad/f3/69/adf3699b-0c2d-0a93-84ac-dd403485c236/mzaf_11582948286059152582.plus.aac.p.m4a'),
    ('Ich Liebe Dich', 'Samra & Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ad/ee/30/adee30bf-2313-1314-4f15-88648ac72162/mzaf_479953202844730391.plus.aac.p.m4a'),
    ('Blessed', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a2/00/b7/a200b7bf-4279-d056-a0ae-f6a8827881d1/mzaf_18168927866089581357.plus.aac.p.m4a'),
    ('2 Germans', 'Luciano & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f3/d9/5f/f3d95f31-2c0a-98b0-16a8-0adeca3c71d5/mzaf_8928989082293985026.plus.aac.p.m4a'),
    ('Malaga', 'Aymen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/13/fd/6f/13fd6fa1-370d-d1be-3f96-dfffe8514f76/mzaf_16885909096574483141.plus.aac.p.m4a'),
    ('Dur gitme', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/48/ce/21/48ce2190-5c54-6ece-01a7-ddaea5364c26/mzaf_3316860205134164664.plus.aac.p.m4a'),
    ('Malli', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/63/c3/df63c3a6-c4ac-ce85-ea3e-4af63b069230/mzaf_15135499478839051035.plus.aac.p.m4a'),
    ('Gib uns niemals auf', 'Hava & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/49/7f/be/497fbefc-57c9-abd7-c3da-5e11cd4d3a88/mzaf_3320579638543591468.plus.aac.p.m4a'),
    ('Bullet', 'MERO & AYLIVA', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9c/8d/91/9c8d9193-745b-0af1-2e08-1fff1a6fdde6/mzaf_3841862161557108035.plus.aac.p.m4a'),
    ('Simpel', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/60/8f/48/608f48bc-6597-e943-b484-6da8193f2117/mzaf_1009043656935833073.plus.aac.p.m4a'),
    ('GUNSHOT', 'Eno & Olexesh', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e0/40/37/e04037c7-5f6c-1bd6-0df2-59881e694c42/mzaf_10998222718601598764.plus.aac.p.m4a'),
    ('Time', 'Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fb/5d/87/fb5d872f-f18b-9587-39e9-3ed5b7cb2d5d/mzaf_14490002942984877311.plus.aac.p.m4a'),
    ('Bei Nacht', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b6/bd/42/b6bd4202-2553-9aa8-00b3-71d20c2127b8/mzaf_9072479678311111131.plus.aac.p.m4a'),
    ('Doktor', 'PA Sports, Sido, Haftbefehl & Alies', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/40/15/4c401580-708e-8d4e-d1a4-fe9c7a08af66/mzaf_12482896108109383756.plus.aac.p.m4a'),
    ('Gebete', 'RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/91/d8/0091d803-c040-58c2-1f44-8e053f31db5d/mzaf_7572544460874239446.plus.aac.p.m4a'),
    ('Blanco', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7c/08/e3/7c08e334-425a-6061-a76d-eed07a417212/mzaf_12155294836401644578.plus.aac.p.m4a'),
    ('ICE', 'MERO & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/eb/16/cf/eb16cf6b-1753-ad7e-8061-5e5382f9e18b/mzaf_6524550815768888568.plus.aac.p.m4a'),
    ('STERN', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e2/1c/b8/e21cb888-6b52-7696-5e25-9ef20fdf6dbf/mzaf_6301867712581873308.plus.aac.p.m4a'),
    ('EL FENOMENO', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/ed/9c/00ed9c75-a8f1-46f7-8282-1340dc9a1c6b/mzaf_3715258946467331101.plus.aac.p.m4a'),
    ('LOVEBOMB', 'Jamule, Sido & Miksu / Macloud', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1c/5e/ba/1c5eba83-fa65-2e92-550b-9939c4f657fc/mzaf_12278393253279906826.plus.aac.p.m4a'),
    ('Dreckig & Gemein', 'Kontra K & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a6/92/90/a692903f-d0fb-ed0a-6b4a-c4c83c02b8c5/mzaf_4353049620056260625.plus.aac.p.m4a'),
    ('Mira', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c3/11/f2/c311f26d-75d9-bc05-593c-460db824de65/mzaf_18362130171740636230.plus.aac.p.m4a'),
    ('Vorbei', 'Robin Schulz, RAF Camora, Montez & Dario Rodriguez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/87/9b/3e/879b3e1c-8cb4-a6bb-aff2-8f07403ba177/mzaf_1516059861525404433.plus.aac.p.m4a'),
    ('Imaginando', 'Eno, Morad & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/15/84/a5158479-abb7-969e-faa4-df2aa4123765/mzaf_5263152839562531237.plus.aac.p.m4a'),
    ('Let''s Go', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/07/ae/57/07ae573e-222f-a123-bae2-2d8863ae93be/mzaf_7309876885742509461.plus.aac.p.m4a'),
    ('Mungu', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d4/e2/12/d4e212c8-a81d-eaba-ca24-d2262b07fc47/mzaf_13904135254925487554.plus.aac.p.m4a'),
    ('LOWLIFE', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/95/fb/34/95fb340c-e2df-4d30-d41e-9e0644955e7f/mzaf_1348284490872911620.plus.aac.p.m4a'),
    ('Rauch', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fa/30/b3/fa30b361-18ba-b9ed-df9c-99d55d248bdf/mzaf_10404839895522640714.plus.aac.p.m4a'),
    ('Damals', 'Aymen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cb/d4/3c/cbd43c19-75f8-4235-7ed2-71fc71cf22b1/mzaf_12453833949439085787.plus.aac.p.m4a'),
    ('Hade', 'KC Rebell, Eno & Hakim Lokman', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a5/7c/af/a57caf64-4dde-9fde-d58d-7e0b456bb576/mzaf_11383866726658884140.plus.aac.p.m4a'),
    ('Blutbad', 'AMO & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ee/a7/2d/eea72de7-0568-49d3-32f4-891f25dba90b/mzaf_14189828146150700813.plus.aac.p.m4a'),
    ('HEUTE NACHT', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b3/ea/e9/b3eae99b-5092-3d3d-4a3c-9b96386d65e2/mzaf_1441601545411226452.plus.aac.p.m4a'),
    ('Sor Bize', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/29/b7/fc/29b7fc45-e1a0-94b1-457c-b4ab5c33fe34/mzaf_10753538560032951085.plus.aac.p.m4a'),
    ('IN MEINER DNA', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/dc/bb/e1/dcbbe133-0c47-6f8d-368f-cfab6cf27214/mzaf_12546886472788241672.plus.aac.p.m4a'),
    ('Happy Birthday', 'SANNA & KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview123/v4/0c/4d/ce/0c4dce3c-da9a-304e-d1f1-97394fcb96e3/mzaf_484295918791478171.plus.aac.p.m4a'),
    ('MIND ON MY $$$', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6e/85/1b/6e851bfb-03dd-6679-c22f-d82364a909b4/mzaf_3366244369010142205.plus.aac.p.m4a'),
    ('Manchmal', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/37/2a/dd/372add09-902b-7c3e-b8be-c5e2079c196b/mzaf_9984244776565485716.plus.aac.p.m4a'),
    ('Ararım Yarın', 'Murda & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1e/1d/14/1e1d14ec-5645-6d29-870c-2eccc59f886d/mzaf_17338544245438323162.plus.aac.p.m4a'),
    ('Pasha Nanen', 'Zuna & THIS IS DARDY', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/85/db/06/85db06fc-189b-b0de-d814-b4587486c6d0/mzaf_338615190257956012.plus.aac.p.m4a'),
    ('Bei dir', 'Jamule & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0d/56/f7/0d56f774-5530-c710-eafb-21b4cea67b77/mzaf_3093789863475407207.plus.aac.p.m4a'),
    ('Herz aus Stein', 'Estikay, Samra & SANTOS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/77/c0/d4/77c0d42f-d0b5-6d67-6392-9674fd05fef0/mzaf_9099777111903076764.plus.aac.p.m4a'),
    ('HOKUS POKUS', 'Kurdo & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/69/a1/d7/69a1d7ab-1a75-ad76-4c2f-4fadbd16b429/mzaf_15620536077385099501.plus.aac.p.m4a'),
    ('Millieu 26', 'Kolja Goldstein & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/25/7c/f9/257cf9af-d138-c04b-ec2d-14ce685b1d0b/mzaf_6109046488295430534.plus.aac.p.m4a'),
    ('Ti Amo', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f8/e4/98/f8e4982a-2bda-ddc2-8170-c77c6c3086a9/mzaf_4522595372364098278.plus.aac.p.m4a'),
    ('Normal zu lieben', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview123/v4/7c/21/83/7c218369-aea0-4812-6846-55bc2f1dc43e/mzaf_13093781519628213744.plus.aac.p.m4a'),
    ('Barbie & Ken', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/99/69/04/996904c7-b9a1-4a8b-ddda-e7534bab9e89/mzaf_2524642872684901284.plus.aac.p.m4a'),
    ('Weiße Orchideen', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a7/76/d1/a776d1a8-58b2-5a56-8683-580a147f029c/mzaf_11956202380289994444.plus.aac.p.m4a'),
    ('Beretta', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/fb/62/87/fb628789-b7ca-e377-dbd7-614d42a75add/mzaf_10549660590872910506.plus.aac.p.m4a'),
    ('Strassenmelodie', 'Miami Yacine & SRNO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/40/e5/fb/40e5fb69-fe30-efdc-29d2-8615de161d5b/mzaf_13602128457672147082.plus.aac.p.m4a'),
    ('SOBER', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/55/6d/1f/556d1f5d-473d-bc0b-dede-8110ff3fa2a3/mzaf_14782195066701509251.plus.aac.p.m4a'),
    ('STERNHIMMELDACH', 'BOJAN & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e4/73/58/e4735896-0800-4517-8f11-e6e6d6465e67/mzaf_18283054740411781302.plus.aac.p.m4a'),
    ('Valium', '1986zig & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/98/10/de/9810de2f-5eb2-d7c3-4a01-ac1a33898a7e/mzaf_10166741569885775122.plus.aac.p.m4a'),
    ('Asozialer Araber', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/06/c9/32/06c93209-0b8c-856c-d752-32a611806f4c/mzaf_6983262192757295817.plus.aac.p.m4a'),
    ('Dale', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/65/44/7e/65447e38-3b73-4c3d-3f52-7db8bd18b00d/mzaf_5785039631957696441.plus.aac.p.m4a'),
    ('Baby Mama', 'Saliou & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/45/ed/60/45ed6082-5f22-65a3-987c-8b0bc9b64e6a/mzaf_286500367577267129.plus.aac.p.m4a'),
    ('ICH MACH ES', 'AK AUSSERKONTROLLE & Undacava', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/87/03/17/87031742-614f-f5ff-da36-dd53a0559d4a/mzaf_16238059611758974715.plus.aac.p.m4a'),
    ('Highlight', 'Dardan & Jamin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/4c/94/c1/4c94c18e-9087-ddea-ad96-8fd9e8b065ee/mzaf_1200630864984026125.plus.aac.p.m4a'),
    ('Plaza', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/31/7b/f5/317bf58a-0ca0-ad37-4cee-3bcc7d53354f/mzaf_2357910546520271752.plus.aac.p.m4a'),
    ('BETTER DAYZ', 'Summer Cem & Geenaro & Ghana Beats', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/29/b9/9029b96f-d613-0b83-78e8-79fa02fefb36/mzaf_17349856476015755068.plus.aac.p.m4a'),
    ('Irgendwann', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6f/ef/4a/6fef4aae-9508-50d1-c9d9-ee18d3b3526a/mzaf_7920455585732442865.plus.aac.p.m4a'),
    ('Schlechter Empfang', 'Eno, Nizi19 & Bawer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/33/d6/e3/33d6e353-fbf4-be28-a71d-d82e3563c39f/mzaf_9238309832954595394.plus.aac.p.m4a'),
    ('Tagebuch', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/52/e2/6a52e21f-ddf8-da3e-3ec4-84c6fffedbfa/mzaf_11363355878459504484.plus.aac.p.m4a'),
    ('IMMER UNTERWEGS', 'AK AUSSERKONTROLLE & Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cc/4c/ef/cc4cefcc-76c0-ba28-c727-3f6b27107a87/mzaf_1171581247820736063.plus.aac.p.m4a'),
    ('Odyssee', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/65/1f/48/651f4816-fe2d-3064-f963-b3ebd973f5c0/mzaf_7670773666622268651.plus.aac.p.m4a'),
    ('Papaya', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d0/1c/ae/d01cae60-fcfc-b68d-bd26-4385f02b3ffa/mzaf_6945943440048941783.plus.aac.p.m4a'),
    ('SAYFA', 'KC Rebell, ERAY067 & MANSUR', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/c4/32/adc43260-2cca-1ae7-d2c6-8e91690fad03/mzaf_14594639550616219058.plus.aac.p.m4a'),
    ('Bang', 'Avie, Delil & Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9a/54/5f/9a545f35-04b6-ce4b-e77c-ad9fa62fdc80/mzaf_5353498550943481217.plus.aac.p.m4a'),
    ('WEEKEND', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/50/62/d2/5062d2fc-2dc6-426d-cb14-f115402d2e2a/mzaf_13257673340527140850.plus.aac.p.m4a'),
    ('PLUS EINS', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2e/3b/a6/2e3ba668-72ec-2bec-c003-d0bc736d3314/mzaf_7810233548907997281.plus.aac.p.m4a'),
    ('FLÜGEL', 'Capital Bra & Samo104', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e2/f5/e7/e2f5e7a1-aa7d-cec9-a236-01309a0feb05/mzaf_283694240929386023.plus.aac.p.m4a'),
    ('HABIBI', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bc/ab/a8/bcaba8ac-d2d0-5d3d-2c3c-6bc62be4e4aa/mzaf_1142964363303506908.plus.aac.p.m4a'),
    ('Alemania', 'Jamule & SRNO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/76/0d/ed/760ded97-7a91-c3fb-0a01-f59426249167/mzaf_4444291828857320283.plus.aac.p.m4a'),
    ('BIELEFELD', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/cc/11/58/cc11588c-a34f-34f4-61a4-a674b4636717/mzaf_16263017425410838093.plus.aac.p.m4a'),
    ('DU FEHLST', 'Kurdo & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1b/6f/a6/1b6fa625-fa7e-380f-cfd7-5fbd69c6ee2a/mzaf_17553965928552408157.plus.aac.p.m4a'),
    ('Model', 'RAF Camora, Dardan & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ba/94/eb/ba94eba7-8fb5-3497-792c-44ca5e3ec580/mzaf_17263892315971117117.plus.aac.p.m4a'),
    ('La 3youne', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/75/24/c4/7524c492-177a-32ef-cf47-3bceea835803/mzaf_12543184924114294351.plus.aac.p.m4a'),
    ('MAHALLE', 'Cave & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/cd/14/7a/cd147a28-ac58-5bf1-bada-1d8792d449ce/mzaf_4867614436575811670.plus.aac.p.m4a'),
    ('VIJA VIJA', 'DJ Gimi-O & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/6e/f8/8a/6ef88ab5-5d91-6e9f-8937-6bdd2513258e/mzaf_17128033351433615102.plus.aac.p.m4a'),
    ('Buonasera', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c4/f7/65/c4f765c3-42b9-1e1d-17f8-3562239d0ac4/mzaf_8614215666656592719.plus.aac.p.m4a'),
    ('Sommerregen', 'SRNO & Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8c/c3/82/8cc3827d-8b10-64f5-7819-483ab1ab937f/mzaf_9003414316984527837.plus.aac.p.m4a'),
    ('Ozean', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d9/a6/fc/d9a6fc1a-d4f0-258c-1582-eb41171a37a0/mzaf_3715534556376139007.plus.aac.p.m4a'),
    ('Glizzy', 'Jamule & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/d7/e7/a5d7e7cd-e597-3406-8c70-df4d6be65524/mzaf_8582882596024662500.plus.aac.p.m4a'),
    ('UUU', 'NOAH & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/5d/aa/bb/5daabbf6-0991-8b0b-73e6-9f9da9a49fe7/mzaf_1423466242667668057.plus.aac.p.m4a'),
    ('Discokugel', 'Gustav, NOAH & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/1a/cf/11/1acf11c0-be0a-b4e4-008d-494b8dcfaf40/mzaf_15125068063405641959.plus.aac.p.m4a'),
    ('Planet', 'Berky & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ae/61/88/ae61884a-e854-a1da-0580-a3d760dff0a6/mzaf_14024351611993764792.plus.aac.p.m4a'),
    ('0Uhr26', 'Capital Bra & Lucry & Suena', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/7d/54/f3/7d54f3fb-7e27-d05a-3ffd-581102c0ce09/mzaf_1107396209393777173.plus.aac.p.m4a'),
    ('USDT', 'Haaland936 & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a6/21/5e/a6215e41-55b9-ef5d-ff80-75f8b19e16f2/mzaf_8284436615119124255.plus.aac.p.m4a'),
    ('DRÜCK', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/67/6c/87/676c8727-d173-4556-feed-56d88157f1aa/mzaf_2272216899427668193.plus.aac.p.m4a'),
    ('Ring Ring', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/83/f4/d283f42b-171b-98ab-9740-ac70abdafd57/mzaf_6864107917543808666.plus.aac.p.m4a'),
    ('MAVI', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c8/7d/42/c87d4253-aebe-c7e5-573b-d7cd532e851f/mzaf_10798492575093691513.plus.aac.p.m4a'),
    ('STRESS OHNE GRUND', 'Majoe, Zombic & District Red', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f4/b0/45/f4b045da-fda7-083d-f049-85c3a6a28d94/mzaf_3949487449278880155.plus.aac.p.m4a'),
    ('Kein Geld der Welt', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/17/54/96/1754963b-71d3-a189-56ba-f64dfc4c5a24/mzaf_8238011803299039018.plus.aac.p.m4a'),
    ('Caliente', 'Zuna & Shabab', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/37/f0/30/37f030a3-0267-eb25-4cda-e9c72585f01a/mzaf_5217201572072935778.plus.aac.p.m4a'),
    ('Hol mir deine Cousine', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b7/43/ee/b743ee3c-a76d-0cdd-fe2e-2bd7ba1d3a0d/mzaf_9556768465452639955.plus.aac.p.m4a'),
    ('Mailand', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/99/b4/f6/99b4f677-2759-846e-de76-8c8d6c59f3e1/mzaf_12766038301063344791.plus.aac.p.m4a'),
    ('MAGHREB UNITED', 'Ataypapi, ILO 7ARAGA, Miami Yacine & YONII', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d5/25/1d/d5251ddd-a495-c86a-fd86-bf2812a8588a/mzaf_1522284100641962249.plus.aac.p.m4a'),
    ('BEEF', 'OZAN BRA & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/01/f1/ba/01f1ba79-d345-28cd-c984-2cc959c5bd59/mzaf_1657306145062003025.plus.aac.p.m4a'),
    ('El Naseeni', 'Capital Bra & Ilatch', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/0a/8a/a4/0a8aa4b3-f0f5-329b-72ba-95190e87c7b8/mzaf_8331300202345863870.plus.aac.p.m4a'),
    ('DILEMIN', 'Eno & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a2/d5/5a/a2d55a1b-65a1-c3ff-79c6-e95faa41793a/mzaf_499600063130735107.plus.aac.p.m4a'),
    ('LAMBADA', 'Eno & Ataypapi', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f1/30/a2/f130a221-3455-27e6-1e8a-7e0efaf2b05a/mzaf_2641231104817836374.plus.aac.p.m4a'),
    ('La La La', 'Remoe & Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/2b/cd/50/2bcd50b6-0265-ff73-e327-5f06b6b4a178/mzaf_12488055406248125529.plus.aac.p.m4a'),
    ('Primetime', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d1/c6/9e/d1c69eb7-5154-3c76-104e-b4210c943fe9/mzaf_2485236636118152565.plus.aac.p.m4a'),
    ('JEMAND WIE DICH', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/62/ad/9a/62ad9a96-dda6-b510-6032-bf974569fe47/mzaf_13560684668608902982.plus.aac.p.m4a'),
    ('WAS IST LOS?!', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2c/a7/84/2ca784cf-7e63-c118-6018-f9f845269666/mzaf_10747796428684819033.plus.aac.p.m4a'),
    ('Dum Dum', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/52/45/f6/5245f6ac-5a3d-8975-6670-7998141f0390/mzaf_10441706360362357835.plus.aac.p.m4a'),
    ('Hautfarbe Cappuccino', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/fc/43/61/fc436194-f504-529a-be0b-99100dce0221/mzaf_8764121993852182512.plus.aac.p.m4a'),
    ('Bon Voyage II', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/38/6b/ff/386bffdf-b8ff-4df9-8885-a8c121ec8778/mzaf_16122372931988548775.plus.aac.p.m4a'),
    ('BLOCKBANDEN', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview123/v4/17/df/9b/17df9bf7-c12b-dcd7-1eee-f4c48e57fc9b/mzaf_7743347812085434616.plus.aac.p.m4a'),
    ('EINBAHNSTRASSE', 'Majoe & Madlin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9a/e7/fb/9ae7fb11-ce67-dc97-d9e9-2ab7579da2b7/mzaf_2311748501708847467.plus.aac.p.m4a'),
    ('CLASSIC', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/02/27/f3/0227f30e-e654-15f3-9651-d23237b16f5b/mzaf_4322190388412081195.plus.aac.p.m4a'),
    ('REGEN AUF DER FAHRBAHN', 'Capital Bra, Sido & GRiNGO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/65/8a/e2/658ae2f7-d5e2-8d20-c995-2d85decbf182/mzaf_15068873530823684149.plus.aac.p.m4a'),
    ('Für die Kamera', 'Miami Yacine & Nash', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/d3/01/add3017f-2467-24ca-a299-f29bd970e04d/mzaf_15971102917953269827.plus.aac.p.m4a'),
    ('UNGLAUBLICH', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/eb/c6/18/ebc6184c-3653-d7eb-96ea-15b750d70de5/mzaf_2328194127208676826.plus.aac.p.m4a'),
    ('LIEBE & HASS', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/be/ff/b4/beffb423-0931-5c19-843c-f928b60266b6/mzaf_5599497847680839048.plus.aac.p.m4a'),
    ('E Jemja', 'Zuna & Majk', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b9/72/be/b972be0c-eca8-5383-ee55-9092546368ae/mzaf_1739745588208430147.plus.aac.p.m4a'),
    ('I Love You', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/c1/a4/ecc1a415-cc86-e5f5-7376-459adc61082d/mzaf_4503705299515093535.plus.aac.p.m4a'),
    ('7 Sitzer', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/45/ff/8a/45ff8aa7-d5c3-72c9-39b1-888bdd2731db/mzaf_333299023830826263.plus.aac.p.m4a')
) AS v(title, artist, url)
JOIN public.topic_pool tp ON tp.text = 'Deutschrap aktuell'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

COMMIT;


-- >>> 088_only_deutschrap_aktuell.sql <<<
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

-- >>> 089_register_without_email.sql <<<
-- ============================================================
-- 089: Konto ohne E-Mail (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Registrieren nur noch mit Benutzername + Passwort. Das Konto legt der Server (Next.js, service_role)
-- direkt bestätigt an, mit einer internen Platzhalter-Adresse <zufall>@konto.kumpir.invalid, die nie
-- angezeigt wird und keine Mails bekommt. Diese Funktion bremst Massen-Registrierungen:
-- höchstens 5 neue Konten pro IP und Stunde. Nur der Server darf sie aufrufen.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.register_guard(p_ip text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public._rate_limit('register:' || coalesce(nullif(trim(p_ip), ''), 'unbekannt'), 5, 3600);
END;
$$;

REVOKE ALL ON FUNCTION public.register_guard(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_guard(text) TO service_role;

COMMIT;

-- >>> 090_discord_logs.sql <<<
-- ============================================================
-- 090: Spiel-Logs nach Discord (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Die Datenbank schickt wichtige Ereignisse selbst an Discord-Webhooks (pg_net, asynchron nach dem
-- Speichern – das Spiel wartet nie auf Discord, Fehler werden verschluckt):
--   spiele   : Spiel gestartet / Match beendet mit Rangliste
--   konten   : neues Konto, Konto gelöscht
--   admin    : Aktionen aus dem Protokoll (Rollen, Sperren, Kicks, Songs, Playlists, ...)
--   bericht  : Tagesbericht um 23:00 (deutsche Zeit) – Matches, Spieler, neue Konten
-- Die Webhook-Adressen liegen in private.discord_hooks (nicht über die API erreichbar) und werden von
-- db/scripts/discord-setup.mjs eingetragen. Ohne Eintrag passiert einfach nichts.
-- ============================================================
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.discord_hooks (
  channel    text PRIMARY KEY,           -- spiele | konten | admin | bericht
  url        text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON private.discord_hooks FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ Senden
CREATE OR REPLACE FUNCTION private.discord_send(p_channel text, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE v_url text;
BEGIN
  SELECT url INTO v_url FROM private.discord_hooks WHERE channel = p_channel;
  IF v_url IS NULL THEN RETURN; END IF;
  PERFORM net.http_post(
    url := v_url,
    body := p_payload || jsonb_build_object('username', 'Kumpir'),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000
  );
EXCEPTION WHEN OTHERS THEN
  NULL;  -- Discord darf das Spiel nie stören
END;
$$;
REVOKE ALL ON FUNCTION private.discord_send(text, jsonb) FROM PUBLIC, anon, authenticated;

-- Discord-Text entschärfen (keine @everyone-Erwähnungen, kein Markdown aus Spielernamen)
CREATE OR REPLACE FUNCTION private.dc_safe(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT regexp_replace(replace(coalesce(p, ''), '@', '@' || chr(8203)), '([*_`~|>\\])', '\\\1', 'g');
$$;

-- ------------------------------------------------------------ Spiele
CREATE OR REPLACE FUNCTION private._trg_discord_lobby()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_players text;
  v_humans int;
  v_bots int;
  v_rank text;
  v_winner text;
  v_minutes int;
BEGIN
  IF NEW.phase IS NOT DISTINCT FROM OLD.phase THEN RETURN NEW; END IF;

  -- Spiel gestartet (erster Durchgang eines Matches)
  IF NEW.phase = 'running' AND OLD.phase = 'countdown' AND coalesce(NEW.series_index, 1) = 1 THEN
    SELECT string_agg(CASE WHEN p.is_bot THEN '🤖 ' ELSE '👤 ' END || private.dc_safe(p.name), '  ·  ' ORDER BY p.is_bot, p.joined_at),
           count(*) FILTER (WHERE NOT p.is_bot), count(*) FILTER (WHERE p.is_bot)
      INTO v_players, v_humans, v_bots
      FROM public.players p WHERE p.lobby_id = NEW.id AND p.status = 'active';
    PERFORM private.discord_send('spiele', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
      'title', CASE WHEN v_humans <= 1 AND v_bots > 0 THEN '🤖 Solo-Spiel gestartet' ELSE '🎮 Spiel gestartet' END,
      'description', coalesce(v_players, '–'),
      'color', 3447003,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Lobby', 'value', '`' || NEW.code || '`', 'inline', true),
        jsonb_build_object('name', 'Playlist', 'value', coalesce(private.dc_safe(NEW.topic_selected), '–'), 'inline', true),
        jsonb_build_object('name', 'Runden', 'value', coalesce(NEW.series_total, 1)::text, 'inline', true),
        jsonb_build_object('name', 'Spieler', 'value', v_humans || ' Menschen, ' || v_bots || ' Bots', 'inline', true)
      ),
      'timestamp', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ))));
  END IF;

  -- Match beendet: Rangliste über alle Durchgänge
  IF NEW.phase = 'finished' THEN
    WITH t AS (
      SELECT sr.player_id, max(sr.name) AS name, bool_or(sr.is_bot) AS is_bot,
             sum(sr.arena_points) AS pts, sum(sr.song_points) AS hits
        FROM public.series_results sr WHERE sr.lobby_id = NEW.id
       GROUP BY sr.player_id
    ), r AS (
      SELECT *, row_number() OVER (ORDER BY pts DESC, hits DESC) AS rn FROM t
    )
    SELECT string_agg(
             CASE rn WHEN 1 THEN '🥇' WHEN 2 THEN '🥈' WHEN 3 THEN '🥉' ELSE rn || '.' END || ' '
             || CASE WHEN is_bot THEN '🤖 ' ELSE '' END || '**' || private.dc_safe(name) || '** – ' || pts || ' Pkt'
             || CASE WHEN hits > 0 THEN ' · ♪ ' || rtrim(rtrim(to_char(hits, 'FM999990.0'), '0'), '.') ELSE '' END,
             E'\n' ORDER BY rn),
           max(CASE WHEN rn = 1 THEN private.dc_safe(name) END)
      INTO v_rank, v_winner
      FROM r WHERE rn <= 8;
    v_minutes := greatest(1, round(extract(epoch FROM (now() - coalesce(NEW.run_started_at, NEW.created_at))) / 60.0)::int);
    IF v_rank IS NOT NULL THEN
      PERFORM private.discord_send('spiele', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
        'title', '🏆 ' || coalesce(v_winner, '?') || ' gewinnt!',
        'description', v_rank,
        'color', 16766720,
        'fields', jsonb_build_array(
          jsonb_build_object('name', 'Lobby', 'value', '`' || NEW.code || '`', 'inline', true),
          jsonb_build_object('name', 'Dauer', 'value', '~' || v_minutes || ' Min', 'inline', true),
          jsonb_build_object('name', 'Playlist', 'value', coalesce(private.dc_safe(NEW.topic_selected), '–'), 'inline', true)
        ),
        'timestamp', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      ))));
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;  -- Logs dürfen nie ein Spiel blockieren
END;
$$;

DROP TRIGGER IF EXISTS lobbies_discord_log ON public.lobbies;
CREATE TRIGGER lobbies_discord_log AFTER UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION private._trg_discord_lobby();

-- ------------------------------------------------------------ Konten + Admin-Protokoll
CREATE OR REPLACE FUNCTION private._trg_discord_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_label text;
  v_who text := coalesce(private.dc_safe(NEW.actor_name), 'System');
  v_target text := coalesce(private.dc_safe(NEW.target_label), '–');
BEGIN
  IF NEW.action = 'account_created' THEN
    PERFORM private.discord_send('konten', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
      'title', '👋 Neues Konto', 'description', '**' || v_target || '** ist dabei!', 'color', 5763719,
      'timestamp', to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
    RETURN NEW;
  END IF;
  IF NEW.action IN ('account_deleted', 'deleted', 'deletion_requested') THEN
    PERFORM private.discord_send('konten', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
      'title', CASE WHEN NEW.action = 'deletion_requested' THEN '🗑️ Löschung beantragt' ELSE '❌ Konto gelöscht' END,
      'description', '**' || v_target || '**', 'color', 15548997,
      'timestamp', to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  END IF;

  -- Kleinkram, den Spieler selbst ändern, nicht melden
  IF NEW.action IN ('preferences_changed', 'avatar_changed', 'display_name_changed', 'lobbies_expired', 'account_created') THEN
    RETURN NEW;
  END IF;

  v_label := CASE NEW.action
    WHEN 'suspended' THEN '⛔ gesperrt' WHEN 'unsuspended' THEN '✅ entsperrt'
    WHEN 'deletion_requested' THEN '🗑️ Löschung beantragt' WHEN 'deletion_rejected' THEN '↩️ Löschantrag abgelehnt'
    WHEN 'deleted' THEN '❌ endgültig gelöscht' WHEN 'account_deleted' THEN '❌ Konto gelöscht'
    WHEN 'role_changed' THEN '🛡️ Rolle geändert' WHEN 'profile_moderated' THEN '✏️ Profil bearbeitet'
    WHEN 'password_reset_sent' THEN '🔑 Passwort-Reset gesendet' WHEN 'password_changed' THEN '🔐 Passwort geändert'
    WHEN 'lobby_closed' THEN '🚪 Lobby geschlossen' WHEN 'player_kicked' THEN '👢 Spieler gekickt'
    WHEN 'song_archived' THEN '📦 Song archiviert' WHEN 'song_restored' THEN '♻️ Song zurückgeholt'
    WHEN 'username_changed' THEN '✏️ Benutzername geändert' WHEN 'email_changed' THEN '📧 E-Mail geändert'
    WHEN 'status_changed' THEN '🚦 Status geändert' WHEN 'platform_admin_changed' THEN '🛡️ Plattform-Admin geändert'
    WHEN 'songs_added' THEN '➕ Songs hinzugefügt' WHEN 'songs_removed' THEN '➖ Songs entfernt'
    WHEN 'songs_changed' THEN '🎵 Songs geändert' WHEN 'playlist_changed' THEN '📀 Playlist geändert'
    ELSE '📝 ' || NEW.action END;

  PERFORM private.discord_send('admin', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
    'title', v_label,
    'description', 'Betrifft: **' || v_target || '**' || E'\n' || 'Von: ' || v_who,
    'color', 10181046,
    'timestamp', to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS admin_audit_discord_log ON public.admin_audit;
CREATE TRIGGER admin_audit_discord_log AFTER INSERT ON public.admin_audit
  FOR EACH ROW EXECUTE FUNCTION private._trg_discord_audit();

-- ------------------------------------------------------------ Tagesbericht
CREATE OR REPLACE FUNCTION private.discord_daily_report()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_matches int; v_solo int; v_humans int; v_accounts int; v_top text;
BEGIN
  SELECT count(DISTINCT lobby_id) INTO v_matches FROM public.series_results WHERE created_at > now() - interval '24 hours';
  SELECT count(*) INTO v_solo FROM (
    SELECT lobby_id FROM public.series_results WHERE created_at > now() - interval '24 hours'
    GROUP BY lobby_id HAVING count(*) FILTER (WHERE NOT is_bot) <= 1) s;
  -- Namen statt Spieler-Zeilen: Lobbys (und ihre Spieler) werden nach dem Spiel aufgeräumt
  SELECT count(DISTINCT lower(name)) INTO v_humans
    FROM public.series_results WHERE created_at > now() - interval '24 hours' AND NOT is_bot;
  SELECT count(*) INTO v_accounts FROM public.admin_audit WHERE action = 'account_created' AND created_at > now() - interval '24 hours';
  SELECT string_agg('**' || private.dc_safe(name) || '** – ' || wins || ' Sieg' || CASE WHEN wins = 1 THEN '' ELSE 'e' END, E'\n')
    INTO v_top FROM (
      SELECT name, count(*) AS wins FROM public.series_results
       WHERE created_at > now() - interval '24 hours' AND place = 1 AND NOT is_bot
       GROUP BY name ORDER BY count(*) DESC LIMIT 3) w;

  PERFORM private.discord_send('bericht', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
    'title', '📊 Tagesbericht',
    'color', 16750615,
    'fields', jsonb_build_array(
      jsonb_build_object('name', 'Matches', 'value', v_matches || ' (davon ' || v_solo || ' Solo)', 'inline', true),
      jsonb_build_object('name', 'Spieler', 'value', v_humans::text, 'inline', true),
      jsonb_build_object('name', 'Neue Konten', 'value', v_accounts::text, 'inline', true),
      jsonb_build_object('name', 'Meiste Siege (Menschen)', 'value', coalesce(v_top, '–'), 'inline', false)
    ),
    'timestamp', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ))));
END;
$$;
REVOKE ALL ON FUNCTION private.discord_daily_report() FROM PUBLIC, anon, authenticated;

-- 21:00 UTC = 23:00 Sommerzeit / 22:00 Winterzeit
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kumpir-discord-daily';
SELECT cron.schedule('kumpir-discord-daily', '0 21 * * *', 'select private.discord_daily_report()');

COMMIT;

-- >>> 091_pass_grace.sql <<<
-- ============================================================
-- 091: Schutzzeit beim Weitergeben (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Problem: Die Zündschnur läuft pro Zug (nicht pro Spieler). Wer in letzter Sekunde weitergibt,
-- reichte dem Nächsten nur die Restzeit weiter – der platzte ohne jede Chance (im Duell gibt es
-- zusätzlich keine Bonuszeit).
--
-- Lösung: Wer die Kumpir bekommt, hat IMMER mindestens die Schutzzeit:
--   Blitz 5 s · Standard 6 s · Casual 7 s
-- Jede weitere Schutzzeit im selben Zug ist 1 s kürzer (nie unter 4 s) – so kann ein Zug nicht
-- endlos weiterlaufen, wenn alle immer kurz vor Schluss abgeben. Neuer Zug = wieder volle Schutzzeit.
-- lobbies.last_grace_sec sagt dem Browser, dass beim letzten Weitergeben die Schutzzeit gegriffen hat
-- (für den Hinweis beim Empfänger); 0 = normale Restzeit.
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies
  ADD COLUMN IF NOT EXISTS grace_count int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_grace_sec numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.calc_pass_grace_seconds(p_round_speed text, p_used int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(4,
    (CASE p_round_speed WHEN 'fast' THEN 5 WHEN 'calm' THEN 7 ELSE 6 END) - greatest(0, coalesce(p_used, 0))
  )::numeric;
$$;

-- Neuer Zug (jemand ist geplatzt) oder neue Runde: Schutzzeit wieder voll
CREATE OR REPLACE FUNCTION public._trg_reset_grace()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.round_number IS DISTINCT FROM OLD.round_number
     OR (NEW.phase = 'running' AND OLD.phase IS DISTINCT FROM 'running') THEN
    NEW.grace_count := 0;
    NEW.last_grace_sec := 0;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS lobbies_reset_grace ON public.lobbies;
CREATE TRIGGER lobbies_reset_grace BEFORE UPDATE ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_reset_grace();

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
  v_quality numeric; v_diff numeric; v_combo_bonus numeric;
  v_speed text; v_grace_count int; v_grace numeric; v_new_explode timestamptz; v_grace_applied numeric := 0;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number,
         coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at),
         coalesce(l.last_pass_quality, 1), coalesce(l.last_pass_diff, 1), coalesce(l.last_pass_combo_bonus, 0),
         coalesce(l.round_speed, 'normal'), coalesce(l.grace_count, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number,
         v_bonus_used, v_since, v_quality, v_diff, v_combo_bonus,
         v_speed, v_grace_count
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
    -- Original: Richtung kann durch den Rache-Pass gedreht sein.
    if coalesce(v_dir, 1) >= 0 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  v_bonus_cap := public.calc_pass_bonus_cap(n);
  -- Basis (Runde) x Antwortqualität (Titel 1 / Interpret 0.5) x Song-
  -- Schwierigkeit + Combo-Bonus; im Duell (2 Lebende) gar keine Bonuszeit.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality * v_diff + v_combo_bonus;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  v_new_explode := greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second');

  -- Schutzzeit: der Empfänger hat immer mindestens v_grace Sekunden (Migration 091)
  v_grace := public.calc_pass_grace_seconds(v_speed, v_grace_count);
  if v_new_explode < v_now + (v_grace * interval '1 second') then
    v_new_explode := v_now + (v_grace * interval '1 second');
    v_grace_applied := v_grace;
  end if;

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = v_new_explode,
      round_bonus_used = v_bonus_used + v_bonus_applied,
      grace_count = v_grace_count + case when v_grace_applied > 0 then 1 else 0 end,
      last_grace_sec = v_grace_applied,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;

-- >>> 092_bots_songs_invites.sql <<<
-- ============================================================
-- 092: Bots raten meist den Künstler, Liste der erratenen Songs, keine Song-Wiederholung im Match,
--      Lobby-Einladungen an Freunde (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- 1) Bots: Wenn ein Bot etwas errät, nennt er zu 70–80 % den Künstler (½ Punkt) und nur zu 20–30 %
--    den Titel – vorher nannten Bots fast immer den Titel (zu stark):
--    Anfänger 80 % Künstler · Mittel 75 % · Profi 70 %.
-- 2) "Schon gesagt": statt der getippten Eingabe steht dort der richtige Song: "Titel – Künstler"
--    (inkl. Feature-Künstler, so wie er in der Song-Liste steht).
-- 3) Songs wiederholen sich innerhalb eines Matches nicht mehr (3 oder 5 Runden): die Liste der
--    gespielten Songs wird nur noch beim ersten Durchgang eines Matches geleert.
-- 4) Lobby-Einladungen: Wer in einer Lobby ist, kann Freunde einladen; der Freund bekommt ein
--    Pop-up "X hat dich eingeladen" mit Beitreten / Nicht beitreten.
-- ============================================================
BEGIN;

-- ------------------------------------------------------------ 1) Bots
CREATE OR REPLACE FUNCTION public._bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_delay numeric;
  v_roll numeric;
  v_answer text;
  v_seed text;
  v_artist_chance numeric;
  v_base numeric; v_span numeric;
begin
  -- ---------- Themen-Voting ----------
  for r in
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at, l.topic_vote_cards
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % greatest(1, least(3, r.topic_vote_cards))))
      on conflict (lobby_id, player_id) do nothing;
    end if;
  end loop;

  -- ---------- Laufende Runde: Bot ist Halter ----------
  for r in
    select l.id, l.code, l.holder_player_id, l.holder_since, l.round_number, l.current_song_id,
           l.topic_selected, l.used_answers, l.explode_at, coalesce(p.bot_skill, 2) as skill
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    -- Reaktionszeit je Stärke
    if r.skill = 1 then v_base := 2.4; v_span := 3.0;
    elsif r.skill = 3 then v_base := 0.8; v_span := 1.2;
    else v_base := 1.2; v_span := 2.6; end if;

    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := v_base + (abs(hashtext(v_seed)) % 1000) / 1000.0 * v_span;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number, r.skill) then continue; end if;

    -- Migration 092: meist den Künstler (½ Punkt), seltener den Titel
    v_artist_chance := case r.skill when 1 then 0.80 when 3 then 0.70 else 0.75 end;

    v_answer := null;
    if r.current_song_id is not null then
      if (abs(hashtext('a' || v_seed)) % 1000) / 1000.0 < v_artist_chance then
        select trim(split_part(split_part(artist, ',', 1), '&', 1)) into v_answer from public.song_pool where id = r.current_song_id;
      end if;
      if v_answer is null or length(v_answer) = 0 then
        select title into v_answer from public.song_pool where id = r.current_song_id;
      end if;
    else
      select ta.answer into v_answer
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(coalesce(r.topic_selected, ''))
        and not (ta.lower_answer = any (select lower(u) from unnest(r.used_answers) u))
      order by random() limit 1;
      v_answer := coalesce(v_answer, 'Keine Ahnung');
    end if;

    if v_answer is not null then
      begin
        perform public.rpc_attempt_pass(r.code, r.holder_player_id, v_answer);
      exception when others then
        null;
      end;
    end if;
  end loop;
end;
$function$;

-- ------------------------------------------------------------ 2) Erratene Songs
CREATE OR REPLACE FUNCTION public._finalize_attempt_accept(p_attempt_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_attempt   public.pass_attempts%ROWTYPE;
    v_lobby     public.lobbies%ROWTYPE;
    v_code      TEXT;
    v_shown     TEXT;
BEGIN
    SELECT * INTO v_attempt FROM public.pass_attempts WHERE id = p_attempt_id;
    SELECT * INTO v_lobby FROM public.lobbies WHERE id = v_attempt.lobby_id;
    v_code := v_lobby.code;

    -- Song-Runde: den richtigen Song zeigen ("Titel – Künstler"), nicht die Eingabe
    v_shown := v_attempt.answer;
    IF v_lobby.current_song_id IS NOT NULL THEN
        SELECT sp.title || ' – ' || sp.artist INTO v_shown FROM public.song_pool sp WHERE sp.id = v_lobby.current_song_id;
        v_shown := coalesce(v_shown, v_attempt.answer);
    END IF;

    UPDATE public.pass_attempts
    SET status = 'accepted', decided_at = NOW()
    WHERE id = p_attempt_id;

    UPDATE public.lobbies
    SET current_attempt_id = NULL,
        used_answers = array_append(used_answers, v_shown)
    WHERE id = v_lobby.id;

    -- Bestehende rpc_pass_potato hält die Logik (next holder, stats etc.)
    PERFORM public.rpc_pass_potato(v_code, v_attempt.holder_player_id);
END;
$function$;

-- ------------------------------------------------------------ 3) Keine Wiederholung im Match
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
  v_phase text;
begin
  select phase, round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_phase, v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'countdown' then return; end if;
  if coalesce(current_setting('request.headers', true), '') <> '' and exists (select 1 from public.lobbies where id = p_lobby_id and countdown_ends_at > now() + interval '1 second') then return; end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  -- Faire Weitergabe-Reihenfolge: Sitzplätze zufällig mischen.
  with act as (
    select player_id, seat_index as old_seat,
           row_number() over (order by seat_index) as rk
    from public.players
    where lobby_id = p_lobby_id and status = 'active'
  ), shuf as (
    select player_id, row_number() over (order by random()) as rk from act
  ), pick as (
    select s.player_id, a.old_seat
    from shuf s join act a on a.rk = s.rk
  )
  update public.players p set seat_index = -(pick.old_seat + 1)
  from pick where p.lobby_id = p_lobby_id and p.player_id = pick.player_id;

  update public.players set seat_index = -seat_index - 1
  where lobby_id = p_lobby_id and status = 'active' and seat_index < 0;

  update public.players set skips_left = 1
  where lobby_id = p_lobby_id and status = 'active';

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
      countdown_starter_player_id = null,
      used_answers = '{}',
      -- Migration 092: gespielte Songs nur beim ersten Durchgang eines Matches leeren
      used_song_ids = case when coalesce(series_index, 1) <= 1 then '{}' else coalesce(used_song_ids, '{}') end,
      current_attempt_id = null,
      round_bonus_used = 0,
      last_pass_quality = 1,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- ------------------------------------------------------------ 4) Lobby-Einladungen
CREATE TABLE IF NOT EXISTS public.lobby_invites (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lobby_id    uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  from_user   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  to_user     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lobby_id, to_user)
);
ALTER TABLE public.lobby_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lobby_invites FROM PUBLIC, anon, authenticated;

-- Einladen: nur Freunde, nur wer selbst gerade in der (wartenden) Lobby ist
CREATE OR REPLACE FUNCTION public.rpc_invite_friend(p_lobby_code text, p_friend_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_me uuid := auth.uid(); v_lobby uuid;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_logged_in'; END IF;
  PERFORM public._rate_limit('invite:' || v_me::text, 30, 600);
  SELECT l.id INTO v_lobby FROM public.lobbies l
   WHERE l.code = upper(trim(p_lobby_code)) AND l.phase = 'waiting'
     AND EXISTS (SELECT 1 FROM public.players p WHERE p.lobby_id = l.id AND p.user_id = v_me AND p.status = 'active');
  IF v_lobby IS NULL THEN RAISE EXCEPTION 'lobby_not_waiting'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.friendships f WHERE f.user_id = v_me AND f.friend_user_id = p_friend_user_id AND f.status = 'accepted') THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;
  INSERT INTO public.lobby_invites (lobby_id, from_user, to_user)
  VALUES (v_lobby, v_me, p_friend_user_id)
  ON CONFLICT (lobby_id, to_user) DO UPDATE SET status = 'pending', from_user = excluded.from_user, created_at = now();
END;
$$;

-- Offene Einladungen an mich (letzte 10 Minuten, Lobby wartet noch)
CREATE OR REPLACE FUNCTION public.rpc_my_invites()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  IF v_me IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', i.id, 'lobbyCode', l.code, 'fromName', coalesce(pr.display_name, pr.username, 'Ein Freund'),
             'fromEmoji', pr.avatar_emoji, 'createdAt', i.created_at) ORDER BY i.created_at DESC)
      FROM public.lobby_invites i
      JOIN public.lobbies l ON l.id = i.lobby_id
      LEFT JOIN public.profiles pr ON pr.id = i.from_user
     WHERE i.to_user = v_me AND i.status = 'pending'
       AND i.created_at > now() - interval '10 minutes'
       AND l.phase = 'waiting'
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_respond_invite(p_invite_id uuid, p_accept boolean)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_me uuid := auth.uid(); v_code text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_logged_in'; END IF;
  UPDATE public.lobby_invites i SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END
   WHERE i.id = p_invite_id AND i.to_user = v_me
  RETURNING (SELECT l.code FROM public.lobbies l WHERE l.id = i.lobby_id) INTO v_code;
  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_invite_friend(text, uuid), public.rpc_my_invites(), public.rpc_respond_invite(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_invite_friend(text, uuid), public.rpc_my_invites(), public.rpc_respond_invite(uuid, boolean) TO authenticated;

COMMIT;

-- >>> 093_deutschrap_klassiker.sql <<<
-- Generiert von db/scripts/build-deutschrap.mjs (2026-10-07)
-- Playlist "Deutschrap aktuell": 351 Songs (Alter egal), max. 15 pro Rapper, Beliebtheit laut Deezer, Vorschau laut iTunes
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap aktuell', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap aktuell');

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Archiv (deaktivierte Songs)', false, false
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)');

UPDATE public.song_pool s
SET archived_from = 'Deutschrap aktuell', topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)')
WHERE s.topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Deutschrap aktuell')
  AND lower(s.title) NOT IN ('killy manjaro', 'strasse', 'chaos', 'radw', 'ma baby', 'prada sport', 'madonna', 'breaking your heart', 'heb ab', 'komm näher', 'niemals', '1999, pt. iii', 'fame', 'sport', 'apartment', 'kein problem', 'rhythm', 'casa cuba', 'take it', 'gift', '7 stunden', 'beautiful girl', 'alors', 'starboy', 'erinnerung', 'wolken', 'kaybeden', 'connected', 'brot nach hause', 'leere hände', 'lüg mich an', 'count your blessings', 'ocean', 'bläulich', 'let me love you', 'suvs', 'superstars', 'unsichtbar', 'moonlight dreams', 'do you lie', 'frühstück in paris', 'rücken an rücken', 'klatsch das!', 'unterwegs', 'dna', 'all night', 'ich bring dir keine blumen', 'another vibe', 'marlboro rot', 'pa mu', 'nur wegen dir', 'vacation', 'immer', 'mailbox', 'cherry lady', 'wenn das so bleibt', 'gesegnet', 'high', 'hold me down', 'mala fama', '1999, pt. i', 'blessed', 'himmel leer', 'konum gizli', 'halbmond', 'malaga', 'marbella', 'risiko', 'dünya', 'weiss', 'malli', 'schmetterling', '9mm', 'wenn du mich siehst', 'adriana', 'baebae', 'h <3 t e l', 'allein', 'nicht verdient', '187 gang', 'melodien', 'bullet', 'simpel', 'blunt für dich', 'fly', 'neptun', 'karma', 'gunshot', 'cc', 'berlin lebt wie nie zuvor', 'echte berliner', 'bei nacht', 'doktor', 'gebete', 'sommer', 'ich liebe es', 'blanco', 'to the sky', 'ruhe nach dem sturm', 'rolex', 'stern', 'kein schlaf', 'meine couch', 'adrenalina', 'el fenomeno', 'wenn ich will', 'flouz kommt flouz geht', 'dreckig & gemein', 'lieber gott', 'mira', 'sommernacht', 'coração', 'azzlackz sterben jung 2', 'ebbe & flut', 'imaginando', '365 tage', 'copkkkilla', 'let''s go', 'hayati', 'mungu', 'blue lagoon', 'panzaknacka', 'fajet', 'lowlife', 'ice', 'zombie', 'hade', 'blutbad', 'sommer 19', 'heute nacht', 'in meiner dna', 'wolke 7', 'nympho', 'bebe', 'ich will alles', 'virus', 'mind on my $$$', 'manchmal', 'odyssee', 'ararım yarın', 'pasha nanen', 'leben lang', 'bei dir', 'ohne dich', 'hokus pokus', 'island chick', 'augen husky', 'millieu 26', 'iphone 17', 'solo', 'd a yyy t o n a', 'so wie du', 'kokaretten', 'valla nein', 'baile funk im blut', 'seele', 'kiss me', 'barbie & ken', 'saudi arabi money rich', 'beretta', 'baby 2.0', 'sober', 'sternhimmeldach', 'asozialer araber', 'flexscheibe', 'immer mehr', 'kinginmeimding', 'baby mama', 'ich mach es', 'fefe', 'ich brauch dich', 'plaza', 'better dayz', 'vollautomatik', 'muskat', 'mbappé', 'shakal', 'fastlane', 'amcaogle', 'papaya', 'sayfa', 'bounce', 'bang', 'ich hol dich ab', 'weekend', 'geh dein weg', 'rapstars', 'scarface', 'hasta la vista', 'früher pleite heute benz', 'vollmond', 'magie', 'medmen', 'wenn ich geh', 'du fehlst', 'leer', 'down', 'jaloux', 'paper', 'wow', 'model', 'la 3youne', 'mahalle', 'nala', 'sommernächte.mp3', 'buonasera', 'weisse tn sneakers', 'glizzy', 'junimond', 'layla wa layla', 'usdt', 'rendezvous ii', 'drück', 'mannschaft', 'ring ring', 'mavi', 'biturbo', 'ghetto karibik', 'maghreb united', 'sorry', 'nador', 'was ist los?!', 'hautfarbe cappuccino', 'komet', 'ferrari testarossa', 'sie ruft', '2 minuten', 'blue porsche', 'peppermint', 'perfekt', 'so lala', 'tattoos', 'strada', 'verändert', 'maschine', 'schnapp!', 'haifisch nikez', 'prollz', 'komm zu 187', 'blättchen und ganja', 'grabstein', 'gefährlich', 'irgendwann', 'rohdiamant ٢٠٢٠', 'so alleine', 'tranquillo', 'tief in die nacht', 'bielefeld', 'phantom', 'geht nich gibs nich', 'flex so hard', 'ratchet', 'warner cash', 'iron man', 'tagebuch', 'dale', 'mango', 'family', 'handy brennt…', 'nicht da', 'caliente', 'hol mir deine cousine', '7 sitzer', 'i love you', 'neapel', 'dreckige dollars', 'wo du warst', 'fefe italia', 'dilemin', 'nie wieder', 'trendsetter', 'bitter', 'para drill', 'star', 'cash da', 'classic', 'bon voyage ii', 'akrapovic', 'désolé', 'ti amo', 'highlight', '6am.........', 'saltbae', 'middle of the day', 'sternenhimmeldach', 'lichter der stadt', 'komm mit mir', 'letzte nacht', 'hochhaus', 'tränen', '8 mile', 'von unten', 'keine', 'condor', 'immer unterwegs', 'habibi', 'prominenz', 'bang bang', 'big money', 'discokugel', 'flügel', 'vija vija', 'roli glitzer glitzer', 'bye bye', 'leuchtreklame', '1999, pt. ii', 'ozean', 'frisch aus der küche', 'bolon', 'bend over', 'ma baby 2', 'damals', 'far away', 'alles ist geschrieben', 'tiki taka', '24 karat', 'dinero', 'justizia', 'hood bandolero', 'trance', 'rot oder schwarz', 'happy tears', 'beautiful people', 'lambada', 'aladdin', 'wo bist du', 'yanee', 'talentiert', 'vertrauen', 'dtec', 'safe', 'makarova', 'der rettungsschwimmer', 'der maurermeister', 'der lastwagenfahrer', 'der fahrradkurier', 'der sicherheitsbeamte', 'der lehrer', 'der indianer', 'der putin', 'der rooz', 'von salat schrumpft der bizeps', 'nwo', 'free spirit', 'eine bruderschaft bleibt', 'lyrik lounge theme', 'nador city gang', 'kampfsport', 'testosteron', 'money ii', 'guerilla', 'bitte spitte x', 'get rich die tryin''', 'city gangster', 'krone', 'casanova', 'bitcoins', 'quavo', 'berghainclub', 'alles', 'endlos verliebt', 'inkognito', 'hots 4 u');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('KILLY MANJARO', 'Summer Cem & BILLA JOE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cb/e0/df/cbe0df28-5861-3e82-2ea5-181c317fb36b/mzaf_10048378324413235332.plus.aac.p.m4a'),
    ('STRASSE', 'Cave, AMO & Soufian', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/53/64/7b/53647b6c-5200-12c2-311e-b0add4743472/mzaf_16189344066838957405.plus.aac.p.m4a'),
    ('Chaos', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/3b/3f/5a3b3f8b-e370-5a97-d806-cbf95d77b3c9/mzaf_15555307926128862577.plus.aac.p.m4a'),
    ('RADW', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/6b/d1/99/6bd1997f-0ee0-f4f1-4ba3-412ee6c0aec3/mzaf_17320734412589516315.plus.aac.p.m4a'),
    ('Ma Baby', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/18/4f/66/184f66fb-5c57-96aa-f728-f3d39bc85e19/mzaf_1352664921887866745.plus.aac.p.m4a'),
    ('Prada Sport', 'Pashanim, AK AUSSERKONTROLLE & Selim61', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/67/29/e7/6729e7a2-80a5-4e71-ffe1-73441a63d525/mzaf_2829994467836192279.plus.aac.p.m4a'),
    ('Madonna', 'Bausa & Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/03/8f/78/038f7816-eab4-b3b2-7534-173b3c3d628d/mzaf_11105515926262480032.plus.aac.p.m4a'),
    ('Breaking your heart', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/96/e7/02/96e702d6-1166-5275-fc58-38eb199456c6/mzaf_10767789362673437085.plus.aac.p.m4a'),
    ('Heb ab', 'Miami Yacine & Nash', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/96/4b/93/964b9392-fceb-1702-3513-d370971172cd/mzaf_3561495639029066177.plus.aac.p.m4a'),
    ('KOMM NÄHER', 'Juju & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/46/63/80/46638007-5a53-eff1-2ca7-b689cdde4346/mzaf_13391563044020387101.plus.aac.p.m4a'),
    ('Niemals', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/44/b3/fe/44b3fee5-c732-b2db-4fe2-7d911219e0b3/mzaf_13839186796549365331.plus.aac.p.m4a'),
    ('1999, Pt. III', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/20/00/6d/20006d0e-8a59-a5ed-4ece-064f8edb1ed0/mzaf_16451703821682020900.plus.aac.p.m4a'),
    ('Fame', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5a/f0/f4/5af0f43f-24f5-43c7-0c2a-8feb43eb6ed3/mzaf_12822475214740846917.plus.aac.p.m4a'),
    ('Sport', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/a3/95/af/a395afde-8d8c-bbce-167b-ec1d58e5dcca/mzaf_1380158852321020760.plus.aac.p.m4a'),
    ('APARTMENT', 'Dardan & Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/22/cd/5f/22cd5f0e-b246-34c0-fea3-d8f59000af68/mzaf_7248130489873914061.plus.aac.p.m4a'),
    ('Kein Problem', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/57/4c/94/574c9402-db79-6244-4913-220fd94b4125/mzaf_16230532092180084966.plus.aac.p.m4a'),
    ('Rhythm', 'SIRA, Aymen & NiklasWilson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/10/a8/8f/10a88f93-1082-0a00-1bfd-5866e0efb226/mzaf_10604194046169191608.plus.aac.p.m4a'),
    ('CASA CUBA', 'Cave & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/58/c0/f7/58c0f750-446d-2271-fdde-3ce90eab3c6e/mzaf_12474368255946710699.plus.aac.p.m4a'),
    ('Take it', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a3/a6/89/a3a689a3-a202-71c7-3738-b5e90206bd6a/mzaf_3499770739931437883.plus.aac.p.m4a'),
    ('Gift', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/44/81/f9/4481f964-0b7f-94e0-35d7-565d86a6a57c/mzaf_13676693610091644511.plus.aac.p.m4a'),
    ('7 Stunden', 'LEA & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/89/73/bc/8973bcab-3bc9-c572-d73d-54be93c95c15/mzaf_174349691283394357.plus.aac.p.m4a'),
    ('Beautiful Girl', 'Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5e/91/18/5e911840-43c9-b8ee-26d7-da3731546fe6/mzaf_13837890078012244998.plus.aac.p.m4a'),
    ('Alors', 'Kurdo & CAPO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/eb/08/fd/eb08fdce-ef48-df1a-57ac-060ae9d0ba39/mzaf_2606216749379526645.plus.aac.p.m4a'),
    ('Starboy', 'Luciano & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bc/dd/b5/bcddb5ad-25b3-a5eb-d151-92d5aa72236d/mzaf_11953846642540958986.plus.aac.p.m4a'),
    ('Erinnerung', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9d/ef/63/9def63b3-1fb0-fb68-d5be-ea380c49c07d/mzaf_14113420931006507838.plus.aac.p.m4a'),
    ('Wolken', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b3/ae/a1/b3aea1d0-2ca1-3097-196e-49a967091941/mzaf_18382696023718163837.plus.aac.p.m4a'),
    ('Kaybeden', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/61/f1/61/61f1612e-f0ea-e68b-d16c-eb7b37b8ecac/mzaf_18394005841854612931.plus.aac.p.m4a'),
    ('CONNECTED', 'RAF Camora & reezy', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5e/69/15/5e6915d3-b776-a840-916e-e8b4f2b2cf37/mzaf_11291496925532574361.plus.aac.p.m4a'),
    ('Brot nach Hause', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/6f/59/da/6f59dadb-7025-6aff-1ec9-05830a4f5e2c/mzaf_5318156124128018675.plus.aac.p.m4a'),
    ('Leere Hände', 'SANTOS, Sido & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d0/98/7f/d0987f9e-9024-3111-78de-5ac197623e14/mzaf_15239277641803125945.plus.aac.p.m4a'),
    ('Lüg mich an', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a0/08/ab/a008ab21-2a95-9247-216f-76c6b9d5955d/mzaf_2918240860667383299.plus.aac.p.m4a'),
    ('Count your blessings', 'Sa4 & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d2/af/44/d2af4402-ce9f-b9bf-7610-d99282427cb5/mzaf_3905975321627425060.plus.aac.p.m4a'),
    ('OCEAN', 'RAF Camora & Ufo361', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/ac/66/dfac669a-9c2d-0b4c-86b6-70f8d97b8476/mzaf_12513037025792429953.plus.aac.p.m4a'),
    ('Bläulich', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f2/27/a6/f227a6ef-b6f2-de0b-8060-e0e5a29ba4fa/mzaf_7106802513914058652.plus.aac.p.m4a'),
    ('LET ME LOVE YOU', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c3/f2/32/c3f232ab-2018-4eda-ea4e-f6657e6585ca/mzaf_3300912891012517267.plus.aac.p.m4a'),
    ('SUVs', 'Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/56/b0/ae/56b0aebf-2856-cca5-fa22-efc2bab1f351/mzaf_7883660299171166825.plus.aac.p.m4a'),
    ('Superstars', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/63/08/b7/6308b70d-66f5-805e-df93-a8f80ff525a6/mzaf_9432127935537316648.plus.aac.p.m4a'),
    ('Unsichtbar', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ed/ef/dc/edefdcca-fd31-fae5-8c41-41bcdd3ec3ad/mzaf_13331952717199721520.plus.aac.p.m4a'),
    ('Moonlight Dreams', 'YAKARY & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/50/19/20/50192055-4ae8-5949-7542-9b10239c0782/mzaf_17242896264389125404.plus.aac.p.m4a'),
    ('Do you lie', 'Jazeek & Milano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b4/f5/e5/b4f5e54c-f2fa-d305-6eae-1b57960e57c4/mzaf_15871608143001105174.plus.aac.p.m4a'),
    ('Frühstück in Paris', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8e/c7/30/8ec73000-50eb-86e0-cacf-88c4d27b1556/mzaf_9368692523013546789.plus.aac.p.m4a'),
    ('Rücken an Rücken', 'Aymo, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a1/a4/78/a1a4789d-af4c-3b34-027c-d9851ab77a26/mzaf_1440609807246252587.plus.aac.p.m4a'),
    ('KLATSCH DAS!', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ca/38/55/ca3855e0-7ae4-e579-095e-059c61ac47b1/mzaf_8076816444243589241.plus.aac.p.m4a'),
    ('Unterwegs', 'KITSCHKRIEG & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/01/d3/c4/01d3c481-7a38-7f2c-096e-c978ff40ad1b/mzaf_17696471988269010539.plus.aac.p.m4a'),
    ('DNA', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/45/5b/be/455bbee2-7283-8d29-2a2e-2de451a835c2/mzaf_5267310672923600646.plus.aac.p.m4a'),
    ('All Night', 'Luciano & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/47/bf/0e/47bf0e37-81e8-ecab-d6b6-3dbc016f21c6/mzaf_17394255442885241084.plus.aac.p.m4a'),
    ('Ich bring dir keine Blumen', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/46/e0/7b/46e07b3f-6db0-05d6-ee5f-6f6235268f84/mzaf_9947818941896906192.plus.aac.p.m4a'),
    ('Another Vibe', 'Luciano & OMAH LAY', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/79/34/ad/7934ad7c-6673-f7cd-db0b-b3e2d52e2153/mzaf_15466577134704794977.plus.aac.p.m4a'),
    ('Marlboro Rot', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/27/a1/48/27a148c3-becb-a15f-155e-8415f0172a2b/mzaf_13216838188107952393.plus.aac.p.m4a'),
    ('Pa Mu', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/3a/f6/c63af622-f445-b3e5-c112-1cd7ac6a8e7f/mzaf_3790178152675825614.plus.aac.p.m4a'),
    ('Nur wegen dir', 'Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/01/cc/d2/01ccd21d-ed2e-45bc-193b-2d121fdc83ed/mzaf_787940811939842448.plus.aac.p.m4a'),
    ('VACATION', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/57/c4/e5/57c4e5a5-084d-3133-5f06-49c40fd60a43/mzaf_17719970761118631110.plus.aac.p.m4a'),
    ('Immer', 'Jazeek & DYSTINCT', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/14/43/d2144319-cf5b-b769-92c5-b2e941106808/mzaf_595829568338537564.plus.aac.p.m4a'),
    ('mailbox', 'Dardan & Hava', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/98/12/8a/98128a73-a781-3a00-796e-ee8206ee2fd1/mzaf_15068891723183151358.plus.aac.p.m4a'),
    ('Cherry Lady', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ff/7b/99/ff7b99b2-319e-5159-329b-9e29a0d4dd36/mzaf_10491098164419214407.plus.aac.p.m4a'),
    ('Wenn das so bleibt', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/16/2b/1a/162b1a1b-7e1a-b983-3824-41c559013cfe/mzaf_6020846386956878027.plus.aac.p.m4a'),
    ('Gesegnet', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ea/5b/73/ea5b7364-d204-2ca2-ae7e-729246e92f1f/mzaf_7356541788179685318.plus.aac.p.m4a'),
    ('HIGH', 'Hava & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/ea/ff/e0/eaffe029-3233-72ca-889c-1901212278e0/mzaf_2996385718013576642.plus.aac.p.m4a'),
    ('HOLD ME DOWN', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ad/f3/69/adf3699b-0c2d-0a93-84ac-dd403485c236/mzaf_11582948286059152582.plus.aac.p.m4a'),
    ('Mala Fama', 'Damon Paul & MEYSTA', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/01/67/2e/01672e06-440f-3f75-4ac1-fdd3ae3732ea/mzaf_18188576231625246480.plus.aac.p.m4a'),
    ('1999, Pt. I', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2a/11/f5/2a11f51f-ae0e-50f7-bcfd-51fe247297aa/mzaf_1372066807800128889.plus.aac.p.m4a'),
    ('Blessed', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a2/00/b7/a200b7bf-4279-d056-a0ae-f6a8827881d1/mzaf_18168927866089581357.plus.aac.p.m4a'),
    ('Himmel leer', 'SANTOS & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/71/ab/72/71ab72ec-f5f1-8de1-3fbf-677481cf017e/mzaf_7616871650057538504.plus.aac.p.m4a'),
    ('Konum Gizli', 'MERO & Murda', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/68/36/55/68365597-66a6-4750-80c9-a993c3337be6/mzaf_190833821539286539.plus.aac.p.m4a'),
    ('Halbmond', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e5/19/1e/e5191e72-6656-d7a3-ba3d-88acec57de03/mzaf_2819856113078581940.plus.aac.p.m4a'),
    ('Malaga', 'Aymen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/13/fd/6f/13fd6fa1-370d-d1be-3f96-dfffe8514f76/mzaf_16885909096574483141.plus.aac.p.m4a'),
    ('Marbella', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/29/fa/b8/29fab832-d320-5a36-c9a2-c1e95079ba1b/mzaf_3550922091845222455.plus.aac.p.m4a'),
    ('Risiko', 'RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a6/d7/17/a6d7174a-b96f-62e4-3525-b296ea12f77a/mzaf_7888209895802447691.plus.aac.p.m4a'),
    ('Dünya', 'Amo988', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/c1/0b/1d/c10b1d39-90f8-0ff4-ed05-339c64b2ee72/mzaf_6327875884741618508.plus.aac.p.m4a'),
    ('Weiss', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8d/70/34/8d7034ab-5f92-52f2-4415-f6f379e320b5/mzaf_13569840834649723092.plus.aac.p.m4a'),
    ('Malli', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/63/c3/df63c3a6-c4ac-ce85-ea3e-4af63b069230/mzaf_15135499478839051035.plus.aac.p.m4a'),
    ('SCHMETTERLING', 'Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/83/59/08/83590834-d7cf-e3e8-6b39-1ff4985d20ad/mzaf_8333389594719189466.plus.aac.p.m4a'),
    ('9mm', 'Gzuz & Bonez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f0/bf/15/f0bf15ee-9aa5-c0fa-03ac-4a2c006479ac/mzaf_2738755614767183044.plus.aac.p.m4a'),
    ('Wenn du mich siehst', 'Juju & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/fd/81/64/fd81644d-bab3-e909-9261-e3cd553d3f66/mzaf_62113270035996687.plus.aac.p.m4a'),
    ('Adriana', 'RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/15/69/84/15698440-d1b4-708e-6aa5-97421a997e64/mzaf_2018629143176555460.plus.aac.p.m4a'),
    ('BaeBae', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/57/7b/f2/577bf2eb-e1fa-4544-3ec2-b1969034f8a4/mzaf_2233978413123143655.plus.aac.p.m4a'),
    ('H <3 T E L', 'Dardan & Monet192', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/50/be/46/50be46cb-85bb-c69c-1654-9decd62d33a4/mzaf_8111090196432450027.plus.aac.p.m4a'),
    ('Allein', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/87/16/8f/87168f43-f886-df99-ba54-c05033395bd4/mzaf_9129099729555633962.plus.aac.p.m4a'),
    ('Nicht verdient', 'Capital Bra & Loredana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9e/21/0f/9e210f94-56b5-b2e6-a0f7-6f63f4f43d7f/mzaf_6048149483621901538.plus.aac.p.m4a'),
    ('187 Gang', 'Bonez MC, Gzuz, Maxwell, LX & Sa4', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9c/50/48/9c50481f-c92c-bccf-db64-4cbe9c73db15/mzaf_8509452552188587873.plus.aac.p.m4a'),
    ('Melodien', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ee/d7/51/eed7511b-e292-72be-cd15-6830acc10e68/mzaf_2073020069902082879.plus.aac.p.m4a'),
    ('Bullet', 'MERO & AYLIVA', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9c/8d/91/9c8d9193-745b-0af1-2e08-1fff1a6fdde6/mzaf_3841862161557108035.plus.aac.p.m4a'),
    ('Simpel', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/60/8f/48/608f48bc-6597-e943-b484-6da8193f2117/mzaf_1009043656935833073.plus.aac.p.m4a'),
    ('Blunt für dich', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/ca/c7/0e/cac70ea3-6166-bfa3-65a0-6091e8f359f3/mzaf_14476327957278174126.plus.aac.p.m4a'),
    ('FLY', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/58/eb/2f/58eb2f16-f899-aec4-c548-90e33cdcadd0/mzaf_7081155222039781383.plus.aac.p.m4a'),
    ('Neptun', 'KC Rebell & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/79/f2/1e/79f21eea-9b9e-00f0-791a-752610cf3fe2/mzaf_8246194517897406983.plus.aac.p.m4a'),
    ('KARMA', 'Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6d/02/ab/6d02ab94-b659-b1da-ab2c-8928304067ec/mzaf_7646433073604888784.plus.aac.p.m4a'),
    ('GUNSHOT', 'Eno & Olexesh', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e0/40/37/e04037c7-5f6c-1bd6-0df2-59881e694c42/mzaf_10998222718601598764.plus.aac.p.m4a'),
    ('CC', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/fe/c0/a0/fec0a041-26c2-4766-dfd7-8310c0678ddb/mzaf_5956664687835310048.plus.aac.p.m4a'),
    ('Berlin lebt wie nie zuvor', 'Capital Bra & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/73/b6/e9/73b6e967-eb40-cc16-4783-da22d9deec08/mzaf_13324147459064649850.plus.aac.p.m4a'),
    ('Echte Berliner', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/74/4b/1c/744b1c83-7ad6-f454-dbc8-2c17dc0c420d/mzaf_13625813307275032415.plus.aac.p.m4a'),
    ('Bei Nacht', 'Apache 207 & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b6/bd/42/b6bd4202-2553-9aa8-00b3-71d20c2127b8/mzaf_9072479678311111131.plus.aac.p.m4a'),
    ('Doktor', 'PA Sports, Sido, Haftbefehl & Alies', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/40/15/4c401580-708e-8d4e-d1a4-fe9c7a08af66/mzaf_12482896108109383756.plus.aac.p.m4a'),
    ('Gebete', 'RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/91/d8/0091d803-c040-58c2-1f44-8e053f31db5d/mzaf_7572544460874239446.plus.aac.p.m4a'),
    ('Sommer', 'Beatzarre & Djorkaeff, Lea & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/91/39/c4/9139c4fb-4b25-1932-e244-f4ff2dc7227d/mzaf_14372918576595780014.plus.aac.p.m4a'),
    ('Ich liebe es', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0c/34/bd/0c34bdd7-03c5-1f68-1c0c-00a0c9b2fc01/mzaf_13113870122667930783.plus.aac.p.m4a'),
    ('Blanco', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7c/08/e3/7c08e334-425a-6061-a76d-eed07a417212/mzaf_12155294836401644578.plus.aac.p.m4a'),
    ('To The Sky', 'Luciano & Tayc', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7a/2b/d9/7a2bd977-d0be-eabb-1452-ff3fbf9fc948/mzaf_8319036977891766496.plus.aac.p.m4a'),
    ('Ruhe nach dem Sturm', 'RAF Camora & Bonez MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ee/16/9a/ee169aac-706c-8a68-3607-007242a068be/mzaf_15057202920024218067.plus.aac.p.m4a'),
    ('Rolex', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/37/66/84/37668416-037a-40ba-8486-db6ba80b5a45/mzaf_12687800354008528915.plus.aac.p.m4a'),
    ('STERN', 'Jazeek & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e2/1c/b8/e21cb888-6b52-7696-5e25-9ef20fdf6dbf/mzaf_6301867712581873308.plus.aac.p.m4a'),
    ('KEIN SCHLAF', 'Nimo & Hava', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/53/53/78/535378c4-6b44-3e64-7e83-a0a67490a859/mzaf_8179876992233399718.plus.aac.p.m4a'),
    ('Meine Couch', 'Gzuz & Bonez MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e5/89/87/e5898713-0b99-c107-7659-8efcae926c30/mzaf_14992470435543733987.plus.aac.p.m4a'),
    ('Adrenalina', 'Dhurata Dora & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/14/0e/f6/140ef6c8-2d96-5f82-1cb7-9ab631d0ec72/mzaf_180342302023605984.plus.aac.p.m4a'),
    ('EL FENOMENO', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/ed/9c/00ed9c75-a8f1-46f7-8282-1340dc9a1c6b/mzaf_3715258946467331101.plus.aac.p.m4a'),
    ('Wenn ich will', 'Gzuz & Bonez MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/73/57/08/735708e9-f077-fd8c-08d1-978319a1ac16/mzaf_13477888586079796372.plus.aac.p.m4a'),
    ('Flouz kommt Flouz geht', 'Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/77/b7/cb/77b7cb01-e91d-9ecc-a228-4539489f2c42/mzaf_256287301416292071.plus.aac.p.m4a'),
    ('Dreckig & Gemein', 'Kontra K & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a6/92/90/a692903f-d0fb-ed0a-6b4a-c4c83c02b8c5/mzaf_4353049620056260625.plus.aac.p.m4a'),
    ('Lieber Gott', 'Capital Bra & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/23/08/74/2308746e-558b-9081-dd25-a7f5cbf73d13/mzaf_11368311504780643038.plus.aac.p.m4a'),
    ('Mira', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c3/11/f2/c311f26d-75d9-bc05-593c-460db824de65/mzaf_18362130171740636230.plus.aac.p.m4a'),
    ('Sommernacht', 'Lucry & Suena & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7f/4b/51/7f4b51ef-beac-2dd1-1bce-bf0d27ac277c/mzaf_10403581198310564281.plus.aac.p.m4a'),
    ('Coração', 'Haaland936 & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/cf/d2/4ccfd2da-e05f-3a8b-176f-b18dff504bb5/mzaf_14744560786401629024.plus.aac.p.m4a'),
    ('Azzlackz sterben jung 2', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/19/03/77/19037767-1b9a-6942-ceba-6da22cd665db/mzaf_14206146523469938179.plus.aac.p.m4a'),
    ('Ebbe & Flut', 'Gzuz, XATAR & Hanybal', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/24/7e/0b/247e0baf-9fef-70c6-099f-243650ab33e1/mzaf_10516582036709880938.plus.aac.p.m4a'),
    ('Imaginando', 'Eno, Morad & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/15/84/a5158479-abb7-969e-faa4-df2aa4123765/mzaf_5263152839562531237.plus.aac.p.m4a'),
    ('365 Tage', 'Samra & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c7/52/90/c75290f0-76c9-d9e3-1478-39f5337c8da4/mzaf_9526181682283822482.plus.aac.p.m4a'),
    ('CopKKKilla', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ea/68/ca/ea68ca41-619b-b614-74aa-88691d4138d5/mzaf_7018959603523466979.plus.aac.p.m4a'),
    ('Let''s Go', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/07/ae/57/07ae573e-222f-a123-bae2-2d8863ae93be/mzaf_7309876885742509461.plus.aac.p.m4a'),
    ('Hayati', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/99/c2/ac/99c2accf-db1d-35a3-a63e-d5d59db5c0f3/mzaf_13383349575854404170.plus.aac.p.m4a'),
    ('Mungu', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d4/e2/12/d4e212c8-a81d-eaba-ca24-d2262b07fc47/mzaf_13904135254925487554.plus.aac.p.m4a'),
    ('Blue Lagoon', 'GRiNGO & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/18/e5/23/18e52320-4854-b9ff-6d6a-c08029622d81/mzaf_11355190805518994757.plus.aac.p.m4a'),
    ('Panzaknacka', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1a/17/3c/1a173ca6-626e-eb0a-20bb-25414e44404e/mzaf_14294258829595518116.plus.aac.p.m4a'),
    ('Fajet', 'Dhurata Dora & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/3e/00/91/3e0091fd-ce8f-4858-cce6-35deff06a3e5/mzaf_15337132340459732093.plus.aac.p.m4a'),
    ('LOWLIFE', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/95/fb/34/95fb340c-e2df-4d30-d41e-9e0644955e7f/mzaf_1348284490872911620.plus.aac.p.m4a'),
    ('ICE', 'MERO & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/eb/16/cf/eb16cf6b-1753-ad7e-8061-5e5382f9e18b/mzaf_6524550815768888568.plus.aac.p.m4a'),
    ('Zombie', 'Samra & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/af/0c/85/af0c8599-a799-7388-1c1b-f542c06ef38a/mzaf_6336685802036783003.plus.aac.p.m4a'),
    ('Hade', 'KC Rebell, Eno & Hakim Lokman', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a5/7c/af/a57caf64-4dde-9fde-d58d-7e0b456bb576/mzaf_11383866726658884140.plus.aac.p.m4a'),
    ('Blutbad', 'AMO & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ee/a7/2d/eea72de7-0568-49d3-32f4-891f25dba90b/mzaf_14189828146150700813.plus.aac.p.m4a'),
    ('SOMMER 19', 'Nimo & Jenny Marsala', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b3/b2/d7/b3b2d760-e180-e0e5-ac72-dfe2e21df039/mzaf_5673037259087522885.plus.aac.p.m4a'),
    ('HEUTE NACHT', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b3/ea/e9/b3eae99b-5092-3d3d-4a3c-9b96386d65e2/mzaf_1441601545411226452.plus.aac.p.m4a'),
    ('IN MEINER DNA', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/dc/bb/e1/dcbbe133-0c47-6f8d-368f-cfab6cf27214/mzaf_12546886472788241672.plus.aac.p.m4a'),
    ('Wolke 7', 'Gzuz & Bonez MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e9/41/0e/e9410e1b-2b4d-d36a-7efd-a7819de402ed/mzaf_13052881702288110163.plus.aac.p.m4a'),
    ('Nympho', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4c/54/f9/4c54f957-4985-43e0-41db-eb8046e31131/mzaf_8386658173647346858.plus.aac.p.m4a'),
    ('Bebe', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/05/dc/7f/05dc7f0d-88c0-d24d-854b-ef6b89ee0fc4/mzaf_10512742672207057327.plus.aac.p.m4a'),
    ('Ich will alles', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1c/2d/23/1c2d2361-d35b-c088-e58c-4e80cb3da74a/mzaf_7598233389393935154.plus.aac.p.m4a'),
    ('Virus', 'Capital Bra & SDP', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8d/6c/0c/8d6c0cf8-23bf-2a82-c5e2-96bf2b29c914/mzaf_17617578479745007526.plus.aac.p.m4a'),
    ('MIND ON MY $$$', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6e/85/1b/6e851bfb-03dd-6679-c22f-d82364a909b4/mzaf_3366244369010142205.plus.aac.p.m4a'),
    ('Manchmal', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/37/2a/dd/372add09-902b-7c3e-b8be-c5e2079c196b/mzaf_9984244776565485716.plus.aac.p.m4a'),
    ('Odyssee', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8f/43/68/8f4368f2-d73e-e23e-1f79-7fb4bb3f5256/mzaf_368183158276235810.plus.aac.p.m4a'),
    ('Ararım Yarın', 'Murda & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1e/1d/14/1e1d14ec-5645-6d29-870c-2eccc59f886d/mzaf_17338544245438323162.plus.aac.p.m4a'),
    ('Pasha Nanen', 'Zuna & THIS IS DARDY', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/85/db/06/85db06fc-189b-b0de-d814-b4587486c6d0/mzaf_338615190257956012.plus.aac.p.m4a'),
    ('Leben lang', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d8/f4/0d/d8f40d73-eb7e-12e5-1118-23d455735f11/mzaf_9765868937453719377.plus.aac.p.m4a'),
    ('Bei dir', 'Jamule & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0d/56/f7/0d56f774-5530-c710-eafb-21b4cea67b77/mzaf_3093789863475407207.plus.aac.p.m4a'),
    ('Ohne Dich', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8b/fd/8f/8bfd8f4c-2991-d150-e5e3-526f5d00c47b/mzaf_4880904786904189352.plus.aac.p.m4a'),
    ('HOKUS POKUS', 'Kurdo & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/69/a1/d7/69a1d7ab-1a75-ad76-4c2f-4fadbd16b429/mzaf_15620536077385099501.plus.aac.p.m4a'),
    ('Island Chick', 'MERO & Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c4/85/ad/c485ad97-e1b2-2bc3-6c0b-10112eb841e2/mzaf_12854669792221657072.plus.aac.p.m4a'),
    ('Augen Husky', 'Olexesh & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/60/e7/25/60e725af-8d88-8f0d-a92f-91b447eb6586/mzaf_11162801179469308703.plus.aac.p.m4a'),
    ('Millieu 26', 'Kolja Goldstein & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/25/7c/f9/257cf9af-d138-c04b-ec2d-14ce685b1d0b/mzaf_6109046488295430534.plus.aac.p.m4a'),
    ('iPhone 17', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/40/f3/4c/40f34cba-a8db-6797-888c-7cc93e14382e/mzaf_12256929275888867498.plus.aac.p.m4a'),
    ('Solo', 'Haaland936 & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d5/20/ed/d520ed70-42b4-dce6-f712-d8c592c82c5c/mzaf_1966152671063651198.plus.aac.p.m4a'),
    ('D A YYY T O N A', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e4/20/6a/e4206a9f-4891-d0af-84c9-4de6e8dda24c/mzaf_11433374005308029906.plus.aac.p.m4a'),
    ('So wie du', 'Milano & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/df/57/95/df579572-3503-a8fa-949d-60703d96bffb/mzaf_11702766081507943210.plus.aac.p.m4a'),
    ('Kokaretten', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/9b/75/df9b755b-4620-65f4-1457-0c4dc8698adc/mzaf_17754221146657911384.plus.aac.p.m4a'),
    ('VALLA NEIN', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5f/91/1f/5f911f8d-6a4d-da66-b53a-7bf751e67305/mzaf_7771205189600950987.plus.aac.p.m4a'),
    ('Baile Funk im Blut', 'Jazeek & MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/55/50/4d/55504ddf-ac72-0615-35d1-18d8234604a1/mzaf_10703946474928974744.plus.aac.p.m4a'),
    ('Seele', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b2/6f/10/b26f104e-e3b9-21d0-482f-8aa65dfef2be/mzaf_15692779468919974294.plus.aac.p.m4a'),
    ('Kiss Me', 'Samra & TOPIC42', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8f/da/59/8fda5948-80a8-7f72-6cad-e8bfe0040533/mzaf_12086965538360916318.plus.aac.p.m4a'),
    ('Barbie & Ken', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/99/69/04/996904c7-b9a1-4a8b-ddda-e7534bab9e89/mzaf_2524642872684901284.plus.aac.p.m4a'),
    ('Saudi Arabi Money Rich', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ef/f3/86/eff3864f-7c42-7f51-1980-babc90c35ba7/mzaf_16097453012814403.plus.aac.p.m4a'),
    ('Beretta', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/fb/62/87/fb628789-b7ca-e377-dbd7-614d42a75add/mzaf_10549660590872910506.plus.aac.p.m4a'),
    ('Baby 2.0', 'Zuna & Lune', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ed/0c/b5/ed0cb548-6660-f237-554f-f28dfbb43ef3/mzaf_9944247864887438471.plus.aac.p.m4a'),
    ('SOBER', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/55/6d/1f/556d1f5d-473d-bc0b-dede-8110ff3fa2a3/mzaf_14782195066701509251.plus.aac.p.m4a'),
    ('STERNHIMMELDACH', 'BOJAN & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e4/73/58/e4735896-0800-4517-8f11-e6e6d6465e67/mzaf_18283054740411781302.plus.aac.p.m4a'),
    ('Asozialer Araber', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/06/c9/32/06c93209-0b8c-856c-d752-32a611806f4c/mzaf_6983262192757295817.plus.aac.p.m4a'),
    ('Flexscheibe', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a0/05/94/a0059486-53a3-ab8b-3033-da112dd2dcd0/mzaf_2101678860267514268.plus.aac.p.m4a'),
    ('Immer mehr', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/11/e5/4a/11e54a01-d5a3-0e86-2c3d-5d25d99ca649/mzaf_7996831902801745958.plus.aac.p.m4a'),
    ('KINGINMEIMDING', 'Jan Delay & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2f/33/b1/2f33b1c0-900c-87ad-2484-04b221a56c31/mzaf_7957014747809813670.plus.aac.p.m4a'),
    ('Baby Mama', 'Saliou & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/45/ed/60/45ed6082-5f22-65a3-987c-8b0bc9b64e6a/mzaf_286500367577267129.plus.aac.p.m4a'),
    ('ICH MACH ES', 'AK AUSSERKONTROLLE & Undacava', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/87/03/17/87031742-614f-f5ff-da36-dd53a0559d4a/mzaf_16238059611758974715.plus.aac.p.m4a'),
    ('FEFE', 'MERO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e4/16/c3/e416c31c-01ce-140a-c003-a248f19e4a7a/mzaf_8252930992430232252.plus.aac.p.m4a'),
    ('Ich brauch Dich', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/20/39/0b/20390b57-445d-8b4c-57e9-d457588cea22/mzaf_9257831932181720993.plus.aac.p.m4a'),
    ('Plaza', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/31/7b/f5/317bf58a-0ca0-ad37-4cee-3bcc7d53354f/mzaf_2357910546520271752.plus.aac.p.m4a'),
    ('BETTER DAYZ', 'Summer Cem & Geenaro & Ghana Beats', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/29/b9/9029b96f-d613-0b83-78e8-79fa02fefb36/mzaf_17349856476015755068.plus.aac.p.m4a'),
    ('Vollautomatik', 'Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9f/3c/70/9f3c70e9-9bbe-4da7-9a24-65c01111d8eb/mzaf_7212571350845679588.plus.aac.p.m4a'),
    ('Muskat', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bb/17/87/bb178761-34d8-fcd8-baed-d5934114bad8/mzaf_7604958326324676606.plus.aac.p.m4a'),
    ('Mbappé', 'Capital Bra, Farid Bang & Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7c/6e/76/7c6e76f8-7a1c-e8f4-4964-87fd3c412a01/mzaf_5852759872042665208.plus.aac.p.m4a'),
    ('Shakal', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/07/45/24/074524df-b08e-8aaf-b59e-f26112b4051d/mzaf_12075536709454482423.plus.aac.p.m4a'),
    ('fastlane', 'Jamule & SANTOS', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/8e/76/ad8e7607-3830-15e4-1e87-ffe3f5bc5663/mzaf_15445900265373325584.plus.aac.p.m4a'),
    ('AMCAOGLE', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/72/dd/26/72dd2648-7a6e-50b0-b00f-8cff55484f68/mzaf_12015300932378038402.plus.aac.p.m4a'),
    ('Papaya', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d0/1c/ae/d01cae60-fcfc-b68d-bd26-4385f02b3ffa/mzaf_6945943440048941783.plus.aac.p.m4a'),
    ('SAYFA', 'KC Rebell, ERAY067 & MANSUR', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/c4/32/adc43260-2cca-1ae7-d2c6-8e91690fad03/mzaf_14594639550616219058.plus.aac.p.m4a'),
    ('Bounce', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3e/e1/2a/3ee12a15-37e4-7e86-114d-83b776d6e2c3/mzaf_10806613783983381837.plus.aac.p.m4a'),
    ('Bang', 'Avie, Delil & Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9a/54/5f/9a545f35-04b6-ce4b-e77c-ad9fa62fdc80/mzaf_5353498550943481217.plus.aac.p.m4a'),
    ('Ich hol dich ab', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/71/8d/92/718d920a-17d1-2850-407a-460bd12c379c/mzaf_5557041756307681948.plus.aac.p.m4a'),
    ('WEEKEND', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/50/62/d2/5062d2fc-2dc6-426d-cb14-f115402d2e2a/mzaf_13257673340527140850.plus.aac.p.m4a'),
    ('GEH DEIN WEG', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/bb/2b/62/bb2b6214-477e-2967-10eb-8f2e8a58c334/mzaf_2674117372261885035.plus.aac.p.m4a'),
    ('Rapstars', 'MERO & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/e1/d1/ed/e1d1edd5-87c9-1f52-ca16-6f63e7ef3ff7/mzaf_15758470549444891591.plus.aac.p.m4a'),
    ('Scarface', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d1/af/06/d1af0655-cb93-f3c4-f107-dc5123f62b6e/mzaf_4194029981444940817.plus.aac.p.m4a'),
    ('Hasta La Vista', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/48/e1/c3/48e1c3f3-d5b9-aff9-d58a-b3c7b2e177d6/mzaf_13745750907879057003.plus.aac.p.m4a'),
    ('Früher pleite heute Benz', 'Capital Bra, Nimo & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/dd/04/29/dd04293d-90db-d2db-956e-f087f76d8596/mzaf_5136164056544082353.plus.aac.p.m4a'),
    ('Vollmond', 'Eno & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b4/c1/ea/b4c1ea70-8f82-1aef-afee-b8d1258297d5/mzaf_6222989369231707085.plus.aac.p.m4a'),
    ('Magie', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f2/43/42/f243425a-4d8f-36c7-59c8-cac57377387b/mzaf_11137417536037913128.plus.aac.p.m4a'),
    ('MedMen', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/3d/29/1c/3d291cdd-39e1-b4a8-fbde-ba180e461b82/mzaf_14931280243635793712.plus.aac.p.m4a'),
    ('Wenn ich geh', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9a/d4/83/9ad483d2-614a-bdc4-47a5-2a46e23c8b8f/mzaf_9898564158799472704.plus.aac.p.m4a'),
    ('DU FEHLST', 'Kurdo & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1b/6f/a6/1b6fa625-fa7e-380f-cfd7-5fbd69c6ee2a/mzaf_17553965928552408157.plus.aac.p.m4a'),
    ('Leer', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b6/97/b2/b697b2fe-5c4a-8ed0-d194-c35d418568fb/mzaf_1015873396939824373.plus.aac.p.m4a'),
    ('DOWN', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/92/02/aa/9202aa59-f8f2-7557-4467-38bf079bd61a/mzaf_10896118133884310618.plus.aac.p.m4a'),
    ('Jaloux', 'CAPO & Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/6b/a9/cd/6ba9cd8e-5566-435c-7d64-e6e7c89c3544/mzaf_17978779324035698619.plus.aac.p.m4a'),
    ('Paper', 'KC Rebell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/74/5b/4c/745b4c88-5b21-66ab-b96d-91ee6b9e507c/mzaf_24353185889449714.plus.aac.p.m4a'),
    ('WOW', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/85/f6/5f/85f65f90-097f-a1a4-9bce-53175fdd77f3/mzaf_562390783016249861.plus.aac.p.m4a'),
    ('Model', 'RAF Camora, Dardan & Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ba/94/eb/ba94eba7-8fb5-3497-792c-44ca5e3ec580/mzaf_17263892315971117117.plus.aac.p.m4a'),
    ('La 3youne', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/75/24/c4/7524c492-177a-32ef-cf47-3bceea835803/mzaf_12543184924114294351.plus.aac.p.m4a'),
    ('MAHALLE', 'Cave & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/cd/14/7a/cd147a28-ac58-5bf1-bada-1d8792d449ce/mzaf_4867614436575811670.plus.aac.p.m4a'),
    ('Nala', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/73/ba/fc/73bafc46-d47e-971a-43cd-2024b6d20519/mzaf_3130373461824674740.plus.aac.p.m4a'),
    ('SOMMERNÄCHTE.mp3', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/14/00/1b/14001b06-9738-6b22-c390-61c3869f039d/mzaf_9230929796737967998.plus.aac.p.m4a'),
    ('Buonasera', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c4/f7/65/c4f765c3-42b9-1e1d-17f8-3562239d0ac4/mzaf_8614215666656592719.plus.aac.p.m4a'),
    ('Weisse TN Sneakers', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d7/c1/14/d7c11419-2174-25f2-1eb5-0fb736aaabda/mzaf_16161091224259706633.plus.aac.p.m4a'),
    ('Glizzy', 'Jamule & Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/d7/e7/a5d7e7cd-e597-3406-8c70-df4d6be65524/mzaf_8582882596024662500.plus.aac.p.m4a'),
    ('Junimond', 'Jamule', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/78/42/d3/7842d3ea-f646-9130-a0a2-a47c0fb38b73/mzaf_442708172685093349.plus.aac.p.m4a'),
    ('LAYLA WA LAYLA', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/90/86/56/90865651-be54-7e4e-d690-e21b72fc6324/mzaf_9959651745519395725.plus.aac.p.m4a'),
    ('USDT', 'Haaland936 & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a6/21/5e/a6215e41-55b9-ef5d-ff80-75f8b19e16f2/mzaf_8284436615119124255.plus.aac.p.m4a'),
    ('Rendezvous II', 'Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/a8/c9/47/a8c947a4-5f2e-0ef1-94dd-487bfac894e8/mzaf_11453273254456339464.plus.aac.p.m4a'),
    ('DRÜCK', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/67/6c/87/676c8727-d173-4556-feed-56d88157f1aa/mzaf_2272216899427668193.plus.aac.p.m4a'),
    ('Mannschaft', 'Delil & Kurdo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/12/e0/46/12e046f4-34d2-1138-1ec4-dd5c78136f8d/mzaf_16819881741453730824.plus.aac.p.m4a'),
    ('Ring Ring', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/83/f4/d283f42b-171b-98ab-9740-ac70abdafd57/mzaf_6864107917543808666.plus.aac.p.m4a'),
    ('MAVI', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c8/7d/42/c87d4253-aebe-c7e5-573b-d7cd532e851f/mzaf_10798492575093691513.plus.aac.p.m4a'),
    ('Biturbo', 'Bausa & Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/6b/f5/40/6bf54028-1805-09b3-98cb-664d6a796009/mzaf_6247920531230844403.plus.aac.p.m4a'),
    ('Ghetto Karibik', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/b9/4a/0d/b94a0d58-cd67-23b2-32c3-b4fd6f77e65a/mzaf_928002590461195333.plus.aac.p.m4a'),
    ('MAGHREB UNITED', 'Ataypapi, ILO 7ARAGA, Miami Yacine & YONII', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d5/25/1d/d5251ddd-a495-c86a-fd86-bf2812a8588a/mzaf_1522284100641962249.plus.aac.p.m4a'),
    ('SORRY', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/c2/0a/c9/c20ac97b-f7a5-ed4e-6087-7fa6d560fd32/mzaf_4994399661361189215.plus.aac.p.m4a'),
    ('Nador', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/03/e4/a1/03e4a1c6-5ab1-5a34-6a24-1ff8aecb7690/mzaf_2586790022395316774.plus.aac.p.m4a'),
    ('WAS IST LOS?!', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2c/a7/84/2ca784cf-7e63-c118-6018-f9f845269666/mzaf_10747796428684819033.plus.aac.p.m4a'),
    ('Hautfarbe Cappuccino', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/fc/43/61/fc436194-f504-529a-be0b-99100dce0221/mzaf_8764121993852182512.plus.aac.p.m4a'),
    ('Komet', 'Udo Lindenberg & Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c8/4b/3b/c84b3b17-a6d1-bb27-f307-567b5437a81c/mzaf_1931028906472802154.plus.aac.p.m4a'),
    ('Ferrari Testarossa', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7a/59/cc/7a59cce4-7575-75db-a050-e806e411c4c0/mzaf_11522520052038932727.plus.aac.p.m4a'),
    ('Sie ruft', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d8/a9/6f/d8a96f65-2399-a75b-b528-ecdd0973f6a2/mzaf_10434323037045221451.plus.aac.p.m4a'),
    ('2 Minuten', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/77/ec/c5/77ecc56b-eb38-1197-3bb3-7ee3147d96eb/mzaf_17360550808438090830.plus.aac.p.m4a'),
    ('Blue Porsche', 'Luciano & Niska', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c3/03/04/c3030497-71ce-9419-6e17-9247790757e0/mzaf_662272406190326409.plus.aac.p.m4a'),
    ('PEPPERMINT', 'Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/16/2d/76/162d76b5-fac7-a816-28f2-1b74dbd1d4b8/mzaf_2416212102340906687.plus.aac.p.m4a'),
    ('Perfekt', 'RAF Camora & AriBeatz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/e0/d5/9d/e0d59d30-99d9-8ded-bf05-f59ae5ce57cd/mzaf_16756318283018762656.plus.aac.p.m4a'),
    ('So lala', 'RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d8/b1/52/d8b15218-bfbf-b770-5d8e-650ccf5f4bf7/mzaf_12549097954957148233.plus.aac.p.m4a'),
    ('Tattoos', 'Luciano & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/59/6f/1f/596f1fb8-3c32-458e-3d7f-6a587cfd3a68/mzaf_16928770386829081688.plus.aac.p.m4a'),
    ('Strada', 'RAF Camora & Ahmad Amin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ae/58/63/ae586301-c3b5-2125-719b-9676c939f1da/mzaf_7473982923129836878.plus.aac.p.m4a'),
    ('Verändert', 'Bonez MC & RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/90/9b/ed/909bed1d-4fd3-0dec-2b90-f5759a669950/mzaf_9333173639869732012.plus.aac.p.m4a'),
    ('Maschine', 'RAF Camora & The Cratez', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/14/69/bc/1469bc3e-1b93-7b0b-c319-24db3aab2363/mzaf_2246411357821639701.plus.aac.p.m4a'),
    ('Schnapp!', 'Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/d3/e7/c6d3e765-95d0-97a3-fdf3-927108e4913a/mzaf_13023911471361382533.plus.aac.p.m4a'),
    ('Haifisch Nikez', 'LX, Maxwell & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0e/8b/0b/0e8b0b7a-cb59-9332-0fc0-769baeb6f3f6/mzaf_12495099218275493170.plus.aac.p.m4a'),
    ('Prollz', 'Gzuz & Maxwell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/cc/7c/e3/cc7ce3ff-b406-6aa2-56f8-a01e59ff3c82/mzaf_9428122477964429665.plus.aac.p.m4a'),
    ('Komm zu 187', 'Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ba/16/71/ba16719a-27e2-1283-e8f7-13997a459d84/mzaf_15736945845902088228.plus.aac.p.m4a'),
    ('Blättchen und Ganja', 'Gzuz & Bonez MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/21/26/27/212627e1-4a9a-476a-6505-e5a505fa6e23/mzaf_13080797224659610223.plus.aac.p.m4a'),
    ('Grabstein', 'Bonez MC & Gzuz', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7a/41/cc/7a41cc4f-59ca-dd5e-b928-b53b38a4493a/mzaf_17239168860286297389.plus.aac.p.m4a'),
    ('Gefährlich', 'Gzuz & Bonez MC', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d1/66/1f/d1661f1a-52bc-6742-f130-ca93997b5bbe/mzaf_4832657311046250397.plus.aac.p.m4a'),
    ('Irgendwann', 'Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6f/ef/4a/6fef4aae-9508-50d1-c9d9-ee18d3b3526a/mzaf_7920455585732442865.plus.aac.p.m4a'),
    ('So alleine', 'Capital Bra & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f8/21/2c/f8212cc1-4fcd-fbfb-eeee-240176599643/mzaf_7835713021609659509.plus.aac.p.m4a'),
    ('Tranquillo', 'Capital Bra & Samra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/db/7d/9d/db7d9de8-d682-5fcb-03df-c24ebf0488ae/mzaf_2480976353471496537.plus.aac.p.m4a'),
    ('Tief in die Nacht', 'Samra & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b1/91/24/b1912406-57dc-5119-d945-ec1d9a78dda4/mzaf_12813590550544286430.plus.aac.p.m4a'),
    ('BIELEFELD', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/cc/11/58/cc11588c-a34f-34f4-61a4-a674b4636717/mzaf_16263017425410838093.plus.aac.p.m4a'),
    ('PHANTOM', 'reezy & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/49/9c/ed/499ced17-bce3-ba35-16c3-2f5b054a308b/mzaf_5550829873580695324.plus.aac.p.m4a'),
    ('GEHT NICH GIBS NICH', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/57/f9/74/57f974f9-8492-4a14-4b42-0b7e8d89090f/mzaf_17896304438888081365.plus.aac.p.m4a'),
    ('FLEX SO HARD', 'Summer Cem & Miksu / Macloud', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9b/b8/82/9bb882a9-8621-3fdc-8ba8-b5deca16bba4/mzaf_6861097098223896758.plus.aac.p.m4a'),
    ('RATCHET', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/ca/19/8c/ca198ce7-c5ad-2e6a-ef27-2a8d0792af22/mzaf_9454612053093393379.plus.aac.p.m4a'),
    ('WARNER CASH', 'Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/00/5b/3e/005b3eca-0a54-12b5-e000-2843bf049946/mzaf_6822744264058997034.plus.aac.p.m4a'),
    ('IRON MAN', 'KC Rebell & Summer Cem', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/27/0a/e1/270ae174-07e3-9e17-cf8d-11c9f67e5108/mzaf_15170879008391717619.plus.aac.p.m4a'),
    ('Tagebuch', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/52/e2/6a52e21f-ddf8-da3e-3ec4-84c6fffedbfa/mzaf_11363355878459504484.plus.aac.p.m4a'),
    ('Dale', 'Dardan & Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/65/44/7e/65447e38-3b73-4c3d-3f52-7db8bd18b00d/mzaf_5785039631957696441.plus.aac.p.m4a'),
    ('Mango', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c9/af/25/c9af25e6-1c2c-7b54-257f-465da61bcfa7/mzaf_13542782518865931379.plus.aac.p.m4a'),
    ('Family', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/58/2a/6c/582a6c6e-f6bb-415b-8fb3-6cd91009ccae/mzaf_10526082280009030103.plus.aac.p.m4a'),
    ('Handy brennt…', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ec/71/f7/ec71f706-a5cd-771d-ec83-95942cb6cdf0/mzaf_1283901028520124123.plus.aac.p.m4a'),
    ('Nicht da', 'Azet', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/17/af/80/17af80e5-4159-81c1-d6dd-dd89abd5f89d/mzaf_7622977966442664289.plus.aac.p.m4a'),
    ('Caliente', 'Zuna & Shabab', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/37/f0/30/37f030a3-0267-eb25-4cda-e9c72585f01a/mzaf_5217201572072935778.plus.aac.p.m4a'),
    ('Hol mir deine Cousine', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b7/43/ee/b743ee3c-a76d-0cdd-fe2e-2bd7ba1d3a0d/mzaf_9556768465452639955.plus.aac.p.m4a'),
    ('7 Sitzer', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/45/ff/8a/45ff8aa7-d5c3-72c9-39b1-888bdd2731db/mzaf_333299023830826263.plus.aac.p.m4a'),
    ('I Love You', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/c1/a4/ecc1a415-cc86-e5f5-7376-459adc61082d/mzaf_4503705299515093535.plus.aac.p.m4a'),
    ('Neapel', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/33/5f/cd/335fcd64-de9f-8c74-d472-3e91a6b66a7a/mzaf_13175410053325927094.plus.aac.p.m4a'),
    ('DRECKIGE DOLLARS', 'Kurdo & Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/4a/07/24/4a072458-6fa8-7b49-446b-53214868bdb8/mzaf_5625609685975512157.plus.aac.p.m4a'),
    ('Wo du warst', 'Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/af/d1/1e/afd11e6a-e14b-18c7-c62f-0e9e88d3633e/mzaf_8807199689171519672.plus.aac.p.m4a'),
    ('Fefe Italia', 'Delil & Zuna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/28/18/ad/2818ad03-c862-52e3-e5b4-5902b8467e18/mzaf_17718251644378212953.plus.aac.p.m4a'),
    ('DILEMIN', 'Eno & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a2/d5/5a/a2d55a1b-65a1-c3ff-79c6-e95faa41793a/mzaf_499600063130735107.plus.aac.p.m4a'),
    ('Nie wieder', 'Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/44/cf/3d/44cf3dac-ca49-3c4a-b6f0-a0087543879c/mzaf_14356955254416632531.plus.aac.p.m4a'),
    ('Trendsetter', 'Nimo & Rina', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/42/0d/e1/420de1e4-63a9-7d66-a48b-f2a2d632f102/mzaf_4486183672159469638.plus.aac.p.m4a'),
    ('Bitter', 'Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/52/15/7c/52157cfa-52f4-1bf9-f92e-b0c7e4dc1570/mzaf_5010329278954673478.plus.aac.p.m4a'),
    ('Para Drill', 'Dardan & Nimo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ca/b2/be/cab2be39-2de5-130f-43b2-57c33720bf36/mzaf_8918781499390933561.plus.aac.p.m4a'),
    ('STAR', 'Nimo & Luciano', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/85/ca/99/85ca99f2-4158-5869-47d0-16a33fd510ac/mzaf_13784144060500955493.plus.aac.p.m4a'),
    ('CASH DA', 'Nimo, reezy & KALIM', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a2/57/c4/a257c47f-abfe-1f04-2aed-2f7ebfd43230/mzaf_1225637063440577841.plus.aac.p.m4a'),
    ('CLASSIC', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/02/27/f3/0227f30e-e654-15f3-9651-d23237b16f5b/mzaf_4322190388412081195.plus.aac.p.m4a'),
    ('Bon Voyage II', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/38/6b/ff/386bffdf-b8ff-4df9-8885-a8c121ec8778/mzaf_16122372931988548775.plus.aac.p.m4a'),
    ('AKRAPOVIC', 'Miami Yacine', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/3a/9f/33/3a9f33cb-1f57-7c0c-7815-ff4bc287fa71/mzaf_13936528093901784685.plus.aac.p.m4a'),
    ('Désolé', 'Stef Becker, Kofs, Miami Yacine & Bendo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/61/d8/19/61d8192b-4c0b-f80f-5f78-4d2fce83c2e8/mzaf_11924904944347898954.plus.aac.p.m4a'),
    ('Ti Amo', 'Dardan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f8/e4/98/f8e4982a-2bda-ddc2-8170-c77c6c3086a9/mzaf_4522595372364098278.plus.aac.p.m4a'),
    ('Highlight', 'Dardan & Jamin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/4c/94/c1/4c94c18e-9087-ddea-ad96-8fd9e8b065ee/mzaf_1200630864984026125.plus.aac.p.m4a'),
    ('SALTBAE', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/d5/6f/76/d56f76c7-8c8c-7ea8-05de-ee9f725144ca/mzaf_2092252098612122395.plus.aac.p.m4a'),
    ('MIDDLE OF THE DAY', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/35/66/8f/35668f76-534e-479d-a4a0-8a0fdd8863d5/mzaf_4410102788200088820.plus.aac.p.m4a'),
    ('STERNENHIMMELDACH', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/e5/b8/5d/e5b85d94-9b3f-a8a5-0495-a744fa90ba15/mzaf_16946620599330744331.plus.aac.p.m4a'),
    ('LICHTER DER STADT', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview114/v4/9b/3c/1f/9b3c1f33-2f80-3b39-171a-5dcca582f89b/mzaf_9465471004854331324.plus.aac.p.m4a'),
    ('KOMM MIT MIR', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/f3/ba/bb/f3babb64-6550-8c55-2414-baf331f43690/mzaf_8697147793238315396.plus.aac.p.m4a'),
    ('LETZTE NACHT', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/d5/5d/45/d55d450d-4bb4-d1de-17bb-964d2b53925f/mzaf_2261053335063831624.plus.aac.p.m4a'),
    ('HOCHHAUS', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/f3/29/91/f3299193-0ff6-7acc-bc5c-b88fa98c475e/mzaf_16216501254490059583.plus.aac.p.m4a'),
    ('TRÄNEN', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/53/70/b6/5370b6a6-b00b-f579-05c8-97865a8221ee/mzaf_9659163818166575910.plus.aac.p.m4a'),
    ('8 MILE', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview114/v4/6d/e7/9a/6de79ab4-77ad-9ff5-7feb-4db274ff14e7/mzaf_878454817073982153.plus.aac.p.m4a'),
    ('VON UNTEN', 'Majoe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/41/3b/df/413bdfb8-32a3-105c-93f9-e7ed392b89d4/mzaf_5520019185104127914.plus.aac.p.m4a'),
    ('KEINE', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview114/v4/2a/6c/2a/2a6c2a3b-a374-3ce1-1992-3e7e1d31a29c/mzaf_10809023378063671116.plus.aac.p.m4a'),
    ('CONDOR', 'Majoe & Silva', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview124/v4/10/74/0c/10740ca1-00fb-274f-4a28-dd87c3697c92/mzaf_11147229919562839271.plus.aac.p.m4a'),
    ('IMMER UNTERWEGS', 'AK AUSSERKONTROLLE & Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cc/4c/ef/cc4cefcc-76c0-ba28-c727-3f6b27107a87/mzaf_1171581247820736063.plus.aac.p.m4a'),
    ('HABIBI', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/bc/ab/a8/bcaba8ac-d2d0-5d3d-2c3c-6bc62be4e4aa/mzaf_1142964363303506908.plus.aac.p.m4a'),
    ('Prominenz', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0b/71/9a/0b719a6d-ca9b-4b27-db5a-ee5327ea6bcd/mzaf_15499235219377359044.plus.aac.p.m4a'),
    ('Bang Bang', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c1/5e/70/c15e706e-14ee-0793-4b3f-4441c1390eac/mzaf_1180048103279485011.plus.aac.p.m4a'),
    ('BIG MONEY', 'AK AUSSERKONTROLLE', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/85/b3/b7/85b3b772-e734-b648-56c0-218f5cfedf23/mzaf_3056237664319644718.plus.aac.p.m4a'),
    ('Discokugel', 'Gustav, NOAH & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/1a/cf/11/1acf11c0-be0a-b4e4-008d-494b8dcfaf40/mzaf_15125068063405641959.plus.aac.p.m4a'),
    ('FLÜGEL', 'Capital Bra & Samo104', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e2/f5/e7/e2f5e7a1-aa7d-cec9-a236-01309a0feb05/mzaf_283694240929386023.plus.aac.p.m4a'),
    ('VIJA VIJA', 'DJ Gimi-O & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/6e/f8/8a/6ef88ab5-5d91-6e9f-8937-6bdd2513258e/mzaf_17128033351433615102.plus.aac.p.m4a'),
    ('Roli Glitzer Glitzer', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f3/54/0d/f3540d8c-bbbc-7f22-bac3-1c98b74987dd/mzaf_1874144519483597054.plus.aac.p.m4a'),
    ('Bye Bye', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e5/2c/ac/e52cac0b-db88-dd9e-5e3b-3ddfc00542cf/mzaf_1207722572390496038.plus.aac.p.m4a'),
    ('Leuchtreklame', 'Haftbefehl, Schmyt & Bausa', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/88/c9/ea/88c9eae0-4fd9-873a-2306-f8b38f36de03/mzaf_10308436962489655325.plus.aac.p.m4a'),
    ('1999, Pt. II', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/65/ac/88/65ac88f1-d186-939d-a654-a392888c2baf/mzaf_200189585473977267.plus.aac.p.m4a'),
    ('OZEAN', 'KALIM & Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/28/99/c6289936-b8e7-6cb0-2180-753fc08599cd/mzaf_3167788873948001450.plus.aac.p.m4a'),
    ('Frisch aus der Küche', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/42/3f/a6/423fa67e-1be1-1717-7758-5da49cab2dae/mzaf_12634619335646480191.plus.aac.p.m4a'),
    ('Bolon', 'Haftbefehl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7b/f2/73/7bf2737a-4b9c-d1f6-29c9-859720bf30d4/mzaf_11201987033338370006.plus.aac.p.m4a'),
    ('Bend Over', 'Jazeek', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/34/7f/4e/347f4e67-7028-436d-bc1e-9a46509e1827/mzaf_16659049740227403575.plus.aac.p.m4a'),
    ('Ma Baby 2', 'Jazeek & Lune', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e5/1e/5f/e51e5f8b-4e31-4f91-84e2-102776cfed38/mzaf_6313519103486899946.plus.aac.p.m4a'),
    ('Damals', 'Aymen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cb/d4/3c/cbd43c19-75f8-4235-7ed2-71fc71cf22b1/mzaf_12453833949439085787.plus.aac.p.m4a'),
    ('Far Away', 'Aymen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview62/v4/20/a3/cc/20a3ccfd-c1f3-6a4a-a053-37eeba5d5e00/mzaf_5901238489625417499.plus.aac.p.m4a'),
    ('Alles ist geschrieben', 'Aymo, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/36/de/69/36de69a3-e4c1-f63d-0ac2-ac38ecadab23/mzaf_5588635378609473327.plus.aac.p.m4a'),
    ('Tiki Taka', 'Haaland936, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/42/41/0a/42410a57-048a-1079-c6d5-6ef96300bc9c/mzaf_6988563997818834704.plus.aac.p.m4a'),
    ('24 Karat', 'Aymo, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e6/cf/24/e6cf248c-6487-87a1-7cd5-f3b2cf02d0a6/mzaf_18341087834244559024.plus.aac.p.m4a'),
    ('Dinero', 'AYMEN & PIO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/82/5b/a4/825ba498-836c-8e74-cb85-55a27e86896c/mzaf_5307216003926844122.plus.aac.p.m4a'),
    ('Justizia', 'Shafo & AYMEN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/4c/3a/2b/4c3a2bcd-0e9b-342b-3e02-8036a46fb3d1/mzaf_16305213200841525992.plus.aac.p.m4a'),
    ('Hood Bandolero', 'Lio, Aymen & Ché Salah', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fc/0e/f3/fc0ef326-e399-1999-2002-df8c7245f3d4/mzaf_2382297477009858894.plus.aac.p.m4a'),
    ('Trance', 'Aymo, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a7/d5/9d/a7d59d3f-a6ea-5486-5ca5-0096ba76f47b/mzaf_14576426244346965909.plus.aac.p.m4a'),
    ('Rot oder schwarz', 'Aymo, Aymen & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/4d/30/29/4d302986-3630-110b-0238-dcda469d3ea2/mzaf_15099476564911054036.plus.aac.p.m4a'),
    ('Happy Tears', 'Miles Away, Aymen & RUNN', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/d0/7a/6a/d07a6ada-2fc9-848b-1ec2-469a5f141e59/mzaf_9136838028181740013.plus.aac.p.m4a'),
    ('Beautiful People', 'Miles Away, Aymen & braev', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview112/v4/df/f3/0b/dff30b69-4f2f-5772-c78c-47ee3f1095dd/mzaf_4935811250074588555.plus.aac.p.m4a'),
    ('LAMBADA', 'Eno & Ataypapi', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f1/30/a2/f130a221-3455-27e6-1e8a-7e0efaf2b05a/mzaf_2641231104817836374.plus.aac.p.m4a'),
    ('Aladdin', 'Ardian Bujupi & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/f7/5d/46/f75d46a6-4158-896c-d400-e7457eb062d3/mzaf_13639978759090706750.plus.aac.p.m4a'),
    ('Wo bist du', 'Jamule & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/93/e7/1b/93e71bae-a179-29b7-f1e2-9dca946c79c0/mzaf_5177999134617172159.plus.aac.p.m4a'),
    ('Yanee', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/c2/8b/5d/c28b5db4-5bf9-f0d7-e61f-4ad4f6de4b0e/mzaf_13339291885886255480.plus.aac.p.m4a'),
    ('Talentiert', 'Eno & Pronto', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/42/8a/bb/428abbd7-5c96-6b33-83af-906544bf07e8/mzaf_18292549777148692530.plus.aac.p.m4a'),
    ('Vertrauen', 'Nimo & Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/24/37/67/243767aa-7338-2dfb-39cc-74b1522d6c68/mzaf_6129678092994447297.plus.aac.p.m4a'),
    ('DTEC', 'Eno', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/69/8d/36/698d363d-70c9-4893-a7fb-7a6c0a24b4b5/mzaf_3494644824400844434.plus.aac.p.m4a'),
    ('Safe', 'Eno & Doria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/19/2a/d6/192ad611-67e3-b7af-474e-3c0bfc4319fd/mzaf_7576792300764376577.plus.aac.p.m4a'),
    ('Makarova', 'Asche & Kollegah', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/84/e5/6b/84e56bea-ef02-d210-bbc9-827f1ac2dab9/mzaf_9985403177405777412.plus.aac.p.m4a'),
    ('Von Salat schrumpft der Bizeps', 'Kollegah & Bosshafte Beats', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/e8/85/b1/e885b140-dc30-be9b-78f6-347694463860/mzaf_18229387597919805666.plus.aac.p.m4a'),
    ('Nwo', 'Kollegah & Bosshafte Beats', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/dc/dc/72/dcdc7267-f884-ca46-acab-8983a65cf7ce/mzaf_10244023334043143593.plus.aac.p.m4a'),
    ('FREE SPIRIT', 'Kollegah', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/26/18/29/2618295f-48e2-254d-18b0-a6338ee0aaab/mzaf_14171758539322289896.plus.aac.p.m4a'),
    ('EINE BRUDERSCHAFT BLEIBT', 'Farid Bang & Kollegah', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/95/cb/45/95cb45a9-2727-594d-7060-5f55346620ab/mzaf_691274111876189939.plus.aac.p.m4a'),
    ('NADOR CITY GANG', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/82/52/10/8252106e-87d6-ff7f-f8d6-7b38e7e82de8/mzaf_10586437335603008841.plus.aac.p.m4a'),
    ('KAMPFSPORT', 'Farid Bang & Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f0/4d/e7/f04de7af-b705-32d4-441e-046e59de271b/mzaf_13622995244220406224.plus.aac.p.m4a'),
    ('TESTOSTERON', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/56/72/ba/5672bafe-ac43-ba6b-4fce-8af97c008483/mzaf_12230375736103430974.plus.aac.p.m4a'),
    ('MONEY II', 'Farid Bang & ELIF', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/a0/76/7e/a0767ecf-18c2-0ede-9edf-5cafd35bd4b3/mzaf_1722756917228918935.plus.aac.p.m4a'),
    ('Guerilla', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/76/c9/06/76c906c9-97b2-c4c1-333f-2a790f251ab5/mzaf_13600827758097839912.plus.aac.p.m4a'),
    ('BITTE SPITTE X', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d0/16/3a/d0163a05-e42e-1265-5cf9-9234476ab67d/mzaf_14314533941015686655.plus.aac.p.m4a'),
    ('GET RICH DIE TRYIN''', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a4/43/af/a443afeb-7a4d-6cea-b210-333a896558e6/mzaf_6050327531032361006.plus.aac.p.m4a'),
    ('CITY GANGSTER', 'Farid Bang, CAPO & Veysel', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e9/81/01/e981019e-1b2d-0a46-31e3-80eaf1580097/mzaf_15207516254052509942.plus.aac.p.m4a'),
    ('KRONE', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d7/b5/26/d7b5265b-7698-1708-214c-f2fb4ea18f6b/mzaf_2065872651456502689.plus.aac.p.m4a'),
    ('Casanova', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/51/9f/fe/519ffe58-eb5f-9644-5c22-80f9c20bc587/mzaf_8964798569291865440.plus.aac.p.m4a'),
    ('Bitcoins', 'Capital Bra & Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/e5/90/8e/e5908e4a-dac7-7e76-3181-3933de28aeab/mzaf_7417890863428910713.plus.aac.p.m4a'),
    ('quavo', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/fb/16/ec/fb16ec9b-3cf2-9cff-b4ad-8501d65d14b2/mzaf_8107356921002811773.plus.aac.p.m4a'),
    ('BERGHAINCLUB', 'Farid Bang', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/4b/41/22/4b41229e-046f-aef3-52d1-2d488d11670e/mzaf_1314922449914680265.plus.aac.p.m4a'),
    ('Alles', 'Schubi AKpella & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2e/80/46/2e8046d0-55aa-0b25-6d2c-f56011b2df54/mzaf_5573760364293598363.plus.aac.p.m4a'),
    ('Endlos Verliebt', 'Amo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview126/v4/79/b2/f5/79b2f57e-185f-fcee-9ef8-a2946e2d2631/mzaf_16974262877111658150.plus.aac.p.m4a'),
    ('Inkognito', 'Delil & AMO', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/91/76/cb/9176cb84-12b4-9978-63e7-d76d73b77a8a/mzaf_10560736983716220942.plus.aac.p.m4a'),
    ('HOTS 4 U', 'Chris Lorenzo & aMo (um)', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/63/13/4d/63134d70-3a43-b375-71f0-906f4dfafde7/mzaf_1816836247431571933.plus.aac.p.m4a')
) AS v(title, artist, url)
JOIN public.topic_pool tp ON tp.text = 'Deutschrap aktuell'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

COMMIT;

-- >>> 094_fair_passing.sql <<<
-- ============================================================
-- 094: Faires Weitergeben (Wunsch Mehdi, 2026-10-07, nach Fairness-Test)
-- ============================================================
-- Testlauf (db/scripts/test-fairness.mjs, 5 Matches, 78 Weitergaben) + Spielprotokoll echter Spieler:
--   * Menschen brauchen für eine richtige Antwort im Schnitt 5,6 s (in 4 s schaffen es nur 24 %,
--     in 6 s 54 %, in 7 s 71 %) – die Schutzzeit von min. 4 s war zu knapp.
--   * Ketten liefen endlos: im Blitz 25 Weitergaben hintereinander mit genau 4 s.
--   * Abgeben in letzter Sekunde wurde sogar belohnt (+10 Punkte pro "Clutch").
--   * Bots antworteten in 1,2–4 s, viel schneller als Menschen.
--
-- A) Schutzzeit: Blitz 6 s / Standard 7 s / Casual 8 s, jede weitere im selben Zug 1 s kürzer, nie unter 5 s.
-- B) Nachspielzeit: Sobald in einem Zug die Schutzzeit gegriffen hat (grace_count > 0), zählt bis zum
--    nächsten Knall nur noch der Songtitel – der Interpret reicht nicht mehr ('overtime_title_only',
--    ohne Fehlversuch-Sperre). So enden Ketten von selbst, für alle gleich.
-- C) Tempo-Bonus statt Clutch-Punkte: Wer innerhalb von 5 s abgibt (und nicht erst in den letzten 2 s
--    der Zündschnur), bekommt +5 Arena-Punkte (players.tempo_pass_count). Clutch zählt nur noch als
--    Statistik ("Rettungen in letzter Sekunde"), bringt keine Punkte mehr.
-- D) Bots menschlicher: Anfänger 4,5–7,5 s, Mittel 4–7 s (Profi bleibt schnell). In der Nachspielzeit
--    nennen Bots nur den Titel – und kennen ihn nicht immer (35/50/65 % je Stärke).
-- ============================================================
BEGIN;

-- ---------- A) Schutzzeit ----------
CREATE OR REPLACE FUNCTION public.calc_pass_grace_seconds(p_round_speed text, p_used int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(5,
    (CASE p_round_speed WHEN 'fast' THEN 6 WHEN 'calm' THEN 8 ELSE 7 END) - greatest(0, coalesce(p_used, 0))
  )::numeric;
$$;

-- ---------- C) Tempo-Abgaben zählen ----------
ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS tempo_pass_count int NOT NULL DEFAULT 0;

-- Wird pass_count für eine neue Runde/Revanche auf 0 gesetzt, Tempo-Abgaben mit zurücksetzen
-- (die vielen Reset-Funktionen müssen dafür nicht einzeln angefasst werden).
CREATE OR REPLACE FUNCTION public._trg_reset_tempo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF coalesce(NEW.pass_count, 0) = 0 THEN
    NEW.tempo_pass_count := 0;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS players_reset_tempo ON public.players;
CREATE TRIGGER players_reset_tempo BEFORE UPDATE ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_reset_tempo();

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int; v_tempo int := 0;
  v_quality numeric; v_diff numeric; v_combo_bonus numeric;
  v_speed text; v_grace_count int; v_grace numeric; v_new_explode timestamptz; v_grace_applied numeric := 0;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number,
         coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at),
         coalesce(l.last_pass_quality, 1), coalesce(l.last_pass_diff, 1), coalesce(l.last_pass_combo_bonus, 0),
         coalesce(l.round_speed, 'normal'), coalesce(l.grace_count, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number,
         v_bonus_used, v_since, v_quality, v_diff, v_combo_bonus,
         v_speed, v_grace_count
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
    -- Original: Richtung kann durch den Rache-Pass gedreht sein.
    if coalesce(v_dir, 1) >= 0 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  v_bonus_cap := public.calc_pass_bonus_cap(n);
  -- Basis (Runde) x Antwortqualität (Titel 1 / Interpret 0.5) x Song-
  -- Schwierigkeit + Combo-Bonus; im Duell (2 Lebende) gar keine Bonuszeit.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality * v_diff + v_combo_bonus;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  v_new_explode := greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second');

  -- Schutzzeit: der Empfänger hat immer mindestens v_grace Sekunden (091, Werte 094)
  v_grace := public.calc_pass_grace_seconds(v_speed, v_grace_count);
  if v_new_explode < v_now + (v_grace * interval '1 second') then
    v_new_explode := v_now + (v_grace * interval '1 second');
    v_grace_applied := v_grace;
  end if;

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = v_new_explode,
      round_bonus_used = v_bonus_used + v_bonus_applied,
      grace_count = v_grace_count + case when v_grace_applied > 0 then 1 else 0 end,
      last_grace_sec = v_grace_applied,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  -- Tempo-Abgabe (094): schnell weitergegeben, nicht erst kurz vor dem Knall
  if v_pass_ms <= 5000 and v_clutch = 0 then v_tempo := 1; end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch,
      tempo_pass_count = coalesce(tempo_pass_count, 0) + v_tempo
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

-- ---------- B) Nachspielzeit: nur der Titel zählt ----------
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_plays int; v_hits int;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
  v_diff numeric := 1;
  v_combo int := 0;
  v_combo_bonus numeric := 0;
  v_is_bot boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at, combo, coalesce(is_bot, false) into v_last_wrong, v_combo, v_is_bot
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist, plays, hits into v_song_title, v_song_artist, v_plays, v_hits
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      -- Nachspielzeit (094): der Interpret ist richtig, reicht aber nicht -> kein Fehlversuch, nur Hinweis
      if coalesce(v_lobby.grace_count, 0) > 0 then
        raise exception 'overtime_title_only';
      end if;
      v_points := 0.5;
      v_known := true;
    end if;


    if not v_known then
      update public.players set last_wrong_guess_at = now(), combo = 0
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    v_quality := v_points;
    v_diff := case public._song_difficulty(v_plays, v_hits) when 1 then 0.8 when 3 then 1.3 else 1.0 end;

    if v_points = 1 then
      v_combo := coalesce(v_combo, 0) + 1;
      v_combo_bonus := case when v_combo >= 2 then least(2, 0.5 * (v_combo - 1)) else 0 end;
      if not coalesce(v_is_bot, false) then
        update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
      end if;
    else
      v_combo := 0;
    end if;

    update public.players
    set song_points = song_points + v_points, combo = v_combo
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality,
      last_pass_diff = v_diff, last_pass_combo_bonus = v_combo_bonus
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ---------- D) Bots menschlicher + Nachspielzeit ----------
CREATE OR REPLACE FUNCTION public._bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_delay numeric;
  v_roll numeric;
  v_answer text;
  v_seed text;
  v_artist_chance numeric;
  v_base numeric; v_span numeric;
begin
  -- ---------- Themen-Voting ----------
  for r in
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at, l.topic_vote_cards
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % greatest(1, least(3, r.topic_vote_cards))))
      on conflict (lobby_id, player_id) do nothing;
    end if;
  end loop;

  -- ---------- Laufende Runde: Bot ist Halter ----------
  for r in
    select l.id, l.code, l.holder_player_id, l.holder_since, l.round_number, l.current_song_id,
           l.topic_selected, l.used_answers, l.explode_at, coalesce(l.grace_count, 0) as grace_count,
           coalesce(p.bot_skill, 2) as skill
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    -- Reaktionszeit je Stärke (094: Anfänger/Mittel so langsam wie echte Spieler, Ø Mensch 5,6 s)
    if r.skill = 1 then v_base := 4.5; v_span := 3.0;
    elsif r.skill = 3 then v_base := 0.8; v_span := 1.2;
    else v_base := 4.0; v_span := 3.0; end if;

    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := v_base + (abs(hashtext(v_seed)) % 1000) / 1000.0 * v_span;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number, r.skill) then continue; end if;

    v_answer := null;
    if r.current_song_id is not null then
      if r.grace_count > 0 then
        -- Nachspielzeit: nur der Titel zählt – den kennt der Bot nicht immer
        if (abs(hashtext('t' || v_seed)) % 1000) / 1000.0 >= (case r.skill when 1 then 0.35 when 3 then 0.65 else 0.50 end) then
          continue;
        end if;
        select title into v_answer from public.song_pool where id = r.current_song_id;
      else
        -- Migration 092: meist den Künstler (½ Punkt), seltener den Titel
        v_artist_chance := case r.skill when 1 then 0.80 when 3 then 0.70 else 0.75 end;
        if (abs(hashtext('a' || v_seed)) % 1000) / 1000.0 < v_artist_chance then
          select trim(split_part(split_part(artist, ',', 1), '&', 1)) into v_answer from public.song_pool where id = r.current_song_id;
        end if;
        if v_answer is null or length(v_answer) = 0 then
          select title into v_answer from public.song_pool where id = r.current_song_id;
        end if;
      end if;
    else
      select ta.answer into v_answer
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(coalesce(r.topic_selected, ''))
        and not (ta.lower_answer = any (select lower(u) from unnest(r.used_answers) u))
      order by random() limit 1;
      v_answer := coalesce(v_answer, 'Keine Ahnung');
    end if;

    if v_answer is not null then
      begin
        perform public.rpc_attempt_pass(r.code, r.holder_player_id, v_answer);
      exception when others then
        null;
      end;
    end if;
  end loop;
end;
$function$;

-- ---------- C) Punkte: Tempo-Abgaben x 5 statt Clutch x 10 ----------
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  v_ranked boolean := public._lobby_human_count(p_lobby_id) >= 2;
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.tempo * 5,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.tempo_pass_count, 0) as tempo,
           coalesce(p.is_bot, false) as is_bot
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler und nur, wenn mind. 2 Menschen mitspielen (075).
  if v_ranked then
    for r in
      select p.user_id, sr.arena_points, sr.place
      from public.series_results sr
      join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
      where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
    loop
      insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
      values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
      on conflict (user_id, season) do update
        set arena_points = public.season_points.arena_points + excluded.arena_points,
            sets_played = public.season_points.sets_played + 1,
            set_wins = public.season_points.set_wins + excluded.set_wins,
            updated_at = now();
    end loop;
  end if;

  -- Konto-Verlauf (076). Darf das Rundenende niemals blockieren.
  begin
    perform public._record_round_history(p_lobby_id);
  exception when others then
    raise warning 'record_round_history: %', sqlerrm;
  end;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    if v_ranked then
      begin
        perform public.aggregate_player_stats(p_lobby_id);
      exception when others then
        null;
      end;
    end if;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

COMMIT;

-- >>> 095_ohne_kollegah.sql <<<
-- ============================================================
-- 095: Kollegah raus aus "Deutschrap aktuell" (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Seine Klassiker gibt es bei iTunes nicht (keine Hörprobe), übrig waren nur Nebenwerke.
-- Die 5 Songs mit Kollegah gehen ins Archiv (nicht gelöscht: Spielprotokoll/Statistik bleiben gültig).
-- Auch aus db/scripts/data/deutschrap-rapper.json entfernt, damit ein neuer Bau ihn nicht zurückholt.
-- ============================================================
BEGIN;

UPDATE public.song_pool s
SET archived_from = 'Deutschrap aktuell',
    topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)')
WHERE s.topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Deutschrap aktuell')
  AND s.artist ILIKE '%kollegah%';

COMMIT;
