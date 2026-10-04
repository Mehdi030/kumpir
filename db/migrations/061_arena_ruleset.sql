-- ============================================================
-- Migration 061: "Kumpir Arena" -- Wettbewerbs-Regelwerk
-- ============================================================
-- Ziel: schneller werdendes, faires Duell-Format rund um Songs erraten.
--
--  1) TEMPO-STUFEN: Die Zündschnur wird mit jeder Eliminierung deutlich
--     kürzer (-6 % pro Runde, Boden bei 45 %; vorher -3 %/Boden 65 %).
--  2) DUELL-FINALE: Bei nur noch 2 Lebenden ist die Schnur 20 % kürzer
--     und Pässe geben KEINE Bonuszeit mehr -- das Finale ist ein
--     reines Nervenspiel.
--  3) QUALITÄTS-BONUS: Die Bonuszeit pro Pass hängt von der Antwort ab:
--     Songtitel = volle Bonuszeit, Interpret = halbe Bonuszeit. Wer den
--     Titel weiß, wird mit mehr Zeit belohnt (Titel > Interpret).
--  4) SONG-TAUSCH (Joker): Jeder Spieler darf pro Match EINMAL seinen
--     Song gegen einen neuen tauschen (kostet 2s Zündschnur, nur wenn
--     noch >3s übrig sind). Gleicht Pech bei der Songziehung aus.
--  5) FAIRE SITZORDNUNG: Zu Matchbeginn werden die Sitzplätze zufällig
--     gemischt -- wer zuerst beigetreten ist (Host), hat keinen festen
--     Vorteil/Nachteil in der Weitergabe-Reihenfolge mehr.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_pass_quality numeric NOT NULL DEFAULT 1;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS skips_left int NOT NULL DEFAULT 1;
-- NUR die neue Spalte freigeben (kein Tabellen-GRANT -- siehe Migration 056).
GRANT SELECT (skips_left) ON public.players TO anon, authenticated;
GRANT SELECT ON public.lobbies TO anon, authenticated;

-- ------------------------------------------------------------
-- 1+2) Zündschnur: Tempo-Stufen + Duell
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calc_explode_seconds(p_round_speed text, p_alive_count integer, p_round_number integer, p_exponent numeric DEFAULT 1.9, p_quantize_step_sec numeric DEFAULT 0.5, p_clamp_min_sec numeric DEFAULT 3)
 RETURNS numeric
 LANGUAGE plpgsql
AS $function$
declare
  base_min numeric;
  base_max numeric;
  scale_alive numeric;
  scale_round numeric;
  scale_duel numeric := 1.0;
  min_sec numeric;
  max_sec numeric;
  u numeric;
  biased numeric;
  raw numeric;
  quantized numeric;
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

  -- Tempo-Stufen: -6 % pro Eliminierung, nicht unter 45 %.
  scale_round := greatest(0.45, 1.0 - greatest(0, (p_round_number - 1)) * 0.06);

  -- Duell-Finale: bei 2 Lebenden 20 % kürzer.
  if p_alive_count <= 2 then scale_duel := 0.8; end if;

  min_sec := greatest(p_clamp_min_sec, base_min * scale_alive * scale_round * scale_duel);
  max_sec := greatest(min_sec + 1, base_max * scale_alive * scale_round * scale_duel);

  u := random();
  biased := power(u, p_exponent);
  raw := min_sec + biased * (max_sec - min_sec);

  quantized := round(raw / p_quantize_step_sec) * p_quantize_step_sec;

  return greatest(p_clamp_min_sec, quantized);
end;
$function$;

-- ------------------------------------------------------------
-- 3) Qualität der Antwort merken (Titel 1.0 / Interpret 0.5)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at into v_last_wrong
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist into v_song_title, v_song_artist
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      v_points := 0.5;
      v_known := true;
    end if;

    if not v_known then
      update public.players set last_wrong_guess_at = now()
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    v_quality := v_points;

    update public.players
    set song_points = song_points + v_points
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ------------------------------------------------------------
-- 2+3) Bonuszeit: Qualität skaliert, im Duell keine
-- ------------------------------------------------------------
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
  v_quality numeric;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number, coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at), coalesce(l.last_pass_quality, 1)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number, v_bonus_used, v_since, v_quality
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
  -- Titel = volle Bonuszeit, Interpret = halbe; im Duell (2 Lebende) keine.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second'),
      round_bonus_used = v_bonus_used + v_bonus_applied,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

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

-- ------------------------------------------------------------
-- 4) Song-Tausch-Joker
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_skip_song(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_skips int;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_song_id is null then raise exception 'no_song'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  select skips_left into v_skips from public.players
  where lobby_id = v_lobby.id and player_id = p_player_id;
  if coalesce(v_skips, 0) <= 0 then raise exception 'no_skips_left'; end if;

  if v_lobby.explode_at is null or v_lobby.explode_at - now() < interval '3 seconds' then
    raise exception 'too_late';
  end if;

  update public.players set skips_left = skips_left - 1
  where lobby_id = v_lobby.id and player_id = p_player_id;

  update public.lobbies
  set explode_at = explode_at - interval '2 seconds', last_activity_at = now()
  where id = v_lobby.id;

  perform public._pick_next_song(v_lobby.id);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_skip_song(text, uuid) TO anon, authenticated;

-- ------------------------------------------------------------
-- 5) Matchstart: Sitze mischen, Joker auffüllen
-- ------------------------------------------------------------
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
  -- (unique_seat_per_lobby gilt für ALLE Zeilen der Lobby inkl. gegangener
  -- Spieler -> nur innerhalb der bereits belegten Plätze permutieren, in
  -- zwei Schritten über temporär negative Werte.)
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
      used_song_ids = '{}',
      current_attempt_id = null,
      round_bonus_used = 0,
      last_pass_quality = 1,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

COMMIT;
