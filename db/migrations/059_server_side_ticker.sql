-- ============================================================
-- Migration 059: Server-seitiger Ticker (pg_cron) -- Match friert nicht mehr ein
-- ============================================================
-- Bisher trieb AUSSCHLIESSLICH die Browser-Seite der Spieler die Phasen
-- an (setInterval ruft rpc_tick_game / rpc_finalize_topic_vote /
-- rpc_advance_from_countdown / rpc_start_rematch_if_ready auf). Sobald ALLE
-- Tabs im Hintergrund waren (Alt-Tab zu Discord, Handy gesperrt, Fenster
-- minimiert), drosselt der Browser die Timer -- die Runde blieb
-- stehen, der überfällige Halter explodierte erst, wenn jemand wieder hinsah
-- (im Multi-Bot-Checkup live reproduziert: explode_at 13s überfällig,
-- nichts passierte).
--
-- Jetzt prüft zusätzlich ein pg_cron-Job alle 2 Sekunden alle Lobbys und ruft
-- die ohnehin idempotenten RPCs bei überfälligen Timern selbst auf. Die
-- Client-Ticks bleiben als schnellere Primärquelle bestehen (die RPCs sind
-- phasengeschützt, doppelte Aufrufe sind harmlos).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._server_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select id, code, phase from public.lobbies
    where (phase = 'running' and explode_at is not null and explode_at <= now())
       or (phase = 'topic_vote' and topic_vote_ends_at is not null and topic_vote_ends_at <= now())
       or (phase = 'countdown' and countdown_ends_at is not null and countdown_ends_at <= now())
       or (phase = 'rematch_wait' and countdown_ends_at is not null and countdown_ends_at <= now())
  loop
    begin
      if r.phase = 'running' then
        perform public.rpc_tick_game(r.code);
      elsif r.phase = 'topic_vote' then
        perform public.rpc_finalize_topic_vote(r.id);
      elsif r.phase = 'countdown' then
        perform public.rpc_advance_from_countdown(r.id);
      elsif r.phase = 'rematch_wait' then
        perform public.rpc_start_rematch_if_ready(r.code);
      end if;
    exception when others then
      -- Eine kaputte Lobby (z.B. nur 1 Spieler im Rematch) darf den
      -- Ticker für alle anderen nicht blockieren.
      null;
    end;
  end loop;
end;
$function$;

REVOKE ALL ON FUNCTION public._server_tick() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kumpir-server-tick';
SELECT cron.schedule('kumpir-server-tick', '2 seconds', 'select public._server_tick()');

COMMIT;
