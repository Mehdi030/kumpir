-- ============================================================
-- KUMPIR — Alle Migrationen in einem File
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
-- 009_balance_and_fair_timer.sql
-- ============================================================
-- ============================================================
-- Migration 009: Balance-Fixes — Fair Timer + Modi + Round-Speed
-- ============================================================
-- Drei zusammenhängende Bug-Fixes für ein faires Spielerlebnis:
--
-- 1) FAIR-TIMER: Nach einem Pass hat der nächste Halter MINDESTENS 1.5s
--    bevor die Bombe explodieren kann. Vorher konnte man die Kartoffel
--    300ms vor Ablauf weiterreichen — der nächste war praktisch tot.
--
-- 2) MODI BALANCE: rpc_pass_potato hat Teleport JEDEN Pass ausgelöst
--    und Reverse JEDEN Pass die Richtung geflippt. Das ist Chaos statt
--    Strategie. Jetzt: Teleport mit 30% Chance, Reverse mit 25%.
--
-- 3) ROUND-SPEED: rpc_tick_game hatte explode_at hartcoded auf 15s,
--    rpc_advance_from_countdown auf 25s. Beide ignorierten die
--    round_speed Einstellung. Jetzt: calc_explode_seconds() wird genutzt,
--    abhängig von round_speed + alive_count + round_number.
-- ============================================================

BEGIN;

-- ============================================================
-- rpc_pass_potato — fair timer + balanced modes
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_lobby_id    uuid;
  v_mode        text;
  v_holder      uuid;
  v_dir         smallint;
  v_explode_at  timestamptz;

  alive_ids     uuid[];
  n             int;
  idx           int;
  next_idx      int;
  v_next        uuid;

  v_now         timestamptz := now();
  v_last_pass   timestamptz;
  v_pass_ms     int;
  v_clutch      int := 0;
  v_ms_left     int;

  -- Fair-Timer: nächster Halter bekommt mindestens 1.5s
  v_min_hold    interval := interval '1.5 seconds';

  -- Mode-Trigger-Wahrscheinlichkeiten
  v_teleport_chance numeric := 0.30;
  v_reverse_chance  numeric := 0.25;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
  from public.lobbies l
  where l.code = upper(p_code)
  for update;

  if v_lobby_id is null then
    raise exception 'Lobby not found';
  end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id  = v_lobby_id
      and p.player_id = p_player_id
      and p.status    = 'active'
      and p.is_alive  = true
  ) then
    raise exception 'Player not active/alive';
  end if;

  select array_agg(p.player_id order by p.seat_index)
    into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id
    and p.status   = 'active'
    and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- ============================================================
  -- Mode-Logik mit Wahrscheinlichkeiten (statt jeden Pass)
  -- ============================================================
  if v_mode = 'teleport' and random() < v_teleport_chance then
    -- Teleport: zufälliger lebender Spieler (nicht der aktuelle Halter)
    select p.player_id into v_next
    from public.players p
    where p.lobby_id  = v_lobby_id
      and p.status    = 'active'
      and p.is_alive  = true
      and p.player_id <> p_player_id
    order by random()
    limit 1;

    if v_next is null then
      -- Fallback: linear
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
      v_next := alive_ids[next_idx];
    end if;

  elsif v_mode = 'reverse' and random() < v_reverse_chance then
    -- Reverse: Richtung flippen UND einen Step in die neue Richtung
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
    -- Default: linear in aktueller Richtung
    -- (Reverse-Modus ohne Flip: aktuelle Richtung beibehalten)
    if v_mode = 'reverse' then
      if coalesce(v_dir, 1) = 1 then
        next_idx := idx + 1;
        if next_idx > n then next_idx := 1; end if;
      else
        next_idx := idx - 1;
        if next_idx < 1 then next_idx := n; end if;
      end if;
    else
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  -- ============================================================
  -- FAIR-TIMER: nächster Halter bekommt min. 1.5s
  -- ============================================================
  update public.lobbies
  set holder_player_id = v_next,
      explode_at       = greatest(v_explode_at, v_now + v_min_hold),
      last_activity_at = v_now
  where id = v_lobby_id;

  -- ============================================================
  -- Stats für den vorigen Halter
  -- ============================================================
  select last_pass_at into v_last_pass
  from public.players
  where lobby_id  = v_lobby_id
    and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms
    from public.lobbies
    where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  -- Clutch wenn weniger als 2 Sek übrig waren
  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then
      v_clutch := 1;
    end if;
  end if;

  update public.players
  set
    pass_count        = coalesce(pass_count, 0) + 1,
    last_pass_at      = v_now,
    total_hold_ms     = coalesce(total_hold_ms, 0) + v_pass_ms,
    fastest_pass_ms   = case
                          when fastest_pass_ms is null then v_pass_ms
                          when v_pass_ms < fastest_pass_ms then v_pass_ms
                          else fastest_pass_ms
                        end,
    clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id  = v_lobby_id
    and player_id = p_player_id;

