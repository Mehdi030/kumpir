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
