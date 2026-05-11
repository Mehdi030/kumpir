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
CREATE POLICY "pass_attempts_read_all" ON public.pass_attempts FOR SELECT USING (TRUE);

ALTER TABLE public.pass_attempt_votes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pass_attempt_votes_read_all" ON public.pass_attempt_votes FOR SELECT USING (TRUE);


COMMIT;
