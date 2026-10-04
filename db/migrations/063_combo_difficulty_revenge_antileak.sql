-- ============================================================
-- Migration 063: Combo, Song-Schwierigkeit, Rache-Pass, Anti-Leak
-- ============================================================
--  1) ANTI-LEAK (wichtig für Fairness): song_pool.title / artist /
--     lower_title waren für JEDEN Client per API lesbar -- wer die
--     Browser-Konsole öffnete, konnte die Lösung des laufenden Songs
--     nachschlagen. Jetzt nur noch Spalten ohne Lösung freigegeben.
--  2) COMBO: Titel-Treffer in Folge geben Extra-Bonuszeit (+0.5s pro
--     weiterem Treffer, max +2s). Interpret-Treffer oder Fehlversuch
--     setzen die Combo zurück.
--  3) SCHWIERIGKEIT: adaptiv aus echten Daten (Trefferquote Titel pro
--     Ziehung, ab 5 Ziehungen): leicht x0.8, mittel x1.0, schwer x1.3
--     auf die Bonuszeit. Sichtbar als Sterne beim Halter.
--  4) RACHE-PASS: Wer ausgeschieden ist, darf EINMAL pro Durchgang die
--     Weitergabe-Richtung drehen (rpc_revenge_flip).
-- ============================================================

BEGIN;

-- ---------- 1) Anti-Leak ----------
ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS plays int NOT NULL DEFAULT 0;
ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS hits int NOT NULL DEFAULT 0;

REVOKE SELECT ON public.song_pool FROM anon, authenticated;
GRANT SELECT (id, topic_pool_id, created_at, preview_url, preview_checked_at) ON public.song_pool TO anon, authenticated;

-- ---------- Spalten ----------
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS combo int NOT NULL DEFAULT 0;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS revenge_used boolean NOT NULL DEFAULT false;
GRANT SELECT (combo, revenge_used) ON public.players TO anon, authenticated;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_pass_diff numeric NOT NULL DEFAULT 1;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_pass_combo_bonus numeric NOT NULL DEFAULT 0;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS current_song_difficulty smallint NOT NULL DEFAULT 2;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS revenge_nonce int NOT NULL DEFAULT 0;
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS last_revenge_by uuid;
GRANT SELECT ON public.lobbies TO anon, authenticated;

-- Combo/Rache-Pass pro Durchgang zurücksetzen (jedes neue Themen-Voting
-- = neuer Durchgang) und beim Zurück-in-die-Lobby / Rematch.
CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
 AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from NEW.phase then
    update public.players set combo = 0, revenge_used = false where lobby_id = NEW.id;
    NEW.pass_direction := 1;
  end if;
  return NEW;
end;
$function$;

-- ---------- 3) Schwierigkeit ----------
CREATE OR REPLACE FUNCTION public._song_difficulty(p_plays int, p_hits int)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when coalesce(p_plays, 0) < 5 then 2
    when p_hits::numeric / p_plays >= 0.6 then 1
    when p_hits::numeric / p_plays >= 0.3 then 2
    else 3
  end::smallint;
$function$;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
  v_plays int; v_hits int;
begin
  select topic_selected, used_song_ids, current_song_id into v_topic, v_used, v_current
  from public.lobbies where id = p_lobby_id;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null, current_song_started_at = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  if v_song_id is not null then
    update public.song_pool set plays = plays + 1 where id = v_song_id
    returning plays, hits into v_plays, v_hits;
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      current_song_started_at = case when v_song_id is null then null else now() end,
      current_song_difficulty = public._song_difficulty(v_plays, v_hits),
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

-- ---------- 2+3) Antwort prüfen: Combo + Schwierigkeit ----------
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
  v_plays int; v_hits int;
  v_points numeric;
  v_known boolean;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
  v_diff numeric := 1;
  v_combo int := 0;
  v_combo_bonus numeric := 0;
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
    select last_wrong_guess_at, combo into v_last_wrong, v_combo
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist, plays, hits into v_song_title, v_song_artist, v_plays, v_hits
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
      update public.players set last_wrong_guess_at = now(), combo = 0
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    v_quality := v_points;
    v_diff := case public._song_difficulty(v_plays, v_hits) when 1 then 0.8 when 3 then 1.3 else 1.0 end;

    if v_points = 1 then
      v_combo := coalesce(v_combo, 0) + 1;
      v_combo_bonus := case when v_combo >= 2 then least(2, 0.5 * (v_combo - 1)) else 0 end;
      update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
    else
      v_combo := 0;
    end if;

    update public.players
    set song_points = song_points + v_points, combo = v_combo
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality,
      last_pass_diff = v_diff, last_pass_combo_bonus = v_combo_bonus
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ---------- Nächster lebender Spieler in Richtung ----------
CREATE OR REPLACE FUNCTION public._next_alive(p_lobby_id uuid, p_from uuid, p_dir int)
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

-- ---------- Weitergabe: Qualität x Schwierigkeit + Combo, Richtung ----------
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
  v_quality numeric; v_diff numeric; v_combo_bonus numeric;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number,
         coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at),
         coalesce(l.last_pass_quality, 1), coalesce(l.last_pass_diff, 1), coalesce(l.last_pass_combo_bonus, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number,
         v_bonus_used, v_since, v_quality, v_diff, v_combo_bonus
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

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second'),
      round_bonus_used = v_bonus_used + v_bonus_applied,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
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

-- ---------- Tick/Kick: Richtung beachten ----------
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
  if v_now < v_explode_at then return; end if;

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

-- ---------- 4) Rache-Pass ----------
CREATE OR REPLACE FUNCTION public.rpc_revenge_flip(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_alive int;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then raise exception 'invalid_session'; end if;
  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.game_mode <> 'original' then raise exception 'mode_not_supported'; end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby.id and player_id = p_player_id and status = 'active'
      and is_alive = false and eliminated_at_round is not null and revenge_used = false
  ) then raise exception 'no_revenge_available'; end if;

  select count(*) into v_alive from public.players
  where lobby_id = v_lobby.id and status = 'active' and is_alive = true;
  if v_alive <= 2 then raise exception 'duel_no_revenge'; end if;

  update public.players set revenge_used = true
  where lobby_id = v_lobby.id and player_id = p_player_id;

  update public.lobbies
  set pass_direction = (coalesce(pass_direction, 1) * -1)::smallint,
      revenge_nonce = revenge_nonce + 1,
      last_revenge_by = p_player_id,
      last_activity_at = now()
  where id = v_lobby.id;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_revenge_flip(text, uuid) TO anon, authenticated;

COMMIT;
