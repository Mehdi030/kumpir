-- ============================================================
-- Migration 028: Themen-Countdown springt auf 5s wenn alle (Menschen) gewählt haben
-- ============================================================
-- Bots zählen bewusst NICHT mit -- ihre Wahl ist ohnehin zufällig
-- (useBotEngine.ts) und soll das Verkürzen nicht blockieren, falls ein
-- Bot noch seine 800-2400ms Zufallsverzögerung vor sich hat.
--
-- Wichtig: verkürzt nur EINMAL (wenn die verbleibende Zeit noch > 5s
-- ist). Würde man topic_vote_ends_at bei jedem Aufruf neu auf "jetzt +
-- 5s" setzen, würde der Countdown nie unter 5s fallen, solange die
-- Funktion weiter aufgerufen wird (z.B. durch Polling) -- das wäre ein
-- eingebauter Endlos-Countdown-Bug. Sobald die Restzeit <= 5s ist, tut
-- der Aufruf nichts mehr; die Uhr läuft normal weiter runter.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_maybe_shorten_topic_vote(p_lobby_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_phase text;
  v_ends_at timestamptz;
  v_voters_needed int;
  v_voters_have int;
begin
  select phase, topic_vote_ends_at into v_phase, v_ends_at
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'topic_vote' then return; end if;
  if v_ends_at is null then return; end if;
  if v_ends_at <= now() + interval '5 seconds' then return; end if;

  select count(*) into v_voters_needed
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and coalesce(is_bot, false) = false;

  if v_voters_needed = 0 then return; end if;

  select count(distinct tv.player_id) into v_voters_have
  from public.topic_votes tv
  join public.players p on p.lobby_id = p_lobby_id and p.player_id = tv.player_id
  where tv.lobby_id = p_lobby_id and p.status = 'active' and coalesce(p.is_bot, false) = false;

  if v_voters_have >= v_voters_needed then
    update public.lobbies
    set topic_vote_ends_at = now() + interval '5 seconds'
    where id = p_lobby_id;
  end if;
end;
$function$;

COMMIT;
