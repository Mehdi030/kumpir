-- ============================================================
-- KUMPIR — RPC-Funktionen (gedumpt aus Supabase)
-- Stand: 2026-05-11
-- Quelle: User-Dump via SQL-Editor Query 2 aus db/HOW_TO_DUMP.md
-- ============================================================

CREATE OR REPLACE FUNCTION public._pick_next_host(p_lobby_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  select p.player_id
  from public.players p
  where p.lobby_id = p_lobby_id
    and p.status = 'active'
  order by p.joined_at asc nulls last
  limit 1
$function$;


CREATE OR REPLACE FUNCTION public.assign_seat_index()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.seat_index is null then
    perform 1 from public.lobbies where id = new.lobby_id for update;

    select coalesce(max(seat_index), -1) + 1
      into new.seat_index
    from public.players
    where lobby_id = new.lobby_id;
  end if;

  return new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.auto_transfer_host(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_current_host uuid;
  v_host_active boolean;
  v_new_host uuid;
begin
  select host_player_id into v_current_host
  from public.lobbies
  where id = p_lobby_id;

  if v_current_host is null then
    select p.player_id
      into v_new_host
    from public.players p
    where p.lobby_id = p_lobby_id
      and p.status = 'active'
    order by p.joined_at asc
    limit 1;

    if v_new_host is not null then
      update public.lobbies set host_player_id = v_new_host where id = p_lobby_id;
    end if;
    return;
  end if;

  select exists(
    select 1
    from public.players p
    where p.lobby_id = p_lobby_id
      and p.player_id = v_current_host
      and p.status = 'active'
  ) into v_host_active;

  if v_host_active then
    return;
  end if;

  select p.player_id
    into v_new_host
  from public.players p
  where p.lobby_id = p_lobby_id
    and p.status = 'active'
  order by p.joined_at asc
  limit 1;

  update public.lobbies
     set host_player_id = v_new_host
   where id = p_lobby_id;
end;
$function$;


-- ============================================================
-- LEGACY: begin_round, boom, pass_potato (2x), start_game (3x),
-- start_lobby, start_round, leave_lobby (2x), kick_player (2x)
-- nutzen ein anderes Schema (lobby_code statt lobby_id, is_eliminated
-- statt is_alive, is_connected, is_ready, ended_at, started_at).
-- Diese sind vermutlich ALT und werden vom aktuellen Frontend nicht
-- mehr aufgerufen. Bei Gelegenheit aufräumen → eigenes Cleanup-Ticket.
-- ============================================================


CREATE OR REPLACE FUNCTION public.calc_explode_seconds(p_round_speed text, p_alive_count integer, p_round_number integer, p_exponent numeric DEFAULT 1.9, p_quantize_step_sec numeric DEFAULT 0.5, p_clamp_min_sec numeric DEFAULT 3)
 RETURNS numeric
 LANGUAGE plpgsql
AS $function$
declare
  base_min numeric; base_max numeric;
  scale_alive numeric; scale_round numeric;
  min_sec numeric; max_sec numeric;
  u numeric; biased numeric; raw numeric; quantized numeric;
begin
  if p_round_speed = 'fast' then
    base_min := 9;  base_max := 16;
  elsif p_round_speed = 'normal' then
    base_min := 14; base_max := 26;
  elsif p_round_speed = 'calm' then
    base_min := 22; base_max := 40;
  else
    base_min := 14; base_max := 26;
  end if;

  scale_alive := greatest(0.75, least(1.25, 1.15 - (p_alive_count * 0.035)));
  scale_round := greatest(0.65, 1.0 - greatest(0, (p_round_number - 1)) * 0.03);

  min_sec := greatest(p_clamp_min_sec, base_min * scale_alive * scale_round);
  max_sec := greatest(min_sec + 1, base_max * scale_alive * scale_round);

  u := random();
  biased := power(u, p_exponent);
  raw := min_sec + biased * (max_sec - min_sec);

  quantized := round(raw / p_quantize_step_sec) * p_quantize_step_sec;

  return greatest(p_clamp_min_sec, quantized);
end;
$function$;


CREATE OR REPLACE FUNCTION public.cleanup_lobby(p_lobby_id uuid, p_stale_seconds integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_host uuid;
  v_new_host uuid;
  v_phase text;
begin
  select host_player_id, phase
    into v_host, v_phase
  from public.lobbies
  where id = p_lobby_id;

  -- Only mark players as 'left' BEFORE the game is running.
  if v_phase is null or v_phase in ('lobby', 'topic_vote', 'countdown') then
    update public.players
    set status = 'left',
        left_at = coalesce(left_at, now())
    where lobby_id = p_lobby_id
      and status = 'active'
      and (
        last_seen_at is null
        or last_seen_at < (now() - make_interval(secs => p_stale_seconds))
      );
  end if;

  if v_host is not null then
    if not exists (
      select 1 from public.players
      where lobby_id = p_lobby_id
        and player_id = v_host
        and status = 'active'
    ) then
      select player_id into v_new_host
      from public.players
      where lobby_id = p_lobby_id
        and status = 'active'
      order by joined_at asc nulls last, player_id asc
      limit 1;

      update public.lobbies
      set host_player_id = v_new_host
      where id = p_lobby_id;
    end if;
  end if;
end;
$function$;


CREATE OR REPLACE FUNCTION public.gen_lobby_code(p_len integer DEFAULT 4)
 RETURNS text LANGUAGE plpgsql
AS $function$
declare chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; out text := ''; i int;
begin
  if p_len < 4 then p_len := 4; end if;
  for i in 1..p_len loop
    out := out || substr(chars, 1 + floor(random() * length(chars))::int, 1);
  end loop;
  return out;
end;
$function$;


CREATE OR REPLACE FUNCTION public.generate_lobby_code(p_len integer DEFAULT 4)
 RETURNS text LANGUAGE plpgsql
AS $function$
declare chars constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; out text := ''; i int;
begin
  if p_len is null or p_len < 1 or p_len > 12 then raise exception 'invalid_code_len'; end if;
  for i in 1..p_len loop
    out := out || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  end loop;
  return out;
end;
$function$;


CREATE OR REPLACE FUNCTION public.get_email_for_username(p_username text)
 RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select trim(email) from public.profiles
  where lower(username) = lower(public.normalize_username(p_username))
  limit 1;
$function$;


CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  insert into public.profiles (id, username, email, created_at)
  values (
    new.id,
    nullif(public.normalize_username(coalesce(new.raw_user_meta_data->>'username','')), ''),
    new.email,
    now()
  )
  on conflict (id) do update set
    username = coalesce(public.profiles.username, excluded.username),
    email = coalesce(excluded.email, public.profiles.email);
  return new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.is_username_available(p_username text)
 RETURNS boolean LANGUAGE sql STABLE
AS $function$
  select not exists (
    select 1 from public.profiles
    where lower(username) = lower(p_username)
  );
$function$;


-- ============================================================
-- AKTIV: rpc_join_lobby (im Frontend genutzt)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_join_lobby(p_code text, p_player_id uuid, p_name text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_locked boolean;
  v_max_players int;
  v_active_count int;
  v_next_seat int;
begin
  select id, locked, max_players into v_lobby_id, v_locked, v_max_players
  from public.lobbies where upper(code) = upper(p_code) limit 1;

  if v_lobby_id is null then raise exception 'lobby_not_found'; end if;
  if v_locked then raise exception 'lobby_locked'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  if v_active_count >= v_max_players then raise exception 'lobby_full'; end if;

  select coalesce(min(s.i), 0) into v_next_seat
  from generate_series(0, v_max_players - 1) as s(i)
  left join public.players p
    on p.lobby_id = v_lobby_id and p.seat_index = s.i and p.status = 'active'
  where p.id is null;

  insert into public.players (lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at)
  values (v_lobby_id, p_player_id, left(trim(p_name), 24), 'active', v_next_seat, now(), now())
  on conflict (lobby_id, player_id) do update set
    name = excluded.name,
    status = 'active',
    left_at = null,
    kicked_at = null,
    last_seen_at = now(),
    seat_index = coalesce(public.players.seat_index, excluded.seat_index);
end;
$function$;


CREATE OR REPLACE FUNCTION public.kick_player(p_lobby_id uuid, p_me_player_id uuid, p_target_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare v_host uuid;
begin
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  if p_target_player_id = v_host then raise exception 'cannot_kick_host'; end if;

  update public.players
  set status = 'kicked', kicked_at = now()
  where lobby_id = p_lobby_id and player_id = p_target_player_id and status = 'active';
end;
$function$;


CREATE OR REPLACE FUNCTION public.normalize_username(u text)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $function$ select lower(trim(u)) $function$;


-- ============================================================
-- AKTIV: rpc_pass_potato — enthält BEREITS Teleport + Reverse Logik
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
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

  update public.lobbies set holder_player_id = v_next, last_activity_at = v_now where id = v_lobby_id;

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


CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';
end;
$function$;


-- ============================================================
-- KRITISCH: rpc_begin_topic_vote nutzt topic_pool ✅
-- ABER: rpc_start_rematch_if_ready nutzt `topics` (Inkonsistenz!)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare v_host uuid; v_a text; v_b text;
begin
  select host_player_id into v_host
  from public.lobbies where id = p_lobby_id for update;

  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select t.text into v_a from public.topic_pool t where t.active is true
  order by random() limit 1;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a
  order by random() limit 1;

  if v_a is null or v_b is null then raise exception 'Not enough topics in topic_pool'; end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_create_lobby(p_host_name text, p_privacy text, p_max_players integer, p_round_seconds integer)
 RETURNS TABLE(code text, host_player_id uuid)
 LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare
  v_lobby_id uuid := gen_random_uuid();
  v_code text;
  v_host_player_id uuid := gen_random_uuid();
begin
  v_code := public.generate_lobby_code(4);

  insert into public.lobbies (
    id, code, host_player_id, status, privacy, max_players, round_seconds, created_at, last_activity_at, host_user_id
  ) values (
    v_lobby_id, upper(v_code), v_host_player_id, 'waiting', p_privacy,
    greatest(2, least(p_max_players, 12)),
    coalesce(p_round_seconds, 25),
    now(), now(), null
  );

  insert into public.players (id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id)
  values (gen_random_uuid(), v_lobby_id, v_host_player_id, left(trim(p_host_name), 24), false, now(), now(), null);

  return query select upper(v_code), v_host_player_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text;
  v_a_count int := 0; v_b_count int := 0; v_r_count int := 0;
  v_selected text; v_pick int; v_choices int[];
begin
  select topic_a, topic_b into v_topic_a, v_topic_b
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  select count(*) into v_r_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;

  if v_a_count > v_b_count and v_a_count > v_r_count then
    v_selected := v_topic_a; v_pick := 1; v_choices := null;
  elsif v_b_count > v_a_count and v_b_count > v_r_count then
    v_selected := v_topic_b; v_pick := 2; v_choices := null;
  elsif v_r_count > v_a_count and v_r_count > v_b_count then
    v_pick := (array[1,2])[1 + floor(random() * 2)::int];
    v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
    v_choices := array[3];
  else
    v_choices := array[]::int[];
    if v_a_count = greatest(v_a_count, v_b_count, v_r_count) then v_choices := array_append(v_choices, 1); end if;
    if v_b_count = greatest(v_a_count, v_b_count, v_r_count) then v_choices := array_append(v_choices, 2); end if;
    if v_r_count = greatest(v_a_count, v_b_count, v_r_count) then v_choices := array_append(v_choices, 3); end if;
    v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
    if v_pick = 1 then v_selected := v_topic_a;
    elsif v_pick = 2 then v_selected := v_topic_b;
    else
      v_pick := (array[1,2])[1 + floor(random() * 2)::int];
      v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
    end if;
  end if;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_heartbeat(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
begin
  update public.players
  set last_seen_at = now(), status = 'active'
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


-- ============================================================
-- BUG: rpc_start_rematch_if_ready nutzt `topics.name`,
-- aber rpc_begin_topic_vote nutzt `topic_pool.text`.
-- Inkonsistenz! Sollte eines von beiden umgestellt werden.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_ready_count int; v_active_count int;
  v_topic_a text; v_topic_b text;
begin
  select id into v_lobby_id from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  select count(*) into v_ready_count from public.players
  where lobby_id = v_lobby_id and status = 'active' and coalesce(ready, false) = true;

  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;
  if v_ready_count <> v_active_count then return; end if;

  -- ⚠️ nutzt topics, nicht topic_pool wie rpc_begin_topic_vote!
  with picked as (
    select name from public.topics where active = true order by random() limit 2
  )
  select
    max(case when rn = 1 then name end),
    max(case when rn = 2 then name end)
  into v_topic_a, v_topic_b
  from (select name, row_number() over () as rn from picked) x;

  if v_topic_a is null or v_topic_b is null then
    raise exception 'Nicht genug aktive Themen vorhanden';
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = false
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_selected = null,
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


-- ============================================================
-- AKTIV: rpc_tick_game — Eliminierung + Mode-aware next holder
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval := interval '15 seconds';
begin
  select id, phase, holder_player_id, explode_at, game_mode
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode
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
  where id = v_lobby_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null,
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

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = v_now + v_round_duration,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_toggle_ready(p_lobby_id uuid, p_player_id uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_new boolean;
begin
  update public.players
  set ready = not coalesce(ready,false), last_seen_at = now()
  where lobby_id = p_lobby_id and player_id = p_player_id
  returning ready into v_new;

  if v_new is null then raise exception 'Player not found in lobby'; end if;

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
  return v_new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_vote_topic(p_lobby_id uuid, p_player_id uuid, p_choice integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
begin
  if p_choice not in (1,2,3) then raise exception 'Invalid choice %', p_choice; end if;

  insert into public.topic_votes (lobby_id, player_id, choice)
  values (p_lobby_id, p_player_id, p_choice)
  on conflict (lobby_id, player_id)
  do update set choice = excluded.choice;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_lobby_lock(p_lobby_id uuid, p_me_player_id uuid, p_locked boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid;
begin
  select l.host_player_id into v_host from public.lobbies l where l.id = p_lobby_id;
  if v_host is null or v_host <> p_me_player_id then raise exception 'not_host'; end if;
  update public.lobbies set locked = p_locked where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_lobby_mode(p_lobby_id uuid, p_me_player_id uuid, p_mode text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare v_host uuid; v_mode text;
begin
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  v_mode := btrim(coalesce(p_mode, ''));
  if v_mode not in ('original','teleport','reverse') then raise exception 'invalid_mode'; end if;

  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_lobby_topic(p_lobby_id uuid, p_me_player_id uuid, p_topic text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare v_host uuid; v_topic text;
begin
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  v_topic := btrim(coalesce(p_topic, ''));
  if length(v_topic) > 60 then raise exception 'topic_too_long'; end if;

  update public.lobbies
  set topic = nullif(v_topic, ''),
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.set_max_players(p_lobby_id uuid, p_me_player_id uuid, p_max_players integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare v_host uuid; v_active_count int;
begin
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  if p_max_players < 2 or p_max_players > 12 then raise exception 'invalid_max_players'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = p_lobby_id and status = 'active';

  if p_max_players < v_active_count then raise exception 'too_small_for_current_players'; end if;

  update public.lobbies
  set max_players = p_max_players,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.sync_profile_verification()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  update public.profiles p
  set email = new.email,
      email_verified_at = new.email_confirmed_at,
      phone = new.phone,
      phone_verified_at = new.phone_confirmed_at
  where p.id = new.id;
  return new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.transfer_host(p_lobby_id uuid, p_me_player_id uuid, p_new_host_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_ok boolean;
begin
  select l.host_player_id into v_host from public.lobbies l where l.id = p_lobby_id;
  if v_host is null or v_host <> p_me_player_id then raise exception 'not_host'; end if;

  select exists (
    select 1 from public.players p
    where p.lobby_id = p_lobby_id and p.player_id = p_new_host_player_id and p.status = 'active'
  ) into v_ok;

  if not v_ok then raise exception 'new_host_not_active'; end if;

  update public.lobbies set host_player_id = p_new_host_player_id where id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.user_has_lobby_admin_access(p_user_id uuid, p_lobby_id uuid, p_min_role text)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_role text;
begin
  select las.role into v_role
  from public.lobby_admin_sessions las
  where las.user_id = p_user_id and las.lobby_id = p_lobby_id and las.is_active = true
  limit 1;

  if v_role is null then return false; end if;

  if p_min_role = 'qa' then return v_role in ('qa','moderator','admin','owner');
  elseif p_min_role = 'moderator' then return v_role in ('moderator','admin','owner');
  elseif p_min_role = 'admin' then return v_role in ('admin','owner');
  elseif p_min_role = 'owner' then return v_role = 'owner';
  end if;

  return false;
end;
$function$;


-- ============================================================
-- HINWEIS — weitere Funktionen die im Dump auftauchen aber im
-- aktuellen Frontend NICHT verwendet werden:
--
-- LEGACY (anderes Schema, vermutlich aus älteren Iterationen):
--   begin_round, boom, pass_potato(2x), start_game(3x),
--   start_lobby, start_round, start_game_by_code,
--   leave_lobby(2x), kick_player(p_lobby_id, p_target_player_id)
--   end_lobby, reset_lobby
--
-- INTERNAL / TRIGGERS:
--   rls_auto_enable, set_lobby_timestamps, set_ready,
--   set_updated_at, tg_set_updated_at, touch_lobby_activity_by_code,
--   trg_clear_lobby_on_player_leave, trg_reconcile_after_exit,
--   trg_reconcile_on_player_change, cleanup_lobby_if_empty,
--   end_lobby_if_host_left, reconcile_lobby_after_exit,
--   rpc_reconcile_lobby, rpc_eliminate_player, rpc_clear_lobby_to_waiting,
--   rpc_restart_game, rpc_ready_up, rpc_rematch_1v1, rpc_reset_lobby,
--   rpc_schedule_next_explosion, cleanup_expired_lobbies
--
-- Diese sind Helper / Trigger / Legacy — können bleiben.
-- ============================================================
