-- ============================================================
-- 140: Buzzer-Wertung mit Kommazahlen + Fairness (Wunsch Mehdi, 2026-11-04)
-- ============================================================
-- * Buzzer: Künstler richtig = 0,25 Punkte, Titel richtig = 1 Punkt, Titel + Künstler = 1,25 (vorher 1 / 2 / 2).
--   Falsche Antwort: -0,5 (nie unter 0). Ziel bleibt 10 Punkte (höchstens 20 Songs).
-- * Alle Summen (Statistik, Bestenliste, Herausforderungen) behalten die Kommastellen statt zu runden.
-- * Bots antworten je nach Stärke mit Künstler, Titel oder beidem.
-- * Gleichstand am Ende (gleiche Punkte, gleicher Tiebreak, gleiche Weitergaben): Zufall statt "kleinster Sitzplatz".
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._quiz_do_answer(p_lobby_id uuid, p_player_id uuid, p_answer text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE;
        v_score numeric; v_title text; v_artist text; v_feat text[]; v_pts numeric := 0; v_clean text; v_pen numeric;
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
    -- falsch: -1 Punkt (nicht unter 0), für diesen Song raus, die anderen dürfen weiter buzzern
    v_pen := public._quiz_penalty(p_lobby_id, p_player_id);
    PERFORM public._quiz_log_add(p_lobby_id, l.quiz_seq, p_player_id, v_clean, false, v_pen);
    UPDATE public.lobbies SET quiz_state = 'question', quiz_locked = array_append(quiz_locked, p_player_id), quiz_picker = NULL,
           quiz_ends_at = greatest(coalesce((quiz_options ->> 'qend')::timestamptz, now()), now() + interval '5 seconds'),
           quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND is_bot) THEN
      INSERT INTO public.answer_misses (lobby_id, song_id, player_id, answer) VALUES (p_lobby_id, s.song_id, p_player_id, v_clean);
    END IF;
    IF coalesce(array_length(public._quiz_eligible(p_lobby_id), 1), 0) = 0 THEN PERFORM public._quiz_reveal(p_lobby_id); END IF;
    RETURN jsonb_build_object('correct', false, 'points', v_pen);
  END IF;

  -- 140: Künstler allein 0,25 – Titel 1 – Titel + Künstler 1,25 (vorher 1 / 2 / 2): ein Spiel nur mit Künstler-Raten ist nicht mehr nach 10 Zügen vorbei
  v_pts := CASE WHEN v_score >= 1.5 THEN 1.25 WHEN v_score >= 1 THEN 1 ELSE 0.25 END;
  INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, correct, points, tries, answered_at)
  VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_clean, true, v_pts, 1, now())
  ON CONFLICT (lobby_id, seq, player_id) DO UPDATE SET answer = excluded.answer, correct = true, points = excluded.points,
     tries = quiz_answers.tries + 1, answered_at = now();
  UPDATE public.players SET song_points = coalesce(song_points, 0) + v_pts WHERE lobby_id = p_lobby_id AND player_id = p_player_id;
  PERFORM public._quiz_log_add(p_lobby_id, l.quiz_seq, p_player_id, v_clean, true, v_pts);
  -- Treffer für die Song-Statistik: nur Menschen
  IF v_score >= 1 AND s.song_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND coalesce(is_bot, false)) THEN
    UPDATE public.song_pool SET hits = hits + 1 WHERE id = s.song_id;
  END IF;
  PERFORM public._quiz_reveal(p_lobby_id);
  RETURN jsonb_build_object('correct', true, 'points', v_pts, 'half', v_score < 1);
END $function$;

