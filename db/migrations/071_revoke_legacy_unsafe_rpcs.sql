-- ============================================================
-- Migration 071: unsichere Alt-RPCs für Clients sperren
-- ============================================================
-- Gefunden bei der Spiel-Simulation: mehrere SECURITY-DEFINER-Funktionen waren für
-- anon/authenticated aufrufbar, OHNE die Session des Aufrufers zu prüfen. Wer eine
-- player_id kannte (die ist öffentlich lesbar), konnte damit u. a.
--   * die Kumpir für den Halter weitergeben, ohne den Song zu erraten (rpc_pass_potato),
--   * beliebige Spieler eliminieren / kicken / aus der Lobby werfen,
--   * das Spiel für den Host starten oder fremde "bereit"-Haken setzen.
-- Der Client nutzt nur die session-geprüften Varianten (rpc_attempt_pass, rpc_leave_lobby,
-- rpc_begin_topic_vote, rpc_toggle_ready, kick_player mit p_me_player_id ...). Die Alt-Funktionen
-- werden intern teils noch von anderen SECURITY-DEFINER-Funktionen genutzt (z. B. rpc_pass_potato
-- aus der Antwort-Prüfung) -- das bleibt erlaubt, nur der direkte Client-Zugriff entfällt.
-- ============================================================

DO $$
declare r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (
        (p.proname = 'rpc_pass_potato')
        or (p.proname = 'rpc_eliminate_player')
        or (p.proname = 'kick_player' and pg_get_function_identity_arguments(p.oid) = 'p_lobby_id uuid, p_target_player_id uuid')
        or (p.proname = 'leave_lobby')
        or (p.proname = 'rpc_restart_game')
        or (p.proname = 'rpc_start_game')
        or (p.proname = 'start_game')
        or (p.proname = 'set_ready')
        or (p.proname = 'rpc_ready_up')
      )
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon, authenticated', r.proname, r.args);
    raise notice 'gesperrt: %(%)', r.proname, r.args;
  end loop;
end $$;
