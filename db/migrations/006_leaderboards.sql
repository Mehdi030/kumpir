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