end;
$function$;


-- ============================================================
-- rpc_tick_game — nutze calc_explode_seconds für faire nächste Runde
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_now         timestamptz := now();

  v_lobby_id    uuid;
  v_phase       text;
  v_holder      uuid;
  v_explode_at  timestamptz;
  v_game_mode   text;
  v_round_speed text;
  v_round_num   int;

  v_alive_count int;
  v_loser       uuid;
  v_next_holder uuid;
  v_next_seconds numeric;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, round_number
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_round_num
  from public.lobbies
  where code = upper(p_code)
  for update;

  if v_lobby_id is null then
    raise exception 'Lobby not found';
  end if;

  if v_phase is distinct from 'running' then
    return;
  end if;

  if v_explode_at is null then
    return;
  end if;

  if v_now < v_explode_at then
    return;
  end if;

  v_loser := v_holder;
  if v_loser is null then
    return;
  end if;

  -- Loser eliminieren
  update public.players
  set is_alive        = false,
      survival_streak = 0
  where lobby_id  = v_lobby_id
    and player_id = v_loser;

  -- Streak für alle noch lebenden erhöhen
  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id
    and status   = 'active'
    and is_alive = true;

  -- Runde hochzählen + Loser merken
  update public.lobbies
  set round_number         = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at     = v_now,
      used_answers         = '{}'  -- neue Runde, Antworten reset
  where id = v_lobby_id;

  -- Alive-Count
  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id
    and status   = 'active'
    and is_alive = true;

  -- Letzter überlebender → finished
  if v_alive_count <= 1 then
    update public.lobbies
    set phase            = 'finished',
        explode_at       = null,
        holder_player_id = (
          select player_id
          from public.players
          where lobby_id = v_lobby_id
            and status   = 'active'
            and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster Holder: bei Teleport zufällig, sonst nächster seat_index
  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id
      and status   = 'active'
      and is_alive = true
      and player_id <> v_loser
    order by random()
    limit 1;
  else
    -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
    select p2.player_id
      into v_next_holder
    from public.players p_loser
    join public.players p2
      on  p2.lobby_id   = p_loser.lobby_id
      and p2.status     = 'active'
      and p2.is_alive   = true
      and p2.seat_index > p_loser.seat_index
    where p_loser.lobby_id  = v_lobby_id
      and p_loser.player_id = v_loser
    order by p2.seat_index asc
    limit 1;

    -- Wrap: falls keiner mit höherem seat_index alive ist
    if v_next_holder is null then
      select player_id
        into v_next_holder
      from public.players
      where lobby_id = v_lobby_id
        and status   = 'active'
        and is_alive = true
      order by seat_index asc
      limit 1;
    end if;
  end if;

  -- Nächste explode_at: calc_explode_seconds basierend auf round_speed +
  -- alive_count + round_number — NICHT mehr hartcoded 15s.
  v_next_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_num, 0) + 1,
    1.9,
    0.5,
    3
  );

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at       = v_now + make_interval(secs => v_next_seconds),
      pass_direction   = case
                           when v_game_mode = 'reverse' and random() < 0.40
                           then (pass_direction * -1)::smallint
                           else pass_direction
                         end,
      current_attempt_id = null  -- attempt aus alter Runde aufräumen
  where id = v_lobby_id;

