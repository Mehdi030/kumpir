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
