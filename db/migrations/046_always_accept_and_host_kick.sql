-- ============================================================
-- Migration 046: Antworten immer akzeptieren + Host-Live-Kick
-- ============================================================
-- 1) rpc_attempt_pass akzeptiert ab jetzt JEDE getippte Antwort sofort
--    (kein Titel/Interpret-Abgleich, kein Mehrheits-Voting mehr nötig).
--    Die Spieler entscheiden manuell/sozial, wer rausfliegt -- dafür
--    gibt es Punkt 2.
-- 2) Neue RPC rpc_host_kick_during_round: der Host kann während einer
--    laufenden Runde jederzeit einen Spieler sofort eliminieren (kein
--    Bestätigungsdialog im Client nötig). Ist der Gekickte gerade der
--    Halter, rückt automatisch der nächste lebende Spieler nach --
--    exakt wie beim normalen Rundenverlust in rpc_tick_game.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  -- Jede Antwort wird sofort angenommen -- keine Titel/Interpret- oder
  -- Kategorie-Prüfung mehr. Die Spieler entscheiden danach manuell
  -- (Host-Kick), wer eigentlich hätte rausfliegen müssen.
  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_host_kick_during_round(
    p_code TEXT, p_host_player_id UUID, p_target_player_id UUID
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_was_holder boolean;
  v_alive_count int;
  v_next_holder uuid;
  v_round_duration interval;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_host_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.host_player_id is distinct from p_host_player_id then raise exception 'not_host'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if p_target_player_id = p_host_player_id then raise exception 'cannot_kick_self'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_target_player_id
      and status = 'active' and is_alive = true
  ) then raise exception 'target_not_active'; end if;

  v_was_holder := (v_lobby.holder_player_id = p_target_player_id);

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  -- Ein offener Versuch des Gekickten verfällt kommentarlos.
  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = v_lobby.id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target_player_id,
      last_activity_at = now()
  where id = v_lobby.id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby.id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby.id;
    return;
  end if;

  if not v_was_holder then
    -- Halter bleibt unverändert, nur der Kandidatenkreis schrumpft.
    return;
  end if;

  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby.id and p_loser.player_id = p_target_player_id
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_lobby.game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby.id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_lobby.round_speed, 'normal'),
    v_alive_count,
    coalesce(v_lobby.round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = now() + v_round_duration,
      round_bonus_used = 0
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;

COMMIT;