end;
$function$;


-- ============================================================
-- rpc_advance_from_countdown — nutze calc_explode_seconds
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_round_speed text;
  v_alive_count int;
  v_seconds numeric;
begin
  select round_speed
    into v_round_speed
  from public.lobbies
  where id = p_lobby_id;

  select player_id
    into v_holder
  from public.players
  where lobby_id = p_lobby_id
    and status = 'active'
    and is_alive = true
  order by random()
  limit 1;

  if v_holder is null then
    raise exception 'Kein Startspieler gefunden';
  end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id
    and status = 'active'
    and is_alive = true;

  v_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    1,
    1.9,
    0.5,
    3
  );

  update public.lobbies
  set
    phase = 'running',
    holder_player_id = v_holder,
    run_started_at = now(),
    explode_at = now() + make_interval(secs => v_seconds),
    countdown_started_at = null,
    countdown_ends_at = null,
    last_activity_at = now(),
    used_answers = '{}',
    current_attempt_id = null
  where id = p_lobby_id
    and phase = 'countdown';
end;
$function$;


-- ============================================================
-- View: public_lobbies_view — Anzeige im Hauptmenü
-- ============================================================
-- Nur wartende Public-Lobbies mit grundlegenden Infos.
CREATE OR REPLACE VIEW public.public_lobbies_view AS
SELECT
    l.code,
    l.max_players,
    l.game_mode,
    l.round_speed,
    l.created_at,
    (
        SELECT COUNT(*)
        FROM public.players p
        WHERE p.lobby_id = l.id AND p.status = 'active'
    ) AS player_count
FROM public.lobbies l
WHERE l.privacy = 'public'
  AND l.phase IN ('waiting', 'lobby')
  AND l.locked = FALSE
  AND l.last_activity_at > NOW() - INTERVAL '30 minutes'
ORDER BY l.created_at DESC
LIMIT 20;

GRANT SELECT ON public.public_lobbies_view TO anon, authenticated;


COMMIT;


-- ============================================================
-- 010_warning_mechanic.sql
-- ============================================================
-- ============================================================
-- Migration 010: Schnelles Spiel — Ermahnungs-Mechanik statt Voting
-- ============================================================
-- Neue Gameplay-Idee:
--   - Halter sagt Antwort MÜNDLICH, klickt Pass → Kartoffel geht SOFORT weiter
--   - Andere können für ~5 Sek danach „⚠️ Ermahnen" klicken falls Antwort Mist war
--   - Ermahnungen akkumulieren pro Spieler (sichtbar als Counter)
--   - Bei Spielende: Top-Mogler-Stats
--
-- Was sich ändert:
--   - rpc_pass_potato erweitert um pass_counter Inkrement + last_pass_target
--   - Neue Tabelle pass_warnings (1 Warning pro warner + pass_counter)
--   - Neue RPC rpc_warn_player
--   - Neue Spalte players.warnings_received für UI-Counter
--
-- Die Topic-B-Voting-Tabellen aus Migration 001 (pass_attempts +
-- pass_attempt_votes) bleiben in der DB stehen — werden vom neuen Frontend
-- aber nicht mehr genutzt. Können später für andere Modi wiederverwendet werden.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Neue Spalten in lobbies + players
-- ------------------------------------------------------------
ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS pass_counter INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS last_pass_target_id UUID;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS last_pass_at TIMESTAMPTZ;

ALTER TABLE public.players
    ADD COLUMN IF NOT EXISTS warnings_received INTEGER NOT NULL DEFAULT 0;


