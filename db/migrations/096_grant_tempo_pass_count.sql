-- ============================================================
-- 096: Fix "permission denied for table players" (2026-10-07)
-- ============================================================
-- Migration 094 hat players.tempo_pass_count angelegt, aber nicht freigegeben. players wird über eine
-- Spalten-Freigabeliste gelesen (Migration 080) -> die Spielseite, die die Spalte abfragt, lud nicht mehr
-- und keine Runde ließ sich starten. Neue Spalten brauchen IMMER ein GRANT SELECT (spalte).
-- ============================================================
GRANT SELECT (tempo_pass_count) ON public.players TO anon, authenticated;
