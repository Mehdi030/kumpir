-- ============================================================
-- 113: Modus "Teams" (Wunsch Mehdi 2026-10-13)
-- ============================================================
-- Beim Start werden die (gemischten) Plätze abwechselnd Team Rot (0) und Team Blau (1) zugeteilt.
-- Die Kartoffel geht immer an den nächsten Lebenden aus dem anderen Team (_next_alive).
-- Die Runde endet, sobald nur noch ein Team Spieler im Spiel hat – das Verliererteam landet hinten.
BEGIN;

CREATE OR REPLACE FUNCTION public._next_alive(p_lobby_id uuid, p_from uuid, p_dir integer)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v_seat int; v_next uuid; v_team smallint; v_teams boolean;
begin
  select seat_index, team into v_seat, v_team from public.players where lobby_id = p_lobby_id and player_id = p_from;
  -- 113: Teams – die Kartoffel geht immer an den nächsten aus dem ANDEREN Team
  select game_mode = 'teams' into v_teams from public.lobbies where id = p_lobby_id;
  if coalesce(v_teams, false) and v_team is not null then
    if coalesce(p_dir, 1) >= 0 then
      select player_id into v_next from public.players
      where lobby_id = p_lobby_id and status = 'active' and is_alive = true and team is distinct from v_team
      order by (seat_index <= v_seat), seat_index asc limit 1;
    else
      select player_id into v_next from public.players
      where lobby_id = p_lobby_id and status = 'active' and is_alive = true and team is distinct from v_team
      order by (seat_index >= v_seat), seat_index desc limit 1;
    end if;
    if v_next is not null then return v_next; end if;
  end if;
  if coalesce(p_dir, 1) >= 0 then
    select player_id into v_next from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true and seat_index > v_seat
    order by seat_index asc limit 1;
    if v_next is null then
      select player_id into v_next from public.players
      where lobby_id = p_lobby_id and status = 'active' and is_alive = true
      order by seat_index asc limit 1;
    end if;
  else
    select player_id into v_next from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true and seat_index < v_seat
    order by seat_index desc limit 1;
    if v_next is null then
      select player_id into v_next from public.players
      where lobby_id = p_lobby_id and status = 'active' and is_alive = true
      order by seat_index desc limit 1;
    end if;
  end if;
  return v_next;
end;
$function$;