-- ------------------------------------------------------------
-- Tabelle: pass_warnings
-- ------------------------------------------------------------
-- 1 Warning pro warner + pass_counter (sonst kann jemand spammen).
CREATE TABLE IF NOT EXISTS public.pass_warnings (
    lobby_id            UUID NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
    pass_counter        INTEGER NOT NULL,
    target_player_id    UUID NOT NULL,
    warner_player_id    UUID NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (lobby_id, pass_counter, warner_player_id)
);

CREATE INDEX IF NOT EXISTS idx_pass_warnings_target
    ON public.pass_warnings (lobby_id, target_player_id);


-- ------------------------------------------------------------
-- rpc_pass_potato — erweitert mit pass_counter + last_pass_target
-- Fair-Timer (1.5s) bleibt, Modi-Balance bleibt.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_lobby_id    uuid;
  v_mode        text;
  v_holder      uuid;
  v_dir         smallint;
  v_explode_at  timestamptz;

  alive_ids     uuid[];
  n             int;
  idx           int;
  next_idx      int;
  v_next        uuid;

  v_now         timestamptz := now();
  v_last_pass   timestamptz;
  v_pass_ms     int;
  v_clutch      int := 0;
  v_ms_left     int;

  v_min_hold    interval := interval '1.5 seconds';
  v_teleport_chance numeric := 0.30;
  v_reverse_chance  numeric := 0.25;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
  from public.lobbies l
  where l.code = upper(p_code)
  for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;
  if v_holder is null or v_holder <> p_player_id then raise exception 'Not holder'; end if;
  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index)
    into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- Mode-Logik
  if v_mode = 'teleport' and random() < v_teleport_chance then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id and p.status = 'active'
      and p.is_alive = true and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then
      next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
      v_next := alive_ids[next_idx];
    end if;
  elsif v_mode = 'reverse' and random() < v_reverse_chance then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1; if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  else
    if v_mode = 'reverse' then
      if coalesce(v_dir, 1) = 1 then
        next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
      else
        next_idx := idx - 1; if next_idx < 1 then next_idx := n; end if;
      end if;
    else
      next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  -- Lobby aktualisieren + Pass-Counter inkrementieren
  update public.lobbies
  set holder_player_id      = v_next,
      explode_at            = greatest(v_explode_at, v_now + v_min_hold),
      last_activity_at      = v_now,
      pass_counter          = coalesce(pass_counter, 0) + 1,
      last_pass_target_id   = p_player_id,
      last_pass_at          = v_now
  where id = v_lobby_id;

  -- Stats für vorigen Halter
  select last_pass_at into v_last_pass
  from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms
    from public.lobbies where id = v_lobby_id;
  end if;
  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set
    pass_count        = coalesce(pass_count, 0) + 1,
    last_pass_at      = v_now,
    total_hold_ms     = coalesce(total_hold_ms, 0) + v_pass_ms,
    fastest_pass_ms   = case
                          when fastest_pass_ms is null then v_pass_ms
                          when v_pass_ms < fastest_pass_ms then v_pass_ms
                          else fastest_pass_ms
                        end,
    clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;


