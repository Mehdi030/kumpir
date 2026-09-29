-- ============================================================
-- Migration 032: Grace-Bonus auf den Explosions-Timer bei jedem Pass
-- ============================================================
-- Bisher galt: explode_at wird nur EINMAL pro Runde gesetzt (Rundenstart
-- oder nach einer Explosion) und bleibt beim Weiterreichen der Kartoffel
-- unverändert -- wer die Kartoffel kurz vor Ablauf bekommt, kann quasi
-- ohne jede Chance sofort explodieren, egal wie schnell er reagiert.
--
-- Live-Feedback: bei jedem erfolgreichen Pass soll der Timer um ein paar
-- Sekunden VERLÄNGERT werden (nicht komplett zurückgesetzt) -- Beispiel:
-- Bombe hätte in 10s explodiert, Antwort kommt bei 3s Restzeit rein,
-- Bonus +2s -> 5s Restzeit für den nächsten Halter. Reagiert der wiederum
-- nach 1s (4s Restzeit), bekommt der übernächste 4s + 2s = 6s. Der Bonus
-- soll mit steigender Rundenzahl kleiner werden, damit das Spiel gegen
-- Ende (jeder war schon mehrfach dran) spürbar schneller/härter wird --
-- dieselbe Idee wie der bestehende scale_round-Faktor in
-- calc_explode_seconds, nur eigens für den Pass-Bonus statt die Basis-
-- Rundendauer.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.calc_pass_bonus_seconds(p_round_number integer)
    RETURNS numeric LANGUAGE sql IMMUTABLE
AS $function$
    SELECT CASE
        WHEN coalesce(p_round_number, 1) <= 2 THEN 4
        WHEN p_round_number <= 4 THEN 3
        WHEN p_round_number <= 6 THEN 2
        ELSE 1
    END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number
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

  -- Grace-Bonus: Timer wird bei jedem erfolgreichen Pass um ein paar
  -- Sekunden verlängert statt unverändert zu bleiben. GREATEST(..., now())
  -- als Basis statt einfach v_explode_at + Bonus, damit ein durch Client-
  -- Polling-Lag bereits abgelaufener Timer dem nächsten Halter trotzdem
  -- die volle Bonuszeit gibt statt einer Negativ-Restzeit + Bonus.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number);

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_seconds * interval '1 second'),
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
