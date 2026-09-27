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
