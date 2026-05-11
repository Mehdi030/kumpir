-- ============================================================
-- Migration 009: Balance-Fixes — Fair Timer + Modi + Round-Speed
-- ============================================================
-- Drei zusammenhängende Bug-Fixes für ein faires Spielerlebnis:
--
-- 1) FAIR-TIMER: Nach einem Pass hat der nächste Halter MINDESTENS 1.5s
--    bevor die Bombe explodieren kann. Vorher konnte man die Kartoffel
--    300ms vor Ablauf weiterreichen — der nächste war praktisch tot.
--
-- 2) MODI BALANCE: rpc_pass_potato hat Teleport JEDEN Pass ausgelöst
--    und Reverse JEDEN Pass die Richtung geflippt. Das ist Chaos statt
--    Strategie. Jetzt: Teleport mit 30% Chance, Reverse mit 25%.
--
-- 3) ROUND-SPEED: rpc_tick_game hatte explode_at hartcoded auf 15s,
--    rpc_advance_from_countdown auf 25s. Beide ignorierten die
--    round_speed Einstellung. Jetzt: calc_explode_seconds() wird genutzt,
--    abhängig von round_speed + alive_count + round_number.
-- ============================================================

BEGIN;

-- ============================================================
-- rpc_pass_potato — fair timer + balanced modes
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_lobby_id    uuid;
  v_mode        text;
  v_holder      uuid;
  v_dir         smallint;
  v_explode_at  timestamptz;

  alive_ids     uuid[];
  n             int;
  idx           int;
  next_idx      int;
  v_next        uuid;

  v_now         timestamptz := now();
  v_last_pass   timestamptz;
  v_pass_ms     int;
  v_clutch      int := 0;
  v_ms_left     int;

  -- Fair-Timer: nächster Halter bekommt mindestens 1.5s
  v_min_hold    interval := interval '1.5 seconds';

  -- Mode-Trigger-Wahrscheinlichkeiten
  v_teleport_chance numeric := 0.30;
  v_reverse_chance  numeric := 0.25;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
  from public.lobbies l
  where l.code = upper(p_code)
  for update;

  if v_lobby_id is null then
    raise exception 'Lobby not found';
  end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id  = v_lobby_id
      and p.player_id = p_player_id
      and p.status    = 'active'
      and p.is_alive  = true
  ) then
    raise exception 'Player not active/alive';
  end if;

  select array_agg(p.player_id order by p.seat_index)
    into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id
    and p.status   = 'active'
    and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- ============================================================
  -- Mode-Logik mit Wahrscheinlichkeiten (statt jeden Pass)
  -- ============================================================
  if v_mode = 'teleport' and random() < v_teleport_chance then
    -- Teleport: zufälliger lebender Spieler (nicht der aktuelle Halter)
    select p.player_id into v_next
    from public.players p
    where p.lobby_id  = v_lobby_id
      and p.status    = 'active'
      and p.is_alive  = true
      and p.player_id <> p_player_id
    order by random()
    limit 1;

    if v_next is null then
      -- Fallback: linear
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
      v_next := alive_ids[next_idx];
    end if;

  elsif v_mode = 'reverse' and random() < v_reverse_chance then
    -- Reverse: Richtung flippen UND einen Step in die neue Richtung
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
    -- Default: linear in aktueller Richtung
    -- (Reverse-Modus ohne Flip: aktuelle Richtung beibehalten)
    if v_mode = 'reverse' then
      if coalesce(v_dir, 1) = 1 then
        next_idx := idx + 1;
        if next_idx > n then next_idx := 1; end if;
      else
        next_idx := idx - 1;
        if next_idx < 1 then next_idx := n; end if;
      end if;
    else
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  -- ============================================================
  -- FAIR-TIMER: nächster Halter bekommt min. 1.5s
  -- ============================================================
  update public.lobbies
  set holder_player_id = v_next,
      explode_at       = greatest(v_explode_at, v_now + v_min_hold),
      last_activity_at = v_now
  where id = v_lobby_id;

  -- ============================================================
  -- Stats für den vorigen Halter
  -- ============================================================
  select last_pass_at into v_last_pass
  from public.players
  where lobby_id  = v_lobby_id
    and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms
    from public.lobbies
    where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  -- Clutch wenn weniger als 2 Sek übrig waren
  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then
      v_clutch := 1;
    end if;
  end if;

  update public.players
  set
    pass_count        = coalesce(pass_count, 0) + 1,
    last_pass_at      = v_now,
    total_hold_ms     = coalesce(total_hold_ms, 0) + v_pass_ms,
    fastest_pass_ms   = case
                          when fastest_pass_ms is null then v_pass_ms
                          when v_pass_ms < fastest_pass_ms then v_pass_ms
                          else fastest_pass_ms
                        end,
    clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id  = v_lobby_id
    and player_id = p_player_id;

end;
$function$;


