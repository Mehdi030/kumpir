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
