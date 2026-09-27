-- ============================================================
-- Migration 013: Tote Legacy-Strukturen aufräumen
-- ============================================================
-- Geprüft per Grep über apps/web/src UND über alle db/-Dateien
-- (functions.sql + migrations 001-012), bevor irgendetwas gelöscht
-- wird:
--
--   - public.lobby_players: taucht NUR in der eigenen CREATE TABLE
--     Zeile in schema.sql auf. Kein Frontend-Query, keine RPC, kein
--     Trigger nutzt sie. Ersetzt durch public.players seit jeher.
--     -> sicher zum Löschen.
--
--   - public.topics: wurde nur von der ALTEN Version von
--     rpc_start_rematch_if_ready genutzt (Bug, siehe Kommentar in
--     Migration 003). Migration 003 hat die Funktion bereits auf
--     topic_pool umgestellt; seitdem referenziert keine einzige
--     Funktion mehr public.topics. Migration 003 hat das Löschen
--     bereits als sicheren Schritt dokumentiert.
--     -> sicher zum Löschen.
--
--   - public.game_state: taucht NUR in der eigenen CREATE TABLE Zeile
--     in schema.sql auf. Die aktiven Felder (phase, holder_player_id,
--     explode_at, round_number) leben stattdessen alle in
--     public.lobbies. Kein Frontend-Query, keine RPC referenziert sie.
--     -> sicher zum Löschen.
--
-- NICHT gelöscht (bewusste Entscheidung, siehe Auftrag "bei
-- Unsicherheit lieber stehen lassen"):
--
--   Die in db/functions.sql (Zeilen 930-951) als Legacy dokumentierten
--   Funktionen (begin_round, boom, pass_potato x2, start_game x3,
--   start_lobby, start_round, start_game_by_code, leave_lobby x2,
--   kick_player(p_lobby_id, p_target_player_id), end_lobby, reset_lobby,
--   sowie die Trigger/Helper-Liste darunter) sind in KEINER Datei in
--   db/ mit vollständiger Signatur definiert -- sie existieren
--   offenbar nur (noch) live in Supabase aus einer älteren Iteration,
--   wurden aber nie in dieses Repo gedumpt. Postgres braucht für
--   DROP FUNCTION die exakte Parameter-Signatur; ohne sie riskiert ein
--   blindes DROP entweder einen Fehler oder (schlimmer, falls mehrere
--   Overloads existieren) das Löschen der falschen Variante.
--
--   Vor einem echten Cleanup bitte im Supabase SQL-Editor ausführen
--   und die exakten Signaturen einsammeln:
--
--     SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
--     FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace
--     WHERE n.nspname = 'public'
--       AND p.proname IN (
--         'begin_round','boom','pass_potato','start_game','start_lobby',
--         'start_round','start_game_by_code','leave_lobby','end_lobby',
--         'reset_lobby','rls_auto_enable','set_lobby_timestamps','set_ready',
--         'set_updated_at','tg_set_updated_at','touch_lobby_activity_by_code',
--         'trg_clear_lobby_on_player_leave','trg_reconcile_after_exit',
--         'trg_reconcile_on_player_change','cleanup_lobby_if_empty',
--         'end_lobby_if_host_left','reconcile_lobby_after_exit',
--         'rpc_reconcile_lobby','rpc_eliminate_player','rpc_clear_lobby_to_waiting',
--         'rpc_restart_game','rpc_ready_up','rpc_rematch_1v1','rpc_reset_lobby',
--         'rpc_schedule_next_explosion','cleanup_expired_lobbies'
--       );
--
--   ACHTUNG: rpc_reset_lobby steht in dieser Altlast-Liste, ist aber
--   seit Migration 009 eine ECHTE, aktiv genutzte Funktion -- die
--   obige Abfrage würde also (falls in Supabase noch eine alte Version
--   mit anderer Signatur existierte) einen Konflikt aufdecken, den man
--   vor dem nächsten Deploy manuell prüfen sollte.
-- ============================================================

BEGIN;

DROP TABLE IF EXISTS public.lobby_players;
DROP TABLE IF EXISTS public.topics;
DROP TABLE IF EXISTS public.game_state;

COMMIT;