-- ------------------------------------------------------------
-- rpc_warn_player — andere geben Ermahnung ab
-- Window: 5 Sekunden nach dem letzten Pass.
-- Validierung: warner != target, warner ist active+alive, target = last_pass_target.
-- Idempotent: PRIMARY KEY verhindert Doppel-Warnings.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_warn_player(
    p_code TEXT,
    p_warner_player_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_lobby_id           UUID;
    v_pass_counter       INTEGER;
    v_last_pass_target   UUID;
    v_last_pass_at       TIMESTAMPTZ;
    v_window             INTERVAL := INTERVAL '5 seconds';
BEGIN
    SELECT id, pass_counter, last_pass_target_id, last_pass_at
      INTO v_lobby_id, v_pass_counter, v_last_pass_target, v_last_pass_at
    FROM public.lobbies
    WHERE code = UPPER(p_code);

    IF v_lobby_id IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
    IF v_last_pass_target IS NULL OR v_last_pass_at IS NULL THEN
        RAISE EXCEPTION 'no_recent_pass';
    END IF;

    -- Time-Window: nur innerhalb 5s nach letztem Pass
    IF NOW() > v_last_pass_at + v_window THEN
        RAISE EXCEPTION 'warning_window_expired';
    END IF;

    -- warner darf sich nicht selbst ermahnen
    IF v_last_pass_target = p_warner_player_id THEN
        RAISE EXCEPTION 'cannot_warn_self';
    END IF;

    -- warner muss aktiv + lebendig sein
    IF NOT EXISTS (
        SELECT 1 FROM public.players
        WHERE lobby_id = v_lobby_id
          AND player_id = p_warner_player_id
          AND status = 'active'
          AND is_alive = TRUE
    ) THEN
        RAISE EXCEPTION 'warner_not_active';
    END IF;

    -- Warning einfügen (idempotent über PK)
    INSERT INTO public.pass_warnings (lobby_id, pass_counter, target_player_id, warner_player_id)
    VALUES (v_lobby_id, v_pass_counter, v_last_pass_target, p_warner_player_id)
    ON CONFLICT (lobby_id, pass_counter, warner_player_id) DO NOTHING;

    -- Counter beim Target hochzählen (nur wenn neuer insert)
    IF FOUND THEN
        UPDATE public.players
        SET warnings_received = COALESCE(warnings_received, 0) + 1
        WHERE lobby_id = v_lobby_id
          AND player_id = v_last_pass_target;
    END IF;
END;
$$;


-- ------------------------------------------------------------
-- RLS für pass_warnings
-- ------------------------------------------------------------
ALTER TABLE public.pass_warnings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pass_warnings_read_all" ON public.pass_warnings;
CREATE POLICY "pass_warnings_read_all" ON public.pass_warnings FOR SELECT USING (TRUE);


-- ------------------------------------------------------------
-- Pass-Counter bei Rundenwechsel resetten (im rpc_tick_game)
-- ------------------------------------------------------------
-- rpc_tick_game bekommt zusätzlich das Reset für pass_counter + last_pass_*
-- am Anfang einer neuen Runde, damit Warnings nicht über Runden zählen
-- als „aktuelles Warn-Fenster".
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_now         timestamptz := now();
  v_lobby_id    uuid;
  v_phase       text;
  v_holder      uuid;
  v_explode_at  timestamptz;
  v_game_mode   text;
  v_round_speed text;
  v_round_num   int;
  v_alive_count int;
  v_loser       uuid;
  v_next_holder uuid;
  v_next_seconds numeric;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, round_number
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_round_num
  from public.lobbies
  where code = upper(p_code)
  for update;

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
  set round_number         = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at     = v_now,
      used_answers         = '{}'
  where id = v_lobby_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase            = 'finished',
        explode_at       = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active'
      and is_alive = true and player_id <> v_loser
    order by random() limit 1;
  else
    select p2.player_id into v_next_holder
    from public.players p_loser
    join public.players p2 on p2.lobby_id = p_loser.lobby_id
      and p2.status = 'active' and p2.is_alive = true
      and p2.seat_index > p_loser.seat_index
    where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
    order by p2.seat_index asc limit 1;

    if v_next_holder is null then
      select player_id into v_next_holder from public.players
      where lobby_id = v_lobby_id and status = 'active' and is_alive = true
      order by seat_index asc limit 1;
    end if;
  end if;

  v_next_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'), v_alive_count,
    coalesce(v_round_num, 0) + 1, 1.9, 0.5, 3
  );

  update public.lobbies
  set holder_player_id     = v_next_holder,
      explode_at           = v_now + make_interval(secs => v_next_seconds),
      pass_direction       = case
                               when v_game_mode = 'reverse' and random() < 0.40
                               then (pass_direction * -1)::smallint
                               else pass_direction
                             end,
      current_attempt_id   = null,
      -- Pass-Counter reset für neue Runde (Warnings über Rundengrenze hinaus blocken)
      pass_counter         = 0,
      last_pass_target_id  = null,
      last_pass_at         = null
  where id = v_lobby_id;
end;
$function$;


COMMIT;

