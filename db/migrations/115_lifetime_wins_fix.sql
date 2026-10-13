-- ============================================================
-- 115: Lebenszeit-Siege zählen jede gewonnene Runde (Fund aus dem Gesamttest 2026-10-13)
-- ============================================================
-- Vorher: aggregate_player_stats nahm den "aktuellen Halter, wenn er lebt" als Sieger. Bei Zwischenrunden eines
-- Matches war das der Ausgeschiedene -> Lebenszeit-Siege (Bestenliste "Rundensiege", Erfolge Erstgeborener,
-- Gewinner-Typ, Champion, Legende) zählten nur die LETZTE Runde jedes Matches. Beispiel: medo 26 gewonnene Runden,
-- Bestenliste zeigte 7. Jetzt: Sieger = Platz 1 der Runde (gilt auch für Quiz-Modi und Teams).
-- Bereits gespielte Runden werden hier NICHT nachgerechnet (Nachrechnen nur auf Wunsch).
BEGIN;

CREATE OR REPLACE FUNCTION public.aggregate_player_stats(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_winner_user_id UUID;
BEGIN
    -- Sieger = Platz 1 der gerade beendeten Runde (series_results). 115: vorher "aktueller Halter, wenn am Leben" –
    -- das war bei Zwischenrunden der Verlierer (Lebenszeit-Siege zählten nur die letzte Runde eines Matches) und
    -- hätte in den Quiz-Modi (alle leben) einen Zufallsspieler gewertet.
    SELECT p.user_id INTO v_winner_user_id
    FROM public.lobbies l
    JOIN public.series_results sr ON sr.lobby_id = l.id AND sr.set_index = l.series_index AND sr.place = 1
    JOIN public.players p ON p.lobby_id = sr.lobby_id AND p.player_id = sr.player_id
    WHERE l.id = p_lobby_id
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
$function$;

COMMIT;
