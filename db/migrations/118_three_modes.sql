-- ============================================================
-- 118: Nur noch drei Modi – Original, Buzzer, Jahr raten (Wunsch Mehdi 2026-10-14)
-- ============================================================
-- Entfernt: Wer singt das?, Blitz-Schnipsel, Songwahl, Lückentitel, Duell, Teams (Teams-Logik aus Kartoffel-Funktionen
-- ausgebaut; players.team bleibt als ungenutzte Spalte stehen, damit ältere Seiten beim Laden nicht brechen).
-- Neue Ziele:
--   Original  – wer zuletzt noch im Spiel ist, gewinnt (unverändert)
--   Buzzer    – wer zuerst 10 Punkte hat, gewinnt (Titel +2, nur Künstler +1; falsch = für den Song raus; höchstens 20 Songs)
--   Jahr raten– nach 8 Songs gewinnt, wer die meisten Punkte hat (Gleichstand: mehr Volltreffer)
-- Neu: lobbies.quiz_target (Punkteziel, nur Buzzer), players.tiebreak (Gleichstand-Wertung, nur intern).
BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS quiz_target int;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS tiebreak numeric NOT NULL DEFAULT 0;

-- Laufende Runden mit entfernten Modi sauber beenden, alle anderen Lobbys auf Original stellen
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.lobbies WHERE phase = 'quiz' AND game_mode NOT IN ('buzzer', 'year') LOOP
    PERFORM public._quiz_finish(r.id);
  END LOOP;
END $$;
UPDATE public.lobbies SET game_mode = 'original' WHERE game_mode NOT IN ('original', 'buzzer', 'year');
ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_game_mode_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_game_mode_check CHECK (game_mode = ANY (ARRAY['original', 'buzzer', 'year']));
DELETE FROM public.mode_plays WHERE mode NOT IN ('original', 'buzzer', 'year');

