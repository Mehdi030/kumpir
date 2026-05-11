-- ============================================================
-- KUMPIR — RPC-Funktionen (REKONSTRUIERT als Signaturen)
-- ============================================================
-- Diese Datei zeigt nur, WELCHE RPCs aus dem Frontend aufgerufen werden,
-- und welche Parameter sie bekommen. Die echten Implementierungen liegen
-- in deiner Supabase-DB — bitte mit `supabase db dump` exportieren und
-- die einzelnen Funktionen hier in separate .sql Dateien aufteilen.
-- ============================================================


-- ============================================================
-- Lobby-Management
-- ============================================================

-- Erstellt eine neue Lobby (gen 4-stelliger Code, legt Host an).
-- Returns: TABLE(code TEXT, host_player_id UUID)
CREATE OR REPLACE FUNCTION public.rpc_create_lobby(
    p_host_name TEXT,
    p_privacy TEXT,
    p_max_players SMALLINT,
    p_round_seconds SMALLINT
) RETURNS TABLE(code TEXT, host_player_id UUID)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    -- TODO: Implementation hier aus deinem echten Schema einfügen
    RAISE EXCEPTION 'rpc_create_lobby not yet implemented in reconstructed schema';
END;
$$;


-- Tritt einer Lobby bei (idempotent: gleicher player_id darf mehrfach kommen).
CREATE OR REPLACE FUNCTION public.rpc_join_lobby(
    p_code TEXT,
    p_player_id UUID,
    p_name TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    RAISE EXCEPTION 'rpc_join_lobby not yet implemented in reconstructed schema';
END;
$$;


-- Legacy: ältere Variante von rpc_join_lobby. Kann entfernt werden, wenn keiner mehr anruft.
CREATE OR REPLACE FUNCTION public.join_lobby(
    p_lobby_code TEXT,
    p_name TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    RAISE EXCEPTION 'join_lobby (legacy) not yet implemented in reconstructed schema';
END;
$$;


-- ============================================================
-- Gameplay
-- ============================================================

-- Spieler markiert sich als bereit / nicht bereit.
CREATE OR REPLACE FUNCTION public.rpc_toggle_ready(
    p_lobby_id UUID,
    p_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Host startet das Spiel → Lobby geht in phase = 'topic_vote',
-- topic_a/topic_b werden zufällig aus questions_de gewählt,
-- topic_vote_ends_at = NOW() + 15s.
CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(
    p_lobby_id UUID,
    p_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Spieler stimmt ab (1=topic_a, 2=topic_b, 3=random).
CREATE OR REPLACE FUNCTION public.rpc_vote_topic(
    p_lobby_id UUID,
    p_player_id UUID,
    p_choice SMALLINT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Wertet das Voting aus → setzt topic_selected, geht in phase = 'countdown'.
-- Bei Gleichstand: topic_tie_choices + topic_tie_pick füllen.
CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(
    p_lobby_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Countdown abgelaufen → phase = 'running', holder_player_id = zufälliger Spieler,
-- explode_at = NOW() + calculateExplodeSeconds().
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(
    p_lobby_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Game-Tick: prüft ob explode_at erreicht → eliminiert holder, geht in nächste Runde
-- oder phase = 'finished' wenn nur noch 1 Spieler übrig.
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Kartoffel weitergeben: holder_player_id → nächster Alive im Ring,
-- pass_count++, last_pass_at = NOW(), ggf. clutch_pass_count++ wenn nahe explode_at.
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(
    p_code TEXT,
    p_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Rematch: gleiche Lobby + gleiche Spieler, alles auf Anfang.
CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Lobby auf Anfang zurück (alle Stats reset, phase = 'lobby').
CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- ============================================================
-- Maintenance / Liveness
-- ============================================================

-- Markiert Spieler als "noch online" (alle 8s vom Client).
CREATE OR REPLACE FUNCTION public.rpc_heartbeat(
    p_lobby_id UUID,
    p_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Räumt Lobby auf: Spieler ohne Heartbeat seit p_stale_seconds → status = 'left'.
-- Wird vom Host-Client alle 15s aufgerufen.
CREATE OR REPLACE FUNCTION public.cleanup_lobby(
    p_lobby_id UUID,
    p_stale_seconds INTEGER
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- ============================================================
-- Host-Aktionen (Admin Panel)
-- ============================================================

-- Spieler aus Lobby kicken (nur Host darf).
CREATE OR REPLACE FUNCTION public.kick_player(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_target_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Lobby sperren / öffnen.
CREATE OR REPLACE FUNCTION public.set_lobby_lock(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_locked BOOLEAN
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Host-Rolle übertragen.
CREATE OR REPLACE FUNCTION public.transfer_host(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_new_host_player_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- Settings ändern.
CREATE OR REPLACE FUNCTION public.set_max_players(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_max_players SMALLINT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


CREATE OR REPLACE FUNCTION public.set_lobby_mode(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_mode TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


CREATE OR REPLACE FUNCTION public.set_lobby_topic(
    p_lobby_id UUID,
    p_me_player_id UUID,
    p_topic TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
AS $$ BEGIN RAISE EXCEPTION 'not implemented'; END; $$;


-- ============================================================
-- Profiles / Auth
-- ============================================================

-- Username-Verfügbarkeit prüfen.
CREATE OR REPLACE FUNCTION public.is_username_available(p_username TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE LOWER(username) = LOWER(p_username)
    );
END;
$$;
