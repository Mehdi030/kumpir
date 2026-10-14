-- ============================================================
-- 126: Jahr raten – Monats-Entscheid bei Gleichstand (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- Haben beim besten Abstand zwei oder mehr Spieler denselben Abstand (z. B. beide genau das richtige Jahr), tippen NUR diese
-- den Erscheinungsmonat (12 Sekunden), alle anderen schauen zu. Wer dem echten Monat am nächsten ist, bekommt +1 Punkt
-- (Gleichstand: alle Nächsten). Nur für Songs, bei denen der Monat bekannt ist (song_pool.release_month, aus
-- db/scripts/fetch-release-months.mjs); sonst läuft die Auflösung wie bisher.
-- Neu: song_pool.release_month, quiz_secret.month, quiz_answers.month; Zustand quiz_state = 'month'; quiz_options.tie.
-- ============================================================
BEGIN;

ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS release_month smallint CHECK (release_month BETWEEN 1 AND 12);
ALTER TABLE public.quiz_secret ADD COLUMN IF NOT EXISTS month smallint;
ALTER TABLE public.quiz_answers ADD COLUMN IF NOT EXISTS month smallint;

CREATE OR REPLACE FUNCTION public._quiz_seconds(p_mode text, p_state text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state
    WHEN 'reveal' THEN CASE p_mode WHEN 'year' THEN 8 ELSE 5 END
    WHEN 'buzzed' THEN 7
    WHEN 'month' THEN 12
    ELSE CASE p_mode WHEN 'year' THEN 20 ELSE 30 END
  END::numeric
$$;

CREATE OR REPLACE FUNCTION public._quiz_start_question(p_lobby_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_year int; v_month int; v_seq int;
BEGIN
  SELECT game_mode, quiz_seq + 1 INTO v_mode, v_seq FROM public.lobbies WHERE id = p_lobby_id;
  SELECT release_year, release_month INTO v_year, v_month FROM public.song_pool WHERE id = p_song_id;
  PERFORM public._quiz_take_song(p_lobby_id, p_song_id);
  INSERT INTO public.quiz_secret (lobby_id, seq, song_id, answer, year, month)
  VALUES (p_lobby_id, v_seq, p_song_id, NULL, v_year, v_month)
  ON CONFLICT (lobby_id) DO UPDATE SET seq = excluded.seq, song_id = excluded.song_id, answer = NULL, year = excluded.year, month = excluded.month, pick_options = NULL;
  UPDATE public.lobbies
     SET quiz_state = 'question', quiz_seq = v_seq, quiz_started_at = now(),
         quiz_ends_at = now() + public._quiz_seconds(v_mode, 'question') * interval '1 second',
         quiz_options = CASE WHEN v_mode = 'year' THEN quiz_options - 'tie' ELSE NULL END, quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL,
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_tick(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_end timestamptz; v_pen numeric;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_ends_at IS NULL OR l.quiz_ends_at > now() THEN RETURN; END IF;
  IF l.quiz_state = 'buzzed' THEN
    -- Zeit zum Antworten abgelaufen: dieser Spieler ist für den Song raus, die anderen dürfen weiter buzzern
    v_end := greatest(coalesce((l.quiz_options ->> 'qend')::timestamptz, now()), now() + interval '5 seconds');
    -- 124: keine Eingabe = wie falsch: -1 Punkt (nicht unter 0) und Eintrag im Protokoll
    v_pen := public._quiz_penalty(p_lobby_id, l.quiz_picker);
    PERFORM public._quiz_log_add(p_lobby_id, l.quiz_seq, l.quiz_picker, NULL, false, v_pen);
    UPDATE public.lobbies SET quiz_state = 'question', quiz_locked = array_append(quiz_locked, quiz_picker), quiz_picker = NULL,
                              quiz_ends_at = v_end, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    IF coalesce(array_length(public._quiz_eligible(p_lobby_id), 1), 0) = 0 THEN PERFORM public._quiz_reveal(p_lobby_id); END IF;
  ELSIF l.quiz_state IN ('question', 'month') THEN
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSIF l.quiz_state = 'reveal' THEN
    PERFORM public._quiz_next(p_lobby_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_reveal(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; v_title text; v_artist text; v_results jsonb; v_goal uuid;
        v_tie uuid[]; v_mind int; v_picks jsonb := '{}'::jsonb; v_winners uuid[] := '{}'; v_best int; v_extra jsonb := '{}'::jsonb;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  SELECT title, artist INTO v_title, v_artist FROM public.song_pool WHERE id = s.song_id;

  -- 126: Jahr raten – Gleichstand beim besten Abstand (z. B. zweimal dasselbe Jahr): erst die Gleichstehenden tippen den Monat,
  -- alle anderen schauen kurz zu. Nur wenn wir den Monat des Songs kennen.
  IF l.game_mode = 'year' AND s.year IS NOT NULL AND s.month IS NOT NULL AND l.quiz_state = 'question' THEN
    SELECT min(abs(a.num - s.year)) INTO v_mind FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.num IS NOT NULL;
    SELECT array_agg(a.player_id) INTO v_tie FROM public.quiz_answers a
     WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.num IS NOT NULL AND abs(a.num - s.year) = v_mind
       AND EXISTS (SELECT 1 FROM public.players p WHERE p.lobby_id = p_lobby_id AND p.player_id = a.player_id AND p.status = 'active');
    IF coalesce(array_length(v_tie, 1), 0) >= 2 THEN
      UPDATE public.lobbies
         SET quiz_state = 'month', quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('year', 'month') * interval '1 second',
             quiz_options = coalesce(quiz_options, '{}'::jsonb) || jsonb_build_object('tie', jsonb_build_object('players', to_jsonb(v_tie), 'diff', v_mind)),
             quiz_rev = quiz_rev + 1, last_activity_at = now()
       WHERE id = p_lobby_id;
      RETURN;
    END IF;
  END IF;

  IF l.game_mode = 'year' AND s.year IS NOT NULL THEN
    UPDATE public.quiz_answers a
       SET points = CASE abs(a.num - s.year) WHEN 0 THEN 5 WHEN 1 THEN 3 WHEN 2 THEN 2 ELSE CASE WHEN abs(a.num - s.year) <= 5 THEN 1 ELSE 0 END END,
           correct = abs(a.num - s.year) <= 2
     WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.num IS NOT NULL;
    UPDATE public.players p SET song_points = coalesce(p.song_points, 0) + a.points
      FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND p.lobby_id = p_lobby_id AND p.player_id = a.player_id;
  END IF;

  -- Monats-Entscheid auswerten: wer dem echten Monat am nächsten ist, bekommt +1 (Gleichstand: alle Nächsten)
  IF l.game_mode = 'year' AND l.quiz_state = 'month' AND s.month IS NOT NULL THEN
    SELECT coalesce(jsonb_object_agg(a.player_id::text, a.month), '{}'::jsonb) INTO v_picks
      FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.month IS NOT NULL;
    SELECT min(abs(a.month - s.month)) INTO v_best FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.month IS NOT NULL;
    IF v_best IS NOT NULL THEN
      SELECT array_agg(a.player_id) INTO v_winners FROM public.quiz_answers a
       WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.month IS NOT NULL AND abs(a.month - s.month) = v_best;
      UPDATE public.quiz_answers a SET points = coalesce(a.points, 0) + 1 WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.player_id = ANY (v_winners);
      UPDATE public.players p SET song_points = coalesce(p.song_points, 0) + 1 WHERE p.lobby_id = p_lobby_id AND p.player_id = ANY (v_winners);
    END IF;
    v_extra := jsonb_build_object('month', s.month, 'tie', jsonb_build_object('players', coalesce(l.quiz_options -> 'tie' -> 'players', '[]'::jsonb), 'picks', v_picks, 'winners', to_jsonb(coalesce(v_winners, '{}'::uuid[]))));
  ELSIF s.month IS NOT NULL THEN
    v_extra := jsonb_build_object('month', s.month);
  END IF;

  IF l.quiz_target IS NOT NULL THEN
    SELECT player_id INTO v_goal FROM public.players
     WHERE lobby_id = p_lobby_id AND status = 'active' AND coalesce(song_points, 0) >= l.quiz_target
     ORDER BY song_points DESC LIMIT 1;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('playerId', a.player_id, 'points', a.points, 'correct', a.correct,
           'answer', CASE WHEN l.game_mode = 'year' THEN a.num::text ELSE NULL END) ORDER BY a.points DESC, a.answered_at), '[]')
    INTO v_results FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq;

  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('title', v_title, 'artist', v_artist, 'year', s.year, 'results', v_results, 'goal', v_goal) || v_extra,
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds(l.game_mode, 'reveal') * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_do_choose(p_lobby_id uuid, p_player_id uuid, p_choice text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_num int; v_tie uuid[]; v_left int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_state NOT IN ('question', 'month') THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF l.game_mode <> 'year' THEN RAISE EXCEPTION 'quiz_wrong_action'; END IF;
  -- 126: Monats-Entscheid – nur die Gleichstehenden dürfen, einmal, Monat 1..12
  IF l.quiz_state = 'month' THEN
    SELECT array_agg(x::uuid) INTO v_tie FROM jsonb_array_elements_text(coalesce(l.quiz_options -> 'tie' -> 'players', '[]'::jsonb)) x;
    IF NOT (p_player_id = ANY (coalesce(v_tie, '{}'))) THEN RAISE EXCEPTION 'quiz_not_in_tie'; END IF;
    BEGIN v_num := trim(p_choice)::int; EXCEPTION WHEN others THEN RAISE EXCEPTION 'quiz_bad_month'; END;
    IF v_num < 1 OR v_num > 12 THEN RAISE EXCEPTION 'quiz_bad_month'; END IF;
    IF EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id AND month IS NOT NULL) THEN
      RAISE EXCEPTION 'quiz_already_answered';
    END IF;
    UPDATE public.quiz_answers SET month = v_num WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id;
    UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    SELECT count(*) INTO v_left FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.player_id = ANY (v_tie) AND a.month IS NULL;
    IF v_left = 0 THEN
      UPDATE public.lobbies SET quiz_ends_at = least(quiz_ends_at, now() + interval '800 milliseconds') WHERE id = p_lobby_id;
    END IF;
    RETURN jsonb_build_object('points', 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active') THEN RAISE EXCEPTION 'not_a_member'; END IF;
  IF EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id) THEN
    RAISE EXCEPTION 'quiz_already_answered';
  END IF;
  BEGIN v_num := trim(p_choice)::int; EXCEPTION WHEN others THEN RAISE EXCEPTION 'quiz_bad_year'; END;
  IF v_num < coalesce((l.quiz_options ->> 'yearMin')::int, 1900) OR v_num > coalesce((l.quiz_options ->> 'yearMax')::int, 2100) THEN RAISE EXCEPTION 'quiz_bad_year'; END IF;
  INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, num, correct, points, tries, answered_at)
  VALUES (p_lobby_id, l.quiz_seq, p_player_id, left(p_choice, 80), v_num, false, 0, 1, now());
  UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._quiz_maybe_early(p_lobby_id);
  RETURN jsonb_build_object('points', 0);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_status(p_code text, p_player_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; l public.lobbies%ROWTYPE; v_me jsonb;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  SELECT * INTO l FROM public.lobbies WHERE id = v_id;
  SELECT jsonb_build_object('answered', CASE WHEN l.quiz_state = 'month' THEN a.month IS NOT NULL ELSE true END, 'correct', a.correct, 'points', a.points, 'tries', a.tries,
                            'answer', CASE WHEN l.quiz_state = 'month' THEN a.month::text ELSE a.num::text END)
    INTO v_me FROM public.quiz_answers a WHERE a.lobby_id = v_id AND a.seq = l.quiz_seq AND a.player_id = p_player_id;
  RETURN jsonb_build_object(
    'seq', l.quiz_seq,
    'me', coalesce(v_me, jsonb_build_object('answered', false)),
    -- Jahr raten: wer schon getippt hat (ohne die Jahre selbst – die sieht man erst bei der Auflösung)
    'answered', CASE WHEN l.game_mode = 'year'
                     THEN (SELECT coalesce(jsonb_agg(player_id), '[]') FROM public.quiz_answers WHERE lobby_id = v_id AND seq = l.quiz_seq AND (l.quiz_state <> 'month' OR month IS NOT NULL))
                     ELSE '[]'::jsonb END
  );
END $$;

CREATE OR REPLACE FUNCTION public._quiz_bot_tick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
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
          SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 2 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
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
END $$;

COMMIT;