CREATE OR REPLACE FUNCTION public.set_lobby_mode(p_lobby_id uuid, p_me_player_id uuid, p_mode text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_mode text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  v_mode := btrim(coalesce(p_mode, ''));
  if v_mode not in ('original','buzzer','year') then raise exception 'invalid_mode'; end if;
  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public._next_alive(p_lobby_id uuid, p_from uuid, p_dir integer)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v_seat int; v_next uuid;
begin
  select seat_index into v_seat from public.players where lobby_id = p_lobby_id and player_id = p_from;
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

  if v_alive_count <= 1 then
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

  if v_alive <= 1 then
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

CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
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
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.tiebreak desc, p.pass_count desc, p.seat_index
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


-- ===== Quiz-Motor (nur noch Buzzer und Jahr raten) =====
DROP FUNCTION IF EXISTS public.rpc_quiz_pick(text, uuid, uuid);
DROP FUNCTION IF EXISTS public.rpc_quiz_bet(text, uuid, uuid);
DROP FUNCTION IF EXISTS public._quiz_do_pick(uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public._quiz_do_bet(uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public._quiz_duel_song(uuid);
DROP FUNCTION IF EXISTS public._quiz_artist_options(uuid);
DROP FUNCTION IF EXISTS public._quiz_rank_points(int);
DROP FUNCTION IF EXISTS public._teams_decided(uuid);
DROP TABLE IF EXISTS public.quiz_bets;

CREATE OR REPLACE FUNCTION public._is_quiz_mode(p_mode text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(p_mode, '') = ANY (ARRAY['buzzer','year']) $$;

CREATE OR REPLACE FUNCTION public._quiz_seconds(p_mode text, p_state text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state
    WHEN 'reveal' THEN CASE p_mode WHEN 'year' THEN 8 ELSE 5 END
    WHEN 'buzzed' THEN 7
    ELSE CASE p_mode WHEN 'year' THEN 20 ELSE 30 END
  END::numeric
$$;

CREATE OR REPLACE FUNCTION public._quiz_candidates(p_lobby_id uuid, p_mode text, p_n int) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_topic text; v_used uuid[]; v_ids uuid[];
BEGIN
  SELECT topic_selected, coalesce(used_song_ids, '{}') INTO v_topic, v_used FROM public.lobbies WHERE id = p_lobby_id;
  SELECT array_agg(id) INTO v_ids FROM (
    SELECT sp.id FROM public.song_pool sp
    JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id AND tp.is_song_category IS TRUE AND lower(tp.text) = lower(coalesce(v_topic, ''))
    WHERE sp.archived_from IS NULL AND sp.preview_url IS NOT NULL
      AND NOT (sp.id = ANY (v_used))
      AND (p_mode <> 'year' OR sp.release_year IS NOT NULL)
    ORDER BY random() LIMIT p_n
  ) x;
  RETURN coalesce(v_ids, '{}');
END $$;

-- Song-Statistik (Schwierigkeit): nur Menschen, nur im Buzzer (dort muss man den Song erkennen)
CREATE OR REPLACE FUNCTION public._quiz_take_song(p_lobby_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_plays int; v_hits int; v_h int;
BEGIN
  SELECT count(*) INTO v_h
  FROM public.players p JOIN public.lobbies l ON l.id = p.lobby_id
  WHERE l.id = p_lobby_id AND p.status = 'active' AND NOT coalesce(p.is_bot, false) AND l.game_mode = 'buzzer';
  UPDATE public.song_pool SET plays = plays + coalesce(v_h, 0) WHERE id = p_song_id RETURNING plays, hits INTO v_plays, v_hits;
  UPDATE public.lobbies
     SET current_song_id = p_song_id, current_song_started_at = now(),
         current_song_difficulty = public._song_difficulty(v_plays, v_hits),
         used_song_ids = array_append(coalesce(used_song_ids, '{}'), p_song_id)
   WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_start_question(p_lobby_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_year int; v_seq int;
BEGIN
  SELECT game_mode, quiz_seq + 1 INTO v_mode, v_seq FROM public.lobbies WHERE id = p_lobby_id;
  SELECT release_year INTO v_year FROM public.song_pool WHERE id = p_song_id;
  PERFORM public._quiz_take_song(p_lobby_id, p_song_id);
  INSERT INTO public.quiz_secret (lobby_id, seq, song_id, answer, year)
  VALUES (p_lobby_id, v_seq, p_song_id, NULL, v_year)
  ON CONFLICT (lobby_id) DO UPDATE SET seq = excluded.seq, song_id = excluded.song_id, answer = NULL, year = excluded.year, pick_options = NULL;
  UPDATE public.lobbies
     SET quiz_state = 'question', quiz_seq = v_seq, quiz_started_at = now(),
         quiz_ends_at = now() + public._quiz_seconds(v_mode, 'question') * interval '1 second',
         quiz_options = CASE WHEN v_mode = 'year' THEN quiz_options ELSE NULL END, quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL,
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Wer darf gerade antworten? (Buzzer: alle, die nicht für diesen Song gesperrt sind)
CREATE OR REPLACE FUNCTION public._quiz_eligible(p_lobby_id uuid) RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(array_agg(p.player_id), '{}')
  FROM public.players p, public.lobbies l
  WHERE l.id = p_lobby_id AND p.lobby_id = l.id AND p.status = 'active' AND NOT (p.player_id = ANY (l.quiz_locked))
$$;

-- Jahr raten: haben alle getippt? -> Auflösung gleich (0,8 s Puffer)
CREATE OR REPLACE FUNCTION public._quiz_maybe_early(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_seq int; v_elig uuid[]; v_done int;
BEGIN
  SELECT quiz_seq INTO v_seq FROM public.lobbies WHERE id = p_lobby_id AND quiz_state = 'question' AND game_mode = 'year';
  IF NOT FOUND THEN RETURN; END IF;
  v_elig := public._quiz_eligible(p_lobby_id);
  IF coalesce(array_length(v_elig, 1), 0) = 0 THEN RETURN; END IF;
  SELECT count(*) INTO v_done FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = v_seq AND a.player_id = ANY (v_elig);
  IF v_done >= array_length(v_elig, 1) THEN
    UPDATE public.lobbies SET quiz_ends_at = least(quiz_ends_at, now() + interval '800 milliseconds') WHERE id = p_lobby_id;
  END IF;
END $$;

-- Nächste Frage – oder Ende: Buzzer endet, sobald jemand das Ziel erreicht hat (oder nach quiz_total Songs)
CREATE OR REPLACE FUNCTION public._quiz_next(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_ids uuid[];
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RETURN; END IF;
  IF l.quiz_target IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active' AND coalesce(song_points, 0) >= l.quiz_target) THEN
    PERFORM public._quiz_finish(p_lobby_id); RETURN;
  END IF;
  IF l.quiz_index >= l.quiz_total THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  v_ids := public._quiz_candidates(p_lobby_id, l.game_mode, 1);
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  UPDATE public.lobbies SET quiz_index = quiz_index + 1 WHERE id = p_lobby_id;
  PERFORM public._quiz_start_question(p_lobby_id, v_ids[1]);
END $$;

-- Auflösung: Jahr-Punkte vergeben, Lösung zeigen, Ziel-Erreicht-Hinweis (Buzzer)
CREATE OR REPLACE FUNCTION public._quiz_reveal(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; v_title text; v_artist text; v_results jsonb; v_goal uuid;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  SELECT title, artist INTO v_title, v_artist FROM public.song_pool WHERE id = s.song_id;

  IF l.game_mode = 'year' AND s.year IS NOT NULL THEN
    UPDATE public.quiz_answers a
       SET points = CASE abs(a.num - s.year) WHEN 0 THEN 5 WHEN 1 THEN 3 WHEN 2 THEN 2 ELSE CASE WHEN abs(a.num - s.year) <= 5 THEN 1 ELSE 0 END END,
           correct = abs(a.num - s.year) <= 2
     WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.num IS NOT NULL;
    UPDATE public.players p SET song_points = coalesce(p.song_points, 0) + a.points
      FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND p.lobby_id = p_lobby_id AND p.player_id = a.player_id;
  END IF;

  IF l.quiz_target IS NOT NULL THEN
    SELECT player_id INTO v_goal FROM public.players
     WHERE lobby_id = p_lobby_id AND status = 'active' AND coalesce(song_points, 0) >= l.quiz_target
     ORDER BY song_points DESC LIMIT 1;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('playerId', a.player_id, 'points', a.points, 'correct', a.correct,
           'answer', CASE WHEN l.game_mode = 'year' THEN a.num::text ELSE NULL END) ORDER BY a.points DESC, a.answered_at), '[]')
    INTO v_results FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq;

  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('title', v_title, 'artist', v_artist, 'year', s.year, 'results', v_results, 'goal', v_goal),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds(l.game_mode, 'reveal') * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Ende der Runde: Gleichstand-Wertung merken, dann Wertung/Zwischenstand wie bei der Kartoffel
CREATE OR REPLACE FUNCTION public._quiz_finish(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_top uuid; v_mode text;
BEGIN
  SELECT game_mode INTO v_mode FROM public.lobbies WHERE id = p_lobby_id;
  -- Gleichstand: Jahr raten = mehr Volltreffer (5 P.), dann mehr Treffer ±1, ±2; Buzzer = mehr richtige Antworten
  UPDATE public.players p SET tiebreak = coalesce((
      SELECT CASE WHEN v_mode = 'year'
                  THEN sum(CASE WHEN a.points >= 5 THEN 100 WHEN a.points >= 3 THEN 10 WHEN a.points >= 2 THEN 1 ELSE 0 END)
                  ELSE count(*) FILTER (WHERE a.correct) END
      FROM public.quiz_answers a WHERE a.lobby_id = p.lobby_id AND a.player_id = p.player_id), 0)
   WHERE p.lobby_id = p_lobby_id AND p.status = 'active';
  SELECT player_id INTO v_top FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active'
    ORDER BY coalesce(song_points, 0) DESC, tiebreak DESC, seat_index LIMIT 1;
  UPDATE public.lobbies SET quiz_state = NULL, quiz_ends_at = NULL, quiz_picker = NULL, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._finish_round(p_lobby_id);
  UPDATE public.lobbies SET holder_player_id = v_top WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_tick(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_end timestamptz;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_ends_at IS NULL OR l.quiz_ends_at > now() THEN RETURN; END IF;
  IF l.quiz_state = 'buzzed' THEN
    -- Zeit zum Antworten abgelaufen: dieser Spieler ist für den Song raus, die anderen dürfen weiter buzzern
    v_end := greatest(coalesce((l.quiz_options ->> 'qend')::timestamptz, now()), now() + interval '5 seconds');
    UPDATE public.lobbies SET quiz_state = 'question', quiz_locked = array_append(quiz_locked, quiz_picker), quiz_picker = NULL,
                              quiz_ends_at = v_end, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    IF coalesce(array_length(public._quiz_eligible(p_lobby_id), 1), 0) = 0 THEN PERFORM public._quiz_reveal(p_lobby_id); END IF;
  ELSIF l.quiz_state = 'question' THEN
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSIF l.quiz_state = 'reveal' THEN
    PERFORM public._quiz_next(p_lobby_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_begin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_min int; v_max int; v_opts jsonb;
BEGIN
  SELECT game_mode INTO v_mode FROM public.lobbies WHERE id = p_lobby_id;
  -- Jahr raten: Zeitleiste = ältester bis neuester Song der Playlist (mindestens 15 Jahre breit)
  IF v_mode = 'year' THEN
    SELECT min(sp.release_year), max(sp.release_year) INTO v_min, v_max
      FROM public.song_pool sp
      JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id AND tp.is_song_category IS TRUE
      JOIN public.lobbies l ON l.id = p_lobby_id AND lower(tp.text) = lower(coalesce(l.topic_selected, ''))
     WHERE sp.archived_from IS NULL AND sp.release_year IS NOT NULL;
    v_max := coalesce(v_max, extract(year FROM now())::int);
    v_min := least(coalesce(v_min, v_max - 14) - 1, v_max - 14);
    v_opts := jsonb_build_object('yearMin', v_min, 'yearMax', v_max);
  END IF;
  DELETE FROM public.quiz_answers WHERE lobby_id = p_lobby_id;
  UPDATE public.players SET song_points = 0, tiebreak = 0, is_alive = true, eliminated_at_round = NULL WHERE lobby_id = p_lobby_id AND status = 'active';
  UPDATE public.lobbies
     SET phase = 'quiz', explode_at = NULL, holder_player_id = NULL,
         quiz_index = 0, quiz_state = NULL, quiz_options = v_opts, quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL,
         -- Ziel: Buzzer = zuerst 10 Punkte (höchstens 20 Songs), Jahr raten = nach 8 Songs die meisten Punkte
         quiz_target = CASE WHEN v_mode = 'buzzer' THEN 10 ELSE NULL END,
         quiz_total = CASE WHEN v_mode = 'buzzer' THEN 20 ELSE 8 END,
         used_answers = '{}',
         used_song_ids = CASE WHEN coalesce(series_index, 1) <= 1 THEN '{}' ELSE coalesce(used_song_ids, '{}') END,
         run_started_at = now(), countdown_started_at = NULL, countdown_ends_at = NULL, countdown_starter_player_id = NULL,
         last_activity_at = now()
   WHERE id = p_lobby_id;
  PERFORM public._quiz_next(p_lobby_id);
END $$;

-- Buzzer: getippte Antwort des Spielers, der gebuzzert hat (Titel +2, nur Künstler +1)
CREATE OR REPLACE FUNCTION public._quiz_do_answer(p_lobby_id uuid, p_player_id uuid, p_answer text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE;
        v_score numeric; v_title text; v_artist text; v_feat text[]; v_pts numeric := 0; v_clean text;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RAISE EXCEPTION 'quiz_not_running'; END IF;
  IF l.game_mode <> 'buzzer' THEN RAISE EXCEPTION 'quiz_wrong_action'; END IF;
  IF l.quiz_state <> 'buzzed' OR l.quiz_picker IS DISTINCT FROM p_player_id THEN RAISE EXCEPTION 'quiz_not_your_turn'; END IF;
  v_clean := left(trim(coalesce(p_answer, '')), 60);
  IF v_clean = '' THEN RAISE EXCEPTION 'empty_answer'; END IF;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  SELECT title, artist, feat_artists INTO v_title, v_artist, v_feat FROM public.song_pool WHERE id = s.song_id;
  v_score := public._score_song_answer(v_title, v_artist, v_feat, v_clean);

  IF v_score <= 0 THEN
    INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, tries, answered_at)
    VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_clean, 1, now())
    ON CONFLICT (lobby_id, seq, player_id) DO UPDATE SET answer = excluded.answer, tries = quiz_answers.tries + 1, answered_at = now();
    -- falsch: für diesen Song raus, die anderen dürfen weiter buzzern
    UPDATE public.lobbies SET quiz_state = 'question', quiz_locked = array_append(quiz_locked, p_player_id), quiz_picker = NULL,
           quiz_ends_at = greatest(coalesce((quiz_options ->> 'qend')::timestamptz, now()), now() + interval '5 seconds'),
           quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND is_bot) THEN
      INSERT INTO public.answer_misses (lobby_id, song_id, player_id, answer) VALUES (p_lobby_id, s.song_id, p_player_id, v_clean);
    END IF;
    IF coalesce(array_length(public._quiz_eligible(p_lobby_id), 1), 0) = 0 THEN PERFORM public._quiz_reveal(p_lobby_id); END IF;
    RETURN jsonb_build_object('correct', false);
  END IF;

  v_pts := CASE WHEN v_score >= 1 THEN 2 ELSE 1 END;
  INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, correct, points, tries, answered_at)
  VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_clean, true, v_pts, 1, now())
  ON CONFLICT (lobby_id, seq, player_id) DO UPDATE SET answer = excluded.answer, correct = true, points = excluded.points,
     tries = quiz_answers.tries + 1, answered_at = now();
  UPDATE public.players SET song_points = coalesce(song_points, 0) + v_pts WHERE lobby_id = p_lobby_id AND player_id = p_player_id;
  -- Treffer für die Song-Statistik: nur Menschen
  IF v_score >= 1 AND s.song_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND coalesce(is_bot, false)) THEN
    UPDATE public.song_pool SET hits = hits + 1 WHERE id = s.song_id;
  END IF;
  PERFORM public._quiz_reveal(p_lobby_id);
  RETURN jsonb_build_object('correct', true, 'points', v_pts, 'half', v_score < 1);
END $$;

-- Jahr raten: Jahr tippen (einmal pro Frage)
CREATE OR REPLACE FUNCTION public._quiz_do_choose(p_lobby_id uuid, p_player_id uuid, p_choice text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_num int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_state <> 'question' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF l.game_mode <> 'year' THEN RAISE EXCEPTION 'quiz_wrong_action'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active') THEN RAISE EXCEPTION 'not_a_member'; END IF;
  IF EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id) THEN
    RAISE EXCEPTION 'quiz_already_answered';
  END IF;
  BEGIN v_num := trim(p_choice)::int; EXCEPTION WHEN others THEN RAISE EXCEPTION 'quiz_bad_year'; END;
  IF v_num < coalesce((l.quiz_options ->> 'yearMin')::int, 1900) OR v_num > coalesce((l.quiz_options ->> 'yearMax')::int, 2100) THEN RAISE EXCEPTION 'quiz_bad_year'; END IF;
  INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, num, correct, points, tries, answered_at)
  VALUES (p_lobby_id, l.quiz_seq, p_player_id, left(p_choice, 80), v_num, false, 0, 1, now());
  UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._quiz_maybe_early(p_lobby_id);
  RETURN jsonb_build_object('points', 0);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_status(p_code text, p_player_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; l public.lobbies%ROWTYPE; v_me jsonb;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  SELECT * INTO l FROM public.lobbies WHERE id = v_id;
  SELECT jsonb_build_object('answered', true, 'correct', a.correct, 'points', a.points, 'tries', a.tries, 'answer', a.num::text)
    INTO v_me FROM public.quiz_answers a WHERE a.lobby_id = v_id AND a.seq = l.quiz_seq AND a.player_id = p_player_id;
  RETURN jsonb_build_object(
    'seq', l.quiz_seq,
    'me', coalesce(v_me, jsonb_build_object('answered', false)),
    -- Jahr raten: wer schon getippt hat (ohne die Jahre selbst – die sieht man erst bei der Auflösung)
    'answered', CASE WHEN l.game_mode = 'year'
                     THEN (SELECT coalesce(jsonb_agg(player_id), '[]') FROM public.quiz_answers WHERE lobby_id = v_id AND seq = l.quiz_seq)
                     ELSE '[]'::jsonb END
  );
END $$;

-- Bots: Buzzer (spät und mit Fehlern, damit Menschen eine Chance haben) und Jahr raten (Schätzfehler je nach Stärke)
CREATE OR REPLACE FUNCTION public._quiz_bot_tick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r record; v_seed text; v_delay numeric; v_ok boolean; v_el numeric; s public.quiz_secret%ROWTYPE; v_answer text; v_year int; v_range int;
BEGIN
  FOR r IN
    SELECT l.id AS lobby_id, l.game_mode, l.quiz_state, l.quiz_seq, l.quiz_index, l.quiz_started_at, l.quiz_picker, l.quiz_locked, l.quiz_options,
           p.player_id, coalesce(p.bot_skill, 2) AS skill
    FROM public.lobbies l JOIN public.players p ON p.lobby_id = l.id AND p.is_bot AND p.status = 'active'
    WHERE l.phase = 'quiz' AND l.quiz_state IN ('question', 'buzzed')
  LOOP
    BEGIN
      v_seed := r.player_id::text || ':' || r.quiz_seq || ':' || r.quiz_state || ':' || r.quiz_index;
      v_el := extract(epoch FROM now() - r.quiz_started_at);
      v_ok := (abs(hashtext('ok' || v_seed)) % 1000) / 1000.0 < (CASE r.skill WHEN 1 THEN 0.45 WHEN 3 THEN 0.85 ELSE 0.65 END);
      v_delay := CASE r.skill WHEN 1 THEN 6 WHEN 3 THEN 1.5 ELSE 3.5 END + (abs(hashtext('d' || v_seed)) % 1000) / 1000.0 * CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 2.5 ELSE 4.5 END;
      IF r.game_mode = 'buzzer' THEN v_delay := v_delay * 2.2 + 2; END IF;

      IF r.quiz_state = 'buzzed' THEN
        IF r.quiz_picker = r.player_id AND v_el > 1.5 THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 2 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
            INTO v_answer FROM public.song_pool WHERE id = s.song_id;
          PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
        END IF;
      ELSIF r.quiz_state = 'question' AND v_el >= v_delay THEN
        IF r.game_mode = 'buzzer' THEN
          IF v_ok AND NOT (r.player_id = ANY (r.quiz_locked)) THEN PERFORM public._quiz_do_buzz(r.lobby_id, r.player_id); END IF;
        ELSIF r.game_mode = 'year'
              AND NOT EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = r.lobby_id AND seq = r.quiz_seq AND player_id = r.player_id) THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          v_range := CASE r.skill WHEN 1 THEN 7 WHEN 3 THEN 2 ELSE 4 END;
          v_year := coalesce(s.year, 2020) + (abs(hashtext('y' || v_seed)) % (2 * v_range + 1)) - v_range;
          v_year := greatest(coalesce((r.quiz_options ->> 'yearMin')::int, 1900), least(coalesce((r.quiz_options ->> 'yearMax')::int, 2100), v_year));
          PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_year::text);
        END IF;
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END $$;

COMMIT;
