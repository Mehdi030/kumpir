-- ============================================================
-- Migration 060: Pass-/Haltezeit = Zeit seit ERHALT der Kartoffel
-- ============================================================
-- rpc_pass_potato maß v_pass_ms bisher als Zeit seit dem EIGENEN letzten
-- Pass (beim ersten Pass: seit Rundenstart). Das schloss die komplette
-- Wartezeit ein, in der andere Spieler dran waren -- im Ende-Screen
-- standen dadurch "Fastest Pass"-Werte von 47-56 Sekunden, "Fastest" und
-- "Slowest" waren bei nur einem Pass identisch, und "Longest Hold" war
-- einfach "wer hat am längsten überlebt".
--
-- Neu: lobbies.holder_since wird per Trigger bei JEDEM Halterwechsel auf
-- now() gesetzt. rpc_pass_potato liest es vor dem Wechsel und misst damit
-- die echte Haltezeit (Kartoffel erhalten -> abgegeben). Fastest/Slowest/
-- Longest Hold bekommen dadurch wieder ihre eigentliche Bedeutung.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS holder_since timestamptz;
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._set_holder_since()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.holder_player_id is distinct from OLD.holder_player_id then
    NEW.holder_since := case when NEW.holder_player_id is null then null else now() end;
  end if;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_set_holder_since ON public.lobbies;
CREATE TRIGGER lobbies_set_holder_since
  BEFORE UPDATE OF holder_player_id ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._set_holder_since();

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
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number, coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number, v_bonus_used, v_since
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
    next_idx := idx + 1;
    if next_idx > n then next_idx := 1; end if;
    v_next := alive_ids[next_idx];
  end if;

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

  -- Haltezeit = von Erhalt der Kartoffel (holder_since) bis jetzt.
  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;
