-- ============================================================
-- Migration 073: Austritt ohne Spielabbruch, Bot-Balance, Song-Schwierigkeit, Aufräumen
-- ============================================================
-- Aus der Spiel-Simulation:
--  1) Wenn irgendwer die Lobby verließ, setzte ein Trigger die Lobby für ALLE auf "waiting"
--     zurück (Match + Ergebnisse weg). Neu: der Austritt wird wie eine Eliminierung behandelt,
--     das Spiel läuft weiter (siehe _on_player_exit).
--  2) Host weg -> bevorzugt der nächste MENSCH wird Host (nicht ein Bot).
--  3) Spiel endet bei <=1 Lebenden immer über _finish_round (Rundenergebnis, Saison-Punkte,
--     Mehr-Runden-Match läuft korrekt weiter).
--  4) Bot-Balance: Abstand Anfänger/Mittel/Profi verkleinert.
--  5) Song-Schwierigkeit: geglättete Trefferquote (kein "erst ab 5 Spielen"), nur Menschen
--     zählen (Bots verfälschten die Statistik); bisherige Zahlen zurückgesetzt.
--  6) Host-Kick und Austritt berücksichtigen die Weitergabe-Richtung (gemeinsame Funktion).
--  7) Tote Alt-Funktionen entfernt.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 4) Bot-Balance
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bot_survival(p_round integer, p_skill integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case coalesce(p_skill, 2)
    when 1 then greatest(0.08, public._bot_survival(p_round) * 0.85)
    when 3 then greatest(0.30, 0.92 - (greatest(coalesce(p_round, 1), 1) - 1) * 0.14)
    else public._bot_survival(p_round)
  end;
$function$;

-- ------------------------------------------------------------
-- 5) Song-Schwierigkeit
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._song_difficulty(p_plays integer, p_hits integer)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
AS $function$
  -- geglättet (Prior: 4 Pseudo-Spiele bei 50 %): wenige Daten bleiben "mittel", echte Ausreißer
  -- kippen nach wenigen Runden Richtung leicht/schwer.
  select case
    when (coalesce(p_hits, 0) + 2.0) / (coalesce(p_plays, 0) + 4.0) >= 0.6 then 1
    when (coalesce(p_hits, 0) + 2.0) / (coalesce(p_plays, 0) + 4.0) >= 0.3 then 2
    else 3
  end::smallint;
$function$;

UPDATE public.song_pool SET plays = 0, hits = 0;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
  v_plays int; v_hits int; v_holder uuid; v_holder_is_bot boolean;
begin
  select topic_selected, used_song_ids, current_song_id, holder_player_id
    into v_topic, v_used, v_current, v_holder
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
    -- Nur Songs, die ein MENSCH vor sich hat, zählen für die Schwierigkeits-Statistik.
    select coalesce(is_bot, false) into v_holder_is_bot
    from public.players where lobby_id = p_lobby_id and player_id = v_holder;
    if coalesce(v_holder_is_bot, false) then
      select plays, hits into v_plays, v_hits from public.song_pool where id = v_song_id;
    else
      update public.song_pool set plays = plays + 1 where id = v_song_id
      returning plays, hits into v_plays, v_hits;
    end if;
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      current_song_started_at = case when v_song_id is null then null else now() end,
      current_song_difficulty = public._song_difficulty(v_plays, v_hits),
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

-- rpc_attempt_pass: Treffer nur zählen, wenn ein Mensch geantwortet hat
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
  v_is_bot boolean;
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
    select last_wrong_guess_at, combo, coalesce(is_bot, false) into v_last_wrong, v_combo, v_is_bot
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
      if not coalesce(v_is_bot, false) then
        update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
      end if;
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

-- ------------------------------------------------------------
-- 1) + 6) Gemeinsame Eliminierung während der Runde (Kick, Austritt)
-- ------------------------------------------------------------
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

