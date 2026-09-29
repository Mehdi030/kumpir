-- ============================================================
-- Migration 049: Column-Grant für slowest_pass_ms + eliminated_at_round
-- ============================================================
-- Migration 023 grantet anon/authenticated SELECT nur auf eine explizite
-- Spalten-Allowlist (alles außer dem geheimen session_token). Die 2
-- neuen Spalten aus 047/048 (slowest_pass_ms, eliminated_at_round)
-- standen da noch nicht drin -- das Frontend bekam beim Laden von
-- players() sofort "permission denied for table players" (live im
-- Browser reproduziert). Gleiche Liste wie 023, nur um die 2 neuen
-- Spalten ergänzt.
-- ============================================================

BEGIN;

REVOKE SELECT ON public.players FROM anon, authenticated;
GRANT SELECT (
    id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id,
    seat_index, is_alive, kicked_at, is_online, status, left_at, last_pass_at,
    survival_streak, pass_count, clutch_pass_count, fastest_pass_ms,
    slowest_pass_ms, eliminated_at_round,
    total_hold_ms, is_bot
) ON public.players TO anon, authenticated;

COMMIT;