CREATE OR REPLACE FUNCTION public._quiz_penalty(p_lobby_id uuid, p_player uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_old numeric; v_pen numeric;
BEGIN
  SELECT coalesce(song_points, 0) INTO v_old FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player;
  v_pen := least(0.5, coalesce(v_old, 0));
  IF v_pen > 0 THEN
    UPDATE public.players SET song_points = song_points - v_pen WHERE lobby_id = p_lobby_id AND player_id = p_player;
  END IF;
  RETURN -v_pen;
END $function$;

CREATE OR REPLACE FUNCTION public._quiz_bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_m int; v_seed text; v_delay numeric; v_ok boolean; v_el numeric; s public.quiz_secret%ROWTYPE; v_answer text; v_year int; v_range int;
BEGIN
  FOR r IN
    SELECT l.id AS lobby_id, l.game_mode, l.quiz_state, l.quiz_seq, l.quiz_index, l.quiz_started_at, l.quiz_picker, l.quiz_locked, l.quiz_options,
           p.player_id, coalesce(p.bot_skill, 2) AS skill
    FROM public.lobbies l JOIN public.players p ON p.lobby_id = l.id AND p.is_bot AND p.status = 'active'
    WHERE l.phase = 'quiz' AND l.quiz_state IN ('question', 'buzzed', 'month')
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
          -- 140: Anfänger nennen meist nur den Künstler (0,25), Profis den Titel oder beides (1 / 1,25)
          SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 100 < (CASE r.skill WHEN 1 THEN 35 WHEN 3 THEN 60 ELSE 50 END) THEN title
                      WHEN abs(hashtext('t' || v_seed)) % 100 < (CASE r.skill WHEN 1 THEN 35 WHEN 3 THEN 80 ELSE 55 END) THEN trim(split_part(split_part(artist, ',', 1), '&', 1)) || ' ' || title
                      ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
            INTO v_answer FROM public.song_pool WHERE id = s.song_id;
          PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
        END IF;
      ELSIF r.quiz_state = 'month' AND r.game_mode = 'year' AND v_el >= 1.5 + (abs(hashtext('m' || v_seed)) % 1000) / 1000.0 * 4
            AND (r.quiz_options -> 'tie' -> 'players') ? r.player_id::text
            AND NOT EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = r.lobby_id AND seq = r.quiz_seq AND player_id = r.player_id AND month IS NOT NULL) THEN
        SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
        v_m := ((coalesce(s.month, 6) - 1 + (abs(hashtext('mo' || v_seed)) % (2 * (CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 1 ELSE 3 END) + 1)) - (CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 1 ELSE 3 END) + 24) % 12) + 1;
        PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_m::text);
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
END $function$;

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
                      p.song_points desc, p.tiebreak desc, p.pass_count desc, hashtext(p.lobby_id::text || p.player_id::text)
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

