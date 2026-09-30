-- ============================================================
-- Migration 056: KRITISCHER Sicherheits-Fix -- session_token versehentlich
-- wieder lesbar gemacht
-- ============================================================
-- Migration 055 hat aus Versehen `GRANT SELECT ON public.players TO anon,
-- authenticated;` OHNE Spaltenliste ausgeführt (wollte nur song_points
-- freigeben) -- das hebt die Spalten-Allowlist aus Migration 023 komplett
-- auf und macht session_token wieder für JEDEN lesbar. Live geprüft und
-- bestätigt: session_token hatte danach SELECT für anon.
--
-- Das ist der exakte Exploit, den Migration 023 ursprünglich geschlossen
-- hat (Identitäts-Spoofing: fremde Antworten einreichen, Vote-Stuffing,
-- Ready-Status fremder Spieler umschalten). Sofort zurückgesetzt auf die
-- Allowlist aus Migration 049 + song_points.
-- ============================================================

BEGIN;

REVOKE SELECT ON public.players FROM anon, authenticated;
GRANT SELECT (
    id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id,
    seat_index, is_alive, kicked_at, is_online, status, left_at, last_pass_at,
    survival_streak, pass_count, clutch_pass_count, fastest_pass_ms,
    slowest_pass_ms, eliminated_at_round, song_points,
    total_hold_ms, is_bot
) ON public.players TO anon, authenticated;

COMMIT;
