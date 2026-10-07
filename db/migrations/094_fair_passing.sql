-- ============================================================
-- 094: Faires Weitergeben (Wunsch Mehdi, 2026-10-07, nach Fairness-Test)
-- ============================================================
-- Testlauf (db/scripts/test-fairness.mjs, 5 Matches, 78 Weitergaben) + Spielprotokoll echter Spieler:
--   * Menschen brauchen für eine richtige Antwort im Schnitt 5,6 s (in 4 s schaffen es nur 24 %,
--     in 6 s 54 %, in 7 s 71 %) – die Schutzzeit von min. 4 s war zu knapp.
--   * Ketten liefen endlos: im Blitz 25 Weitergaben hintereinander mit genau 4 s.
--   * Abgeben in letzter Sekunde wurde sogar belohnt (+10 Punkte pro "Clutch").
--   * Bots antworteten in 1,2–4 s, viel schneller als Menschen.
--
-- A) Schutzzeit: Blitz 6 s / Standard 7 s / Casual 8 s, jede weitere im selben Zug 1 s kürzer, nie unter 5 s.
-- B) Nachspielzeit: Sobald in einem Zug die Schutzzeit gegriffen hat (grace_count > 0), zählt bis zum
--    nächsten Knall nur noch der Songtitel – der Interpret reicht nicht mehr ('overtime_title_only',
--    ohne Fehlversuch-Sperre). So enden Ketten von selbst, für alle gleich.
-- C) Tempo-Bonus statt Clutch-Punkte: Wer innerhalb von 5 s abgibt (und nicht erst in den letzten 2 s
--    der Zündschnur), bekommt +5 Arena-Punkte (players.tempo_pass_count). Clutch zählt nur noch als
--    Statistik ("Rettungen in letzter Sekunde"), bringt keine Punkte mehr.
-- D) Bots menschlicher: Anfänger 4,5–7,5 s, Mittel 4–7 s (Profi bleibt schnell). In der Nachspielzeit
--    nennen Bots nur den Titel – und kennen ihn nicht immer (35/50/65 % je Stärke).
-- ============================================================
BEGIN;

-- ---------- A) Schutzzeit ----------
CREATE OR REPLACE FUNCTION public.calc_pass_grace_seconds(p_round_speed text, p_used int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(5,
    (CASE p_round_speed WHEN 'fast' THEN 6 WHEN 'calm' THEN 8 ELSE 7 END) - greatest(0, coalesce(p_used, 0))
  )::numeric;
$$;

-- ---------- C) Tempo-Abgaben zählen ----------
ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS tempo_pass_count int NOT NULL DEFAULT 0;

-- Wird pass_count für eine neue Runde/Revanche auf 0 gesetzt, Tempo-Abgaben mit zurücksetzen
-- (die vielen Reset-Funktionen müssen dafür nicht einzeln angefasst werden).
CREATE OR REPLACE FUNCTION public._trg_reset_tempo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF coalesce(NEW.pass_count, 0) = 0 THEN
    NEW.tempo_pass_count := 0;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS players_reset_tempo ON public.players;
CREATE TRIGGER players_reset_tempo BEFORE UPDATE ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_reset_tempo();

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

-- ---------- B) Nachspielzeit: nur der Titel zählt ----------
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
      -- Nachspielzeit (094): der Interpret ist richtig, reicht aber nicht -> kein Fehlversuch, nur Hinweis
      if coalesce(v_lobby.grace_count, 0) > 0 then
        raise exception 'overtime_title_only';
      end if;
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

-- ---------- D) Bots menschlicher + Nachspielzeit ----------
CREATE OR REPLACE FUNCTION public._bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_delay numeric;
  v_roll numeric;
  v_answer text;
  v_seed text;
  v_artist_chance numeric;
  v_base numeric; v_span numeric;
begin
  -- ---------- Themen-Voting ----------
  for r in
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at, l.topic_vote_cards
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % greatest(1, least(3, r.topic_vote_cards))))
      on conflict (lobby_id, player_id) do nothing;
    end if;
  end loop;

  -- ---------- Laufende Runde: Bot ist Halter ----------
  for r in
    select l.id, l.code, l.holder_player_id, l.holder_since, l.round_number, l.current_song_id,
           l.topic_selected, l.used_answers, l.explode_at, coalesce(l.grace_count, 0) as grace_count,
           coalesce(p.bot_skill, 2) as skill
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    -- Reaktionszeit je Stärke (094: Anfänger/Mittel so langsam wie echte Spieler, Ø Mensch 5,6 s)
    if r.skill = 1 then v_base := 4.5; v_span := 3.0;
    elsif r.skill = 3 then v_base := 0.8; v_span := 1.2;
    else v_base := 4.0; v_span := 3.0; end if;

    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := v_base + (abs(hashtext(v_seed)) % 1000) / 1000.0 * v_span;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number, r.skill) then continue; end if;

    v_answer := null;
    if r.current_song_id is not null then
      if r.grace_count > 0 then
        -- Nachspielzeit: nur der Titel zählt – den kennt der Bot nicht immer
        if (abs(hashtext('t' || v_seed)) % 1000) / 1000.0 >= (case r.skill when 1 then 0.35 when 3 then 0.65 else 0.50 end) then
          continue;
        end if;
        select title into v_answer from public.song_pool where id = r.current_song_id;
      else
        -- Migration 092: meist den Künstler (½ Punkt), seltener den Titel
        v_artist_chance := case r.skill when 1 then 0.80 when 3 then 0.70 else 0.75 end;
        if (abs(hashtext('a' || v_seed)) % 1000) / 1000.0 < v_artist_chance then
          select trim(split_part(split_part(artist, ',', 1), '&', 1)) into v_answer from public.song_pool where id = r.current_song_id;
        end if;
        if v_answer is null or length(v_answer) = 0 then
          select title into v_answer from public.song_pool where id = r.current_song_id;
        end if;
      end if;
    else
      select ta.answer into v_answer
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(coalesce(r.topic_selected, ''))
        and not (ta.lower_answer = any (select lower(u) from unnest(r.used_answers) u))
      order by random() limit 1;
      v_answer := coalesce(v_answer, 'Keine Ahnung');
    end if;

    if v_answer is not null then
      begin
        perform public.rpc_attempt_pass(r.code, r.holder_player_id, v_answer);
      exception when others then
        null;
      end;
    end if;
  end loop;
end;
$function$;

-- ---------- C) Punkte: Tempo-Abgaben x 5 statt Clutch x 10 ----------
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
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.tempo * 5,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.tempo_pass_count, 0) as tempo,
           coalesce(p.is_bot, false) as is_bot
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
