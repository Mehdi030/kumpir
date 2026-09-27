-- ============================================================
-- Migration 010: used_answers wird nie zurückgesetzt
-- ============================================================
-- lobbies.used_answers (Anti-Doppelnennung, siehe Migration 001)
-- sammelte sich über Runden und Rematches hinweg an, weil weder
-- rpc_advance_from_countdown (Rundenstart) noch rpc_rematch das Feld
-- je geleert haben -- Migration 001 hat das per Kommentar sogar
-- explizit als offenes TODO markiert.
--
-- Fix: current_attempt_id + used_answers werden jetzt geleert in:
--   - rpc_advance_from_countdown (jeder neue Rundenstart, inkl. Rematch)
--   - rpc_rematch (zur Sicherheit zusätzlich, falls irgendwo direkt
--     wieder in 'running' gesprungen werden sollte)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_holder uuid;
begin
  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + interval '25 seconds',
      countdown_started_at = null,
      countdown_ends_at = null,
      used_answers = '{}',
      current_attempt_id = null,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = false, is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;
