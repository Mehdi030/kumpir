-- ============================================================
-- Migration 065: Saison-Bestenliste (Monats-Saison)
-- ============================================================
-- season_points wird seit Migration 062 bei jedem Durchgang für
-- eingeloggte Spieler gefüllt (Arena-Punkte, gespielte Durchgänge,
-- Durchgangs-Siege). Diese View liefert die Rangliste pro Saison
-- (Saison = Kalendermonat, 'YYYY-MM') inkl. Benutzername.
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW public.season_leaderboard_view
  WITH (security_invoker = true) AS
SELECT sp.season, sp.user_id, pr.username, sp.arena_points, sp.sets_played, sp.set_wins,
       rank() OVER (PARTITION BY sp.season ORDER BY sp.arena_points DESC, sp.set_wins DESC) AS rank
FROM public.season_points sp
JOIN public.profiles pr ON pr.id = sp.user_id
WHERE pr.username IS NOT NULL;

GRANT SELECT ON public.season_leaderboard_view TO anon, authenticated;

COMMIT;
