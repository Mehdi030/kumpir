-- ============================================================
-- Migration 003: Teleport + Reverse Modi
-- ============================================================
-- Stellt Helper-Funktionen bereit, die aus rpc_pass_potato heraus
-- aufgerufen werden können, um je nach game_mode den nächsten Halter
-- zu bestimmen.
--
-- ⚠️ WICHTIG: rpc_pass_potato in deiner DB muss angepasst werden!
-- Ersetze die "nächster Spieler im Ring"-Logik durch:
--
--   v_next := public.calc_next_holder(
--               p_lobby_id := v_lobby.id,
--               p_current_holder := v_lobby.holder_player_id,
--               p_mode := v_lobby.game_mode
--             );
--
-- Beispiel-Patch siehe unten.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Spalte: lobbies.pass_direction
-- ------------------------------------------------------------
-- Bei Reverse-Modus: aktuelle Richtung im Ring (+1 oder -1).
-- Default +1, kann während des Spiels umkippen.
ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS pass_direction SMALLINT NOT NULL DEFAULT 1;


-- ------------------------------------------------------------
-- Helper: nächsten Halter berechnen (mode-aware)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calc_next_holder(
    p_lobby_id UUID,
    p_current_holder UUID,
    p_mode TEXT
) RETURNS UUID
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_alive_ids     UUID[];
    v_current_idx   INTEGER;
    v_direction     SMALLINT;
    v_next_idx      INTEGER;
    v_aliveN        INTEGER;
BEGIN
    -- Alle lebenden Spieler in seat_index-Reihenfolge
    SELECT array_agg(player_id ORDER BY seat_index)
        INTO v_alive_ids
        FROM public.players
        WHERE lobby_id = p_lobby_id
          AND status = 'active'
          AND is_alive = TRUE;

    v_aliveN := COALESCE(array_length(v_alive_ids, 1), 0);

    IF v_aliveN <= 1 THEN
        RETURN NULL;
    END IF;

    -- TELEPORT: zufälliger lebender Spieler (außer Halter)
    IF p_mode = 'teleport' THEN
        RETURN (
            SELECT player_id
            FROM public.players
            WHERE lobby_id = p_lobby_id
              AND status = 'active'
              AND is_alive = TRUE
              AND player_id <> p_current_holder
            ORDER BY random()
            LIMIT 1
        );
    END IF;

    -- Index des aktuellen Halters im alive-Array finden
    v_current_idx := array_position(v_alive_ids, p_current_holder);
    IF v_current_idx IS NULL THEN
        -- Halter nicht mehr alive — wähle den ersten
        RETURN v_alive_ids[1];
    END IF;

    -- REVERSE: aktuelle Richtung lesen, mit kleiner Chance flippen
    IF p_mode = 'reverse' THEN
        SELECT pass_direction INTO v_direction
            FROM public.lobbies WHERE id = p_lobby_id;

        -- 18% Chance: Richtung flippen
        IF random() < 0.18 THEN
            v_direction := -v_direction;
            UPDATE public.lobbies SET pass_direction = v_direction WHERE id = p_lobby_id;
        END IF;
    ELSE
        v_direction := 1;
    END IF;

    -- next-index mit Wrap-Around
    v_next_idx := ((v_current_idx - 1 + v_direction) % v_aliveN + v_aliveN) % v_aliveN + 1;

    RETURN v_alive_ids[v_next_idx];
END;
$$;


-- ============================================================
-- BEISPIEL: Wie du rpc_pass_potato anpasst
-- ============================================================
-- Eingebaut in dein existierendes rpc_pass_potato, vor dem Update von
-- lobbies.holder_player_id:
--
-- v_next := public.calc_next_holder(
--   p_lobby_id := v_lobby.id,
--   p_current_holder := v_lobby.holder_player_id,
--   p_mode := COALESCE(v_lobby.game_mode, 'original')
-- );
--
-- IF v_next IS NULL THEN
--   -- Spiel zu Ende (nur 1 Spieler übrig)
--   ... finished-logic ...
-- ELSE
--   UPDATE public.lobbies
--     SET holder_player_id = v_next,
--         explode_at = NOW() + (calculate_explode_seconds(...) || ' seconds')::interval
--     WHERE id = v_lobby.id;
-- END IF;
-- ============================================================


-- ------------------------------------------------------------
-- Wenn eine neue Runde startet (rpc_advance_from_countdown), Direction reset
-- ------------------------------------------------------------
-- Dein rpc_advance_from_countdown sollte auch setzen:
--   UPDATE lobbies SET pass_direction = 1 WHERE id = p_lobby_id;
-- (Vermeidet dass Reverse-State aus vorheriger Runde übrig bleibt.)


COMMIT;
