-- ============================================================
-- Migration 034: Obergrenze für den kumulierten Pass-Bonus pro Runde
-- ============================================================
-- Live-Test mit 8 Spielern (Migration 032 nach dem Einbau): Runde 1 lief
-- 27.7s, Runde 2 aber 64.3s -- mit mehr lebenden Spielern gibt es mehr
-- Gelegenheiten, die Kartoffel erfolgreich weiterzureichen, und jeder
-- erfolgreiche Pass verlängert den Timer erneut. Bei genug Glück in
-- Folge kann eine Runde dadurch beliebig lange laufen -- "zu wenige
-- Bots fliegen pro Zeiteinheit", das Spiel zieht sich.
--
-- Fix: pro Runde gibt es jetzt eine Obergrenze, wie viel Bonuszeit sich
-- insgesamt aufsummieren darf (skaliert mit der Spielerzahl -- größere
-- Lobbys bekommen mehr Puffer, aber nie unbegrenzt). Ist die Grenze
-- erreicht, wird die Kartoffel trotzdem normal weitergereicht, der
-- Timer bekommt nur keinen weiteren Aufschlag mehr -- die Runde läuft
-- dann so lange wie geplant statt sich unbegrenzt weiter aufzuschaukeln.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS round_bonus_used numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.calc_pass_bonus_cap(p_alive_count integer)
    RETURNS numeric LANGUAGE sql IMMUTABLE
AS $function$
    SELECT greatest(12, least(30, coalesce(p_alive_count, 4) * 3));
$function$;

-- Reset bei jedem Rundenstart (neues Match/Rematch)
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
begin
  select round_speed, coalesce(round_number, 0)
    into v_round_speed, v_round_number
  from public.lobbies where id = p_lobby_id for update;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

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
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      round_bonus_used = 0,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- Reset bei jedem Rundenwechsel nach einer Explosion
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

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
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

-- Bonus bei jedem Pass jetzt gegen die Obergrenze geprüft
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number, coalesce(l.round_bonus_used, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number, v_bonus_used
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

  -- Mode-aware next holder
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
    next_idx := idx + 1;
    if next_idx > n then next_idx := 1; end if;
    v_next := alive_ids[next_idx];
  end if;

  -- Grace-Bonus, gedeckelt: pro Runde darf sich höchstens calc_pass_bonus_cap(alive)
  -- Sekunden an Bonuszeit aufsummieren, damit viele Spieler + viel Glück nicht zu
  -- einer beliebig lang laufenden Runde führen (siehe Migrationskopf).
  v_bonus_cap := public.calc_pass_bonus_cap(n);
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number);
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second'),
      round_bonus_used = v_bonus_used + v_bonus_applied,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  -- Stats tracking
  select last_pass_at into v_last_pass from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms from public.lobbies where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;