-- Host-Kick mitten in der Runde nutzt dieselbe Funktion (jetzt richtungsbewusst)
CREATE OR REPLACE FUNCTION public.rpc_host_kick_during_round(p_code text, p_host_player_id uuid, p_target_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
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

  perform public._remove_from_round(v_lobby.id, p_target_player_id);
end;
$function$;

-- ------------------------------------------------------------
-- 1) + 2) Austritt: Spiel läuft weiter
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._on_player_exit(p_lobby_id uuid, p_player_id uuid, p_was_alive boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phase text; v_code text; v_host uuid; v_new_host uuid;
  v_humans int; v_active int; v_survivor uuid;
begin
  select phase, code, host_player_id into v_phase, v_code, v_host
  from public.lobbies where id = p_lobby_id for update;
  if not found then return; end if;

  select count(*) filter (where not coalesce(is_bot, false)), count(*)
    into v_humans, v_active
  from public.players where lobby_id = p_lobby_id and status = 'active';

  -- Host weg -> nächster Mensch
  if v_host is null or not exists (
    select 1 from public.players where lobby_id = p_lobby_id and player_id = v_host and status = 'active'
  ) then
    select player_id into v_new_host from public.players
    where lobby_id = p_lobby_id and status = 'active' and not coalesce(is_bot, false)
    order by joined_at asc limit 1;
    if v_new_host is not null then
      update public.lobbies set host_player_id = v_new_host, last_activity_at = now() where id = p_lobby_id;
    end if;
  end if;

  -- Nur noch Bots (oder niemand): Lobby zurücksetzen
  if v_humans = 0 then
    if v_phase <> 'waiting' then perform public.rpc_reset_lobby(v_code); end if;
    return;
  end if;

  if v_phase = 'topic_vote' then
    delete from public.topic_votes where lobby_id = p_lobby_id and player_id = p_player_id;
    if v_active < 2 then perform public.rpc_reset_lobby(v_code); end if;

  elsif v_phase = 'countdown' then
    if v_active < 2 then perform public.rpc_reset_lobby(v_code); end if;

  elsif v_phase = 'running' then
    perform public._remove_from_round(p_lobby_id, p_player_id, p_was_alive);

  elsif v_phase = 'set_summary' then
    -- Zwischenstand: bleibt nur noch einer, ist das Match vorbei
    if v_active < 2 then
      select player_id into v_survivor from public.players
      where lobby_id = p_lobby_id and status = 'active' limit 1;
      update public.lobbies
      set phase = 'finished', explode_at = null, current_song_id = null, current_attempt_id = null,
          holder_player_id = v_survivor, last_activity_at = now()
      where id = p_lobby_id;
    end if;
  end if;
  -- waiting / finished / rematch_wait: nichts weiter -- die Ergebnisse bleiben stehen.
end;
$function$;

CREATE OR REPLACE FUNCTION public._trg_player_exit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' then
    if old.status = 'active' and new.status in ('left', 'kicked') then
      perform public._on_player_exit(new.lobby_id, new.player_id, coalesce(new.is_alive, false));
    end if;
  elsif tg_op = 'DELETE' then
    if old.status = 'active' then
      perform public._on_player_exit(old.lobby_id, old.player_id, coalesce(old.is_alive, false));
    end if;
  end if;
  return null;
end;
$function$;

-- Alte Reset-Trigger entfernen, neuen setzen
DROP TRIGGER IF EXISTS trg_players_reconcile_on_status ON public.players;
DROP TRIGGER IF EXISTS trg_players_reconcile_after_exit ON public.players;
DROP TRIGGER IF EXISTS trg_players_clear_on_status_leave ON public.players;
DROP TRIGGER IF EXISTS trg_players_reconcile_on_delete ON public.players;
DROP TRIGGER IF EXISTS trg_players_clear_on_delete ON public.players;

DROP TRIGGER IF EXISTS trg_player_exit_update ON public.players;
CREATE TRIGGER trg_player_exit_update
  AFTER UPDATE OF status ON public.players
  FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status)
  EXECUTE FUNCTION public._trg_player_exit();
DROP TRIGGER IF EXISTS trg_player_exit_delete ON public.players;
CREATE TRIGGER trg_player_exit_delete
  AFTER DELETE ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_player_exit();

-- Host-Nachfolge beim Löschen: bevorzugt Menschen
CREATE OR REPLACE FUNCTION public.end_lobby_if_host_left()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_new_host uuid;
begin
  if exists (select 1 from public.lobbies l where l.id = old.lobby_id and l.host_player_id = old.player_id) then
    select p.player_id into v_new_host
    from public.players p
    where p.lobby_id = old.lobby_id and p.status = 'active' and p.player_id <> old.player_id
    order by coalesce(p.is_bot, false) asc, p.joined_at asc
    limit 1;

    if v_new_host is not null then
      update public.lobbies set host_player_id = v_new_host, last_activity_at = now() where id = old.lobby_id;
    end if;
  end if;
  return null;
end;
$function$;

-- ------------------------------------------------------------
-- 7) Tote Alt-Funktionen entfernen
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.trg_clear_lobby_on_player_leave();
DROP FUNCTION IF EXISTS public.trg_reconcile_after_exit();
DROP FUNCTION IF EXISTS public.trg_reconcile_on_player_change();
DROP FUNCTION IF EXISTS public.reconcile_lobby_after_exit(uuid);
DROP FUNCTION IF EXISTS public.rpc_reconcile_lobby(uuid);
DROP FUNCTION IF EXISTS public.rpc_create_lobby(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.rpc_create_lobby(text, text, integer, integer, uuid);
DROP FUNCTION IF EXISTS public.rpc_start_game(uuid);
DROP FUNCTION IF EXISTS public.rpc_start_game(text);
DROP FUNCTION IF EXISTS public.rpc_start_game(uuid, uuid);
DROP FUNCTION IF EXISTS public.start_game(text, uuid);
DROP FUNCTION IF EXISTS public.start_game(uuid);
DROP FUNCTION IF EXISTS public.set_ready(uuid, boolean);
DROP FUNCTION IF EXISTS public.rpc_ready_up(text, uuid);
DROP FUNCTION IF EXISTS public.rpc_eliminate_player(uuid, uuid);
DROP FUNCTION IF EXISTS public.rpc_restart_game(uuid, uuid);
DROP FUNCTION IF EXISTS public.kick_player(uuid, uuid);
DROP FUNCTION IF EXISTS public.leave_lobby(uuid, uuid);
DROP FUNCTION IF EXISTS public.leave_lobby(uuid);
DROP FUNCTION IF EXISTS public.rpc_rematch_1v1(uuid);
DROP FUNCTION IF EXISTS public.rpc_schedule_next_explosion(uuid);

COMMIT;
