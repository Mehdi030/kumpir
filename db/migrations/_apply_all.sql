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
