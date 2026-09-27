-- ============================================================
-- Migration 019: rpc_reset_lobby + rpc_rematch abgesichert
-- ============================================================
-- Beim Vollständigkeits-Audit gefunden (schwerwiegender als die
-- bekannte Player-Impersonation-Problematik, weil hier nicht einmal
-- eine Spieler-ID nötig war): rpc_reset_lobby(p_code) und
-- rpc_rematch(p_code) nahmen NUR den 4-stelligen Lobby-Code entgegen
-- -- keinerlei Prüfung, ob der Aufrufer überhaupt Mitglied dieser
-- Lobby ist, geschweige denn in welcher Phase sie gerade ist. Der Code
-- steht im Join-Link, den man mit jedem teilt -- jeder, der ihn je
-- gesehen hat (auch nach dem Verlassen), konnte damit JEDE laufende
-- Partie jederzeit zurücksetzen oder in den Rematch zwingen.
--
-- Fix: beide verlangen jetzt zusätzlich p_player_id und prüfen, dass
-- diese Person aktiv Mitglied der Lobby ist (nicht nur Host --
-- "Zurück zur Lobby" und "Rematch" sind im UI bewusst für alle
-- Spieler verfügbar, nicht nur den Host). Zusätzlich: beide wirken
-- nur noch aus phase='finished' -- vorher ließ sich damit auch eine
-- laufende Partie mitten im Spiel abwürgen.
--
-- rpc_start_rematch_if_ready bleibt unverändert: sie prüft die
-- Ready-Zahlen server-seitig und ist ohne echte Mehrheit ein No-Op,
-- also schon von sich aus ungefährlich für Fremdaufrufe.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.rpc_reset_lobby(text);
DROP FUNCTION IF EXISTS public.rpc_rematch(text);

CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code TEXT, p_player_id UUID)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
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