-- 113: Teams – Runde vorbei, sobald nur noch ein Team lebt
CREATE OR REPLACE FUNCTION public._teams_decided(p_lobby_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT l.game_mode = 'teams' AND (
    SELECT count(DISTINCT p.team) FROM public.players p
    WHERE p.lobby_id = l.id AND p.status = 'active' AND p.is_alive AND p.team IS NOT NULL) <= 1
  FROM public.lobbies l WHERE l.id = p_lobby_id
$$;
REVOKE EXECUTE ON FUNCTION public._teams_decided(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int; v_dir int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, pass_direction
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_dir
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  -- 098: Antworten, die kurz vor Schluss abgeschickt wurden, haben 0,4 s Zeit anzukommen
  if v_now < v_explode_at + interval '400 milliseconds' then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0, combo = 0
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

  if v_alive_count <= 1 or public._teams_decided(v_lobby_id) then
    perform public._finish_round(v_lobby_id);
    return;
  end if;

  v_next_holder := public._next_alive(v_lobby_id, v_loser, case when v_game_mode = 'original' then v_dir else 1 end);

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
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public._remove_from_round(p_lobby_id uuid, p_target uuid, p_force_alive boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_was_alive boolean;
  v_was_holder boolean;
  v_alive int;
  v_next uuid;
  v_round int;
begin
  select * into v_lobby from public.lobbies where id = p_lobby_id for update;
  if not found or v_lobby.phase <> 'running' then return; end if;

  select is_alive into v_was_alive from public.players where lobby_id = p_lobby_id and player_id = p_target;
  v_was_alive := coalesce(v_was_alive, false) or p_force_alive;
  if not v_was_alive then return; end if;

  v_was_holder := (v_lobby.holder_player_id = p_target);

  update public.players
  set is_alive = false, survival_streak = 0, combo = 0
  where lobby_id = p_lobby_id and player_id = p_target;

  if v_lobby.current_attempt_id is not null and v_was_holder then
    update public.pass_attempts set status = 'rejected', decided_at = now()
    where id = v_lobby.current_attempt_id;
    update public.lobbies set current_attempt_id = null where id = p_lobby_id;
  end if;

  update public.lobbies
  set last_loser_player_id = p_target,
      round_number = coalesce(round_number, 0) + 1,
      last_activity_at = now()
  where id = p_lobby_id
  returning round_number into v_round;

  update public.players set eliminated_at_round = v_round
  where lobby_id = p_lobby_id and player_id = p_target;

  select count(*) into v_alive
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_alive <= 1 or public._teams_decided(p_lobby_id) then
    perform public._finish_round(p_lobby_id);
    return;
  end if;

  if not v_was_holder then return; end if;

  -- Nächster Halter: Richtung beachten (Rache-Pass), Teleport = zufällig
  if v_lobby.game_mode = 'teleport' then
    select player_id into v_next from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  else
    v_next := public._next_alive(p_lobby_id, p_target, case when v_lobby.game_mode = 'original' then coalesce(v_lobby.pass_direction, 1) else 1 end);
  end if;

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = now() + public.calc_explode_seconds(coalesce(v_lobby.round_speed, 'normal'), v_alive, coalesce(v_round, 1)) * interval '1 second',
      round_bonus_used = 0,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0
  where id = p_lobby_id;

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int; v_tempo int := 0;
  v_quality numeric; v_diff numeric; v_combo_bonus numeric;
  v_speed text; v_grace_count int; v_grace numeric; v_new_explode timestamptz; v_grace_applied numeric := 0;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number,
         coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at),
         coalesce(l.last_pass_quality, 1), coalesce(l.last_pass_diff, 1), coalesce(l.last_pass_combo_bonus, 0),
         coalesce(l.round_speed, 'normal'), coalesce(l.grace_count, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number,
         v_bonus_used, v_since, v_quality, v_diff, v_combo_bonus,
         v_speed, v_grace_count
  from public.lobbies l
  where l.code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index) into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  if v_mode = 'teleport' then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id
      and p.status = 'active' and p.is_alive = true
      and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then return; end if;

  elsif v_mode = 'reverse' then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];

  elsif v_mode = 'teams' then
    -- 113: immer an den Nächsten aus dem anderen Team
    v_next := public._next_alive(v_lobby_id, p_player_id, coalesce(v_dir, 1));

  else
    -- Original: Richtung kann durch den Rache-Pass gedreht sein.
    if coalesce(v_dir, 1) >= 0 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  v_bonus_cap := public.calc_pass_bonus_cap(n);
  -- Basis (Runde) x Antwortqualität (Titel 1 / Interpret 0.5) x Song-
  -- Schwierigkeit + Combo-Bonus; im Duell (2 Lebende) gar keine Bonuszeit.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality * v_diff + v_combo_bonus;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  v_new_explode := greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second');

  -- Schutzzeit: der Empfänger hat immer mindestens v_grace Sekunden (091, Werte 094)
  v_grace := public.calc_pass_grace_seconds(v_speed, v_grace_count);
  if v_new_explode < v_now + (v_grace * interval '1 second') then
    v_new_explode := v_now + (v_grace * interval '1 second');
    v_grace_applied := v_grace;
  end if;

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = v_new_explode,
      round_bonus_used = v_bonus_used + v_bonus_applied,
      grace_count = v_grace_count + case when v_grace_applied > 0 then 1 else 0 end,
      last_grace_sec = v_grace_applied,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  -- Tempo-Abgabe (094): schnell weitergegeben, nicht erst kurz vor dem Knall
  if v_pass_ms <= 5000 and v_clutch = 0 then v_tempo := 1; end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch,
      tempo_pass_count = coalesce(tempo_pass_count, 0) + v_tempo
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
  v_phase text;
begin
  select phase, round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_phase, v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'countdown' then return; end if;
  if coalesce(current_setting('request.headers', true), '') <> '' and exists (select 1 from public.lobbies where id = p_lobby_id and countdown_ends_at > now() + interval '1 second') then return; end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  -- Faire Weitergabe-Reihenfolge: Sitzplätze zufällig mischen.
  with act as (
    select player_id, seat_index as old_seat,
           row_number() over (order by seat_index) as rk
    from public.players
    where lobby_id = p_lobby_id and status = 'active'
  ), shuf as (
    select player_id, row_number() over (order by random()) as rk from act
  ), pick as (
    select s.player_id, a.old_seat
    from shuf s join act a on a.rk = s.rk
  )
  update public.players p set seat_index = -(pick.old_seat + 1)
  from pick where p.lobby_id = p_lobby_id and p.player_id = pick.player_id;

  update public.players set seat_index = -seat_index - 1
  where lobby_id = p_lobby_id and status = 'active' and seat_index < 0;

  update public.players set skips_left = 1
  where lobby_id = p_lobby_id and status = 'active';

  -- 113: Teams – nach dem Mischen abwechselnd Team 0 (Rot) und 1 (Blau), sonst kein Team
  with t as (
    select player_id, (row_number() over (order by seat_index) - 1) % 2 as tm
    from public.players where lobby_id = p_lobby_id and status = 'active'
  )
  update public.players p
     set team = case when (select game_mode from public.lobbies where id = p_lobby_id) = 'teams' then t.tm::smallint else null end
    from t where p.lobby_id = p_lobby_id and p.player_id = t.player_id;

  -- Quiz-Modi (108): alle raten gleichzeitig, keine Kartoffel
  if public._is_quiz_mode((select game_mode from public.lobbies where id = p_lobby_id)) then
    perform public._quiz_begin(p_lobby_id);
    return;
  end if;

  v_explode_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    greatest(1, v_alive_count),
    greatest(1, v_round_number)
  );

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + (v_explode_seconds * interval '1 second'),
      countdown_started_at = null,
      countdown_ends_at = null,
      countdown_starter_player_id = null,
      used_answers = '{}',
      -- Migration 092: gespielte Songs nur beim ersten Durchgang eines Matches leeren
      used_song_ids = case when coalesce(series_index, 1) <= 1 then '{}' else coalesce(used_song_ids, '{}') end,
      current_attempt_id = null,
      round_bonus_used = 0,
      last_pass_quality = 1,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- Endstand: Siegerteam zuerst
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int; v_win_team smallint;
  v_season text := to_char(now(), 'YYYY-MM');
  v_ranked boolean := public._lobby_human_count(p_lobby_id) >= 2;
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  -- 113: Teams – das ganze Siegerteam kommt vor das Verliererteam
  if (select game_mode from public.lobbies where id = p_lobby_id) = 'teams' then
    select team into v_win_team from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true and team is not null limit 1;
  end if;

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot, fastest_ms, slowest_ms)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * (case when public._is_quiz_mode((select game_mode from public.lobbies where id = p_lobby_id)) then 5 else 15 end))::int + t.tempo * 5,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot, t.fastest_ms, t.slowest_ms
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when v_win_team is not null and p.team = v_win_team then 1 else 0 end) desc,
                      (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.tempo_pass_count, 0) as tempo,
           coalesce(p.is_bot, false) as is_bot,
           p.fastest_pass_ms as fastest_ms,
           p.slowest_pass_ms::int as slowest_ms
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler und nur, wenn mind. 2 Menschen mitspielen (075).
  if v_ranked then
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
  end if;

  -- Konto-Verlauf (076). Darf das Rundenende niemals blockieren.
  begin
    perform public._record_round_history(p_lobby_id);
  exception when others then
    raise warning 'record_round_history: %', sqlerrm;
  end;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    if v_ranked then
      begin
        perform public.aggregate_player_stats(p_lobby_id);
      exception when others then
        null;
      end;
    end if;

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

COMMIT;