CREATE OR REPLACE FUNCTION public._quiz_finish(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_top uuid; v_mode text; v_run timestamptz;
BEGIN
  SELECT game_mode, run_started_at INTO v_mode, v_run FROM public.lobbies WHERE id = p_lobby_id;
  -- Gleichstand: Jahr raten = mehr Volltreffer (5 P.), dann mehr Treffer ±1, ±2; Buzzer = mehr richtige Antworten
  UPDATE public.players p SET tiebreak = CASE WHEN v_mode = 'letters'
      -- 132: Roulette – bei gleichen Punkten gewinnt, wer weniger falsche Wörter hatte
      THEN 1000 - (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p.lobby_id AND e.player_id = p.player_id AND NOT coalesce(e.valid, false) AND NOT e.dup)::int
      ELSE coalesce((
      SELECT CASE WHEN v_mode = 'year'
                  THEN sum(CASE WHEN a.points >= 5 THEN 100 WHEN a.points >= 3 THEN 10 WHEN a.points >= 2 THEN 1 ELSE 0 END)
                  ELSE count(*) FILTER (WHERE a.correct) END
      FROM public.quiz_answers a WHERE a.lobby_id = p.lobby_id AND a.player_id = p.player_id), 0) END
   WHERE p.lobby_id = p_lobby_id AND p.status = 'active';
  SELECT player_id INTO v_top FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active'
    ORDER BY coalesce(song_points, 0) DESC, tiebreak DESC, hashtext(lobby_id::text || player_id::text) LIMIT 1;
  UPDATE public.lobbies SET quiz_state = NULL, quiz_ends_at = NULL, quiz_picker = NULL, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._finish_round(p_lobby_id);
  -- 133: Buzzer / Jahr raten – Spiel für die Modus-Statistik im Profil festhalten
  IF v_mode IN ('buzzer', 'year') THEN PERFORM public._quiz_record_match(p_lobby_id, v_mode, v_run); END IF;
  UPDATE public.lobbies SET holder_player_id = v_top WHERE id = p_lobby_id;
END $function$;

-- Summen mit Kommastellen
ALTER TABLE public.quiz_mode_matches ALTER COLUMN total TYPE numeric(7,2);
CREATE OR REPLACE FUNCTION public._quiz_record_match(p_lobby_id uuid, p_mode text, p_run timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_humans int;
BEGIN
  IF p_run IS NULL THEN RETURN; END IF;
  v_humans := public._lobby_human_count(p_lobby_id);
  INSERT INTO public.quiz_mode_matches (user_id, lobby_id, run_key, mode, place, total, humans, ranked, hits, answers)
  SELECT p.user_id, p_lobby_id, p_run, p_mode,
         coalesce((SELECT sr.place FROM public.series_results sr WHERE sr.lobby_id = p_lobby_id AND sr.player_id = p.player_id ORDER BY sr.set_index DESC LIMIT 1), 99),
         round(coalesce(p.song_points, 0), 2), v_humans, v_humans >= 2,
         (SELECT count(*) FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.player_id = p.player_id AND (CASE WHEN p_mode = 'year' THEN a.points >= 5 ELSE a.correct END))::int,
         (SELECT count(*) FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.player_id = p.player_id)::int
    FROM public.players p
   WHERE p.lobby_id = p_lobby_id AND p.status = 'active' AND p.user_id IS NOT NULL AND NOT coalesce(p.is_bot, false)
  ON CONFLICT DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION public._quiz_record_match(uuid, text, timestamptz) FROM PUBLIC;

ALTER TABLE public.challenges ALTER COLUMN score TYPE numeric(7,2);
ALTER TABLE public.challenge_results ALTER COLUMN score TYPE numeric(7,2);
DROP FUNCTION IF EXISTS public._challenge_score(uuid, uuid);
CREATE FUNCTION public._challenge_score(p_lobby_id uuid, p_player_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN coalesce(l.series_total, 1) > 1
              THEN round(coalesce((SELECT sum(sr.song_points) FROM public.series_results sr WHERE sr.lobby_id = l.id AND sr.player_id = p_player_id), 0), 2)
              ELSE round(coalesce((SELECT p.song_points FROM public.players p WHERE p.lobby_id = l.id AND p.player_id = p_player_id), 0), 2) END
    FROM public.lobbies l WHERE l.id = p_lobby_id;
$$;
REVOKE ALL ON FUNCTION public._challenge_score(uuid, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.rpc_challenge_submit(p_lobby_id uuid, p_player_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; c public.challenges%ROWTYPE; v_name text; v_user uuid; v_score numeric; v_rank int;
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_player_id) THEN RAISE EXCEPTION 'bad_session'; END IF;
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id;
  IF NOT FOUND OR l.challenge_code IS NULL OR l.phase <> 'finished' THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.challenges WHERE code = l.challenge_code;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT name, user_id INTO v_name, v_user FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND NOT coalesce(is_bot, false);
  IF v_name IS NULL THEN RETURN NULL; END IF;
  v_score := public._challenge_score(p_lobby_id, p_player_id);
  INSERT INTO public.challenge_results (lobby_id, code, user_id, name, score) VALUES (p_lobby_id, c.code, v_user, v_name, v_score) ON CONFLICT (lobby_id) DO NOTHING;
  SELECT score INTO v_score FROM public.challenge_results WHERE lobby_id = p_lobby_id;
  SELECT 1 + count(*) INTO v_rank FROM public.challenge_results WHERE code = c.code AND score > v_score;
  RETURN jsonb_build_object('code', c.code, 'creator', c.creator_name, 'target', c.score, 'score', v_score, 'won', v_score > c.score, 'tie', v_score = c.score, 'rank', v_rank);
END $$;
REVOKE ALL ON FUNCTION public.rpc_challenge_submit(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_challenge_submit(uuid, uuid) TO anon, authenticated;

COMMIT;
