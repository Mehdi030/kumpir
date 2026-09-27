-- ============================================================
-- Migration 018: Timeout für hängende Pass-Versuche
-- ============================================================
-- Live-Simulation (BALANCE_REPORT.md, Fund #2): rpc_vote_answer
-- verlangt bei genau 2 verbleibenden Wählern (v_alive = 2, also 3
-- lebende Spieler insgesamt) Einstimmigkeit -- es gab aber KEINEN
-- Timeout. Ein einzelner Spieler, der nicht (oder gegensätzlich)
-- abstimmt, konnte einen pass_attempt für immer auf 'pending' halten.
-- Der zugehörige Freeze-Bug (rpc_tick_game wurde nur vom Browser des
-- aktuellen Halters ausgelöst) ist bereits gefixt -- die Runde endet
-- also inzwischen zuverlässig durch Explosion. Damit ein ehrlich
-- antwortender Halter aber überhaupt eine faire Chance hat, statt
-- durch einen einzelnen Non-Voter/Ablehner automatisch zu verlieren,
-- wird ein hängender Versuch nach 8 Sekunden aufgelöst:
--   - Mehrheit der bis dahin abgegebenen Stimmen entscheidet
--   - Bei Gleichstand (inkl. 0:0, niemand hat abgestimmt) -> im
--     Zweifel für den Halter (angenommen), damit ein einzelner
--     AFK/Troll-Spieler nicht jeden Pass permanent blockieren kann
--
-- Aufrufbar von jedem verbundenen Client (siehe game/[code]/page.tsx),
-- analog zum bereits bestehenden Muster für topic_vote/countdown.
-- Idempotent: wirkt nur auf status='pending' UND älter als 8s.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_resolve_stale_attempt(p_attempt_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_attempt public.pass_attempts%ROWTYPE;
begin
  select * into v_attempt from public.pass_attempts where id = p_attempt_id for update;
  if not found then return; end if;
  if v_attempt.status <> 'pending' then return; end if;
  if v_attempt.created_at > now() - interval '8 seconds' then return; end if;

  if v_attempt.accept_count >= v_attempt.reject_count then
    perform public._finalize_attempt_accept(v_attempt.id);
  else
    perform public._finalize_attempt_reject(v_attempt.id);
  end if;
end;
$function$;

COMMIT;
