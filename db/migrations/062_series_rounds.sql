-- ============================================================
-- Migration 062: Serien -- mehrere Durchgänge pro Match + Zwischenstand
-- ============================================================
-- Der Host wählt beim Erstellen, wie viele Durchgänge gespielt werden
-- (1 / 3 / 5). Jeder Durchgang läuft wie bisher bis nur noch EIN Spieler
-- übrig ist. Danach:
--   - die Platzierungen + Arena-Punkte des Durchgangs werden in
--     series_results gespeichert,
--   - ist es nicht der letzte Durchgang -> Phase 'set_summary' (Zwischen-
--     stand, 12s), danach automatisch neues Themen-Voting (rpc_start_next_set),
--   - ist es der letzte -> 'finished' mit Gesamtwertung.
-- Arena-Punkte pro Durchgang (identisch zur Client-Anzeige):
--   Platzierung (1. = 100 ... Letzter = 0, linear) + Song-Punkte x 15 + Clutch x 10
-- Zusätzlich: Saison-Punkte (Monat) für eingeloggte Spieler.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_total int NOT NULL DEFAULT 1;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_index int NOT NULL DEFAULT 1;

-- Neue Phase 'set_summary' (Zwischenstand) im Check-Constraint zulassen.
ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_phase_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_phase_check CHECK (phase = ANY (ARRAY['waiting','lobby','topic_vote','countdown','running','finished','rematch_wait','set_summary']));
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.series_results (
  id bigserial PRIMARY KEY,
  lobby_id uuid NOT NULL,
  set_index int NOT NULL,
  player_id uuid NOT NULL,
  name text NOT NULL,
  place int NOT NULL,
  arena_points int NOT NULL,
  song_points numeric NOT NULL DEFAULT 0,
  rounds_survived int NOT NULL DEFAULT 0,
  passes int NOT NULL DEFAULT 0,
  clutch int NOT NULL DEFAULT 0,
  is_bot boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lobby_id, set_index, player_id)
);
CREATE INDEX IF NOT EXISTS series_results_lobby_idx ON public.series_results (lobby_id, set_index);
ALTER TABLE public.series_results ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS series_results_read ON public.series_results;
CREATE POLICY series_results_read ON public.series_results FOR SELECT USING (true);
GRANT SELECT ON public.series_results TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.season_points (
  user_id uuid NOT NULL,
  season text NOT NULL,
  arena_points int NOT NULL DEFAULT 0,
  sets_played int NOT NULL DEFAULT 0,
  set_wins int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, season)
);
ALTER TABLE public.season_points ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS season_points_read ON public.season_points;
CREATE POLICY season_points_read ON public.season_points FOR SELECT USING (true);
GRANT SELECT ON public.season_points TO anon, authenticated;

-- Neue Serie (Rematch / zurück in die Lobby) beginnt wieder bei Durchgang 1.
CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_reset_series ON public.lobbies;
CREATE TRIGGER lobbies_reset_series
  BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._reset_series_on_phase();

-- Host stellt die Anzahl Durchgänge ein (nur in der Wartelobby).
CREATE OR REPLACE FUNCTION public.set_lobby_series(p_lobby_id uuid, p_me_player_id uuid, p_total int)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_phase text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then raise exception 'invalid_session'; end if;
  select host_player_id, phase into v_host, v_phase from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  if v_phase not in ('waiting', 'finished') then raise exception 'lobby_not_waiting'; end if;
  if p_total not in (1, 3, 5) then raise exception 'invalid_series_total'; end if;
  update public.lobbies
  set series_total = p_total, settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

-- ------------------------------------------------------------
-- Durchgang abschließen: Ergebnisse speichern, dann Zwischenstand
-- oder Serienende.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.clutch * 10,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.is_bot, false) as is_bot
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler.
  for r in
    select p.user_id, sr.arena_points, sr.place
    from public.series_results sr
    join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
    where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
  loop
    insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
    values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
    on conflict (user_id, season) do update
      set arena_points = public.season_points.arena_points + excluded.arena_points,
          sets_played = public.season_points.sets_played + 1,
          set_wins = public.season_points.set_wins + excluded.set_wins,
          updated_at = now();
  end loop;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    begin
      perform public.aggregate_player_stats(p_lobby_id);
    exception when others then
      null;
    end;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public._finish_round(uuid) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Nächster Durchgang: Spieler zurücksetzen, neues Themen-Voting.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_start_next_set(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_phase text; v_filter text[]; v_prev text; v_ends timestamptz;
  v_topic_a text; v_topic_b text; v_topic_c text;
begin
  select id, phase, topic_filter, topic_selected, countdown_ends_at
    into v_lobby_id, v_phase, v_filter, v_prev, v_ends
  from public.lobbies where code = upper(trim(p_code)) for update;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'set_summary' then return; end if;
  if v_ends is not null and v_ends > now() + interval '1 second' then return; end if;

  -- Neues Thema bevorzugt NICHT dasselbe wie im letzten Durchgang.
  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter)) and t.text is distinct from v_prev
  order by random() limit 1;
  if v_topic_a is null then
    select t.text into v_topic_a from public.topic_pool t
    where t.active is true and (v_filter is null or t.text = any(v_filter)) order by random() limit 1;
  end if;
  if v_topic_a is null then raise exception 'Nicht genug Themen im topic_pool'; end if;

  select t.text into v_topic_b from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;
  if v_topic_b is null then
    v_topic_b := v_topic_a;
  else
    select t.text into v_topic_c from public.topic_pool t
    where t.active is true and t.text <> v_topic_a and t.text <> v_topic_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      series_index = series_index + 1,
      round_number = 1, pass_direction = 1,
      topic_a = v_topic_a, topic_b = v_topic_b, topic_c = v_topic_c, topic_selected = null,
      topic_vote_started_at = now(), topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_loser_player_id = null, current_attempt_id = null, used_answers = '{}',
      last_activity_at = now()
  where id = v_lobby_id and phase = 'set_summary';
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_start_next_set(text) TO anon, authenticated;

-- ------------------------------------------------------------
-- Matchende läuft jetzt über _finish_round (Tick + Host-Kick)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  if v_now < v_explode_at then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0
  where lobby_id = v_lobby_id and player_id = v_loser;

  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  update public.lobbies
  set round_number = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at = v_now
  where id = v_lobby_id
  returning round_number into v_round_number;

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby_id and player_id = v_loser;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    perform public._finish_round(v_lobby_id);
    return;
  end if;

  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true and player_id != v_loser
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = v_now + v_round_duration,
      round_bonus_used = 0,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
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
  v_round_number int;
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

  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = v_lobby.id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target_player_id,
      round_number = coalesce(round_number, 0) + 1,
      last_activity_at = now()
  where id = v_lobby.id
  returning round_number into v_round_number;

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby.id and player_id = p_target_player_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    perform public._finish_round(v_lobby.id);
    return;
  end if;

  if not v_was_holder then
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
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = now() + v_round_duration,
      round_bonus_used = 0
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;

-- ------------------------------------------------------------
-- Server-Ticker kennt den Zwischenstand
-- ------------------------------------------------------------
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
       or (phase in ('rematch_wait', 'set_summary') and countdown_ends_at is not null and countdown_ends_at <= now())
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
      elsif r.phase = 'set_summary' then
        perform public.rpc_start_next_set(r.code);
      end if;
    exception when others then
      null;
    end;
  end loop;
end;
$function$;

COMMIT;