-- ============================================================
-- rpc_tick_game — nutze calc_explode_seconds für faire nächste Runde
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_now         timestamptz := now();

  v_lobby_id    uuid;
  v_phase       text;
  v_holder      uuid;
  v_explode_at  timestamptz;
  v_game_mode   text;
  v_round_speed text;
  v_round_num   int;

  v_alive_count int;
  v_loser       uuid;
  v_next_holder uuid;
  v_next_seconds numeric;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, round_number
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_round_num
  from public.lobbies
  where code = upper(p_code)
  for update;

  if v_lobby_id is null then
    raise exception 'Lobby not found';
  end if;

  if v_phase is distinct from 'running' then
    return;
  end if;

  if v_explode_at is null then
    return;
  end if;

  if v_now < v_explode_at then
    return;
  end if;

  v_loser := v_holder;
  if v_loser is null then
    return;
  end if;

  -- Loser eliminieren
  update public.players
  set is_alive        = false,
      survival_streak = 0
  where lobby_id  = v_lobby_id
    and player_id = v_loser;

  -- Streak für alle noch lebenden erhöhen
  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id
    and status   = 'active'
    and is_alive = true;

  -- Runde hochzählen + Loser merken
  update public.lobbies
  set round_number         = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at     = v_now,
      used_answers         = '{}'  -- neue Runde, Antworten reset
  where id = v_lobby_id;

  -- Alive-Count
  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id
    and status   = 'active'
    and is_alive = true;

  -- Letzter überlebender → finished
  if v_alive_count <= 1 then
    update public.lobbies
    set phase            = 'finished',
        explode_at       = null,
        holder_player_id = (
          select player_id
          from public.players
          where lobby_id = v_lobby_id
            and status   = 'active'
            and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster Holder: bei Teleport zufällig, sonst nächster seat_index
  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id
      and status   = 'active'
      and is_alive = true
      and player_id <> v_loser
    order by random()
    limit 1;
  else
    -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
    select p2.player_id
      into v_next_holder
    from public.players p_loser
    join public.players p2
      on  p2.lobby_id   = p_loser.lobby_id
      and p2.status     = 'active'
      and p2.is_alive   = true
      and p2.seat_index > p_loser.seat_index
    where p_loser.lobby_id  = v_lobby_id
      and p_loser.player_id = v_loser
    order by p2.seat_index asc
    limit 1;

    -- Wrap: falls keiner mit höherem seat_index alive ist
    if v_next_holder is null then
      select player_id
        into v_next_holder
      from public.players
      where lobby_id = v_lobby_id
        and status   = 'active'
        and is_alive = true
      order by seat_index asc
      limit 1;
    end if;
  end if;

  -- Nächste explode_at: calc_explode_seconds basierend auf round_speed +
  -- alive_count + round_number — NICHT mehr hartcoded 15s.
  v_next_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_num, 0) + 1,
    1.9,
    0.5,
    3
  );

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at       = v_now + make_interval(secs => v_next_seconds),
      pass_direction   = case
                           when v_game_mode = 'reverse' and random() < 0.40
                           then (pass_direction * -1)::smallint
                           else pass_direction
                         end,
      current_attempt_id = null  -- attempt aus alter Runde aufräumen
  where id = v_lobby_id;

end;
$function$;


-- ============================================================
-- rpc_advance_from_countdown — nutze calc_explode_seconds
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_round_speed text;
  v_alive_count int;
  v_seconds numeric;
begin
  select round_speed
    into v_round_speed
  from public.lobbies
  where id = p_lobby_id;

  select player_id
    into v_holder
  from public.players
  where lobby_id = p_lobby_id
    and status = 'active'
    and is_alive = true
  order by random()
  limit 1;

  if v_holder is null then
    raise exception 'Kein Startspieler gefunden';
  end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id
    and status = 'active'
    and is_alive = true;

  v_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    1,
    1.9,
    0.5,
    3
  );

  update public.lobbies
  set
    phase = 'running',
    holder_player_id = v_holder,
    run_started_at = now(),
    explode_at = now() + make_interval(secs => v_seconds),
    countdown_started_at = null,
    countdown_ends_at = null,
    last_activity_at = now(),
    used_answers = '{}',
    current_attempt_id = null
  where id = p_lobby_id
    and phase = 'countdown';
end;
$function$;


-- ============================================================
-- View: public_lobbies_view — Anzeige im Hauptmenü
-- ============================================================
-- Nur wartende Public-Lobbies mit grundlegenden Infos.
CREATE OR REPLACE VIEW public.public_lobbies_view AS
SELECT
    l.code,
    l.max_players,
    l.game_mode,
    l.round_speed,
    l.created_at,
    (
        SELECT COUNT(*)
        FROM public.players p
        WHERE p.lobby_id = l.id AND p.status = 'active'
    ) AS player_count
FROM public.lobbies l
WHERE l.privacy = 'public'
  AND l.phase IN ('waiting', 'lobby')
  AND l.locked = FALSE
  AND l.last_activity_at > NOW() - INTERVAL '30 minutes'
ORDER BY l.created_at DESC
LIMIT 20;

GRANT SELECT ON public.public_lobbies_view TO anon, authenticated;


COMMIT;
