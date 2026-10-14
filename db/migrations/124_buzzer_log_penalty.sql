-- ============================================================
-- 124: Buzzer – Protokoll aller Buzzer-Versuche + Minuspunkt (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- Wer buzzert und falsch liegt ODER nichts eingibt (Zeit um), bekommt -1 Punkt – außer er steht bei 0.
-- lobbies.quiz_log (jsonb, letzte 40 Einträge): [{seq, p = Spieler, a = Eingabe oder null, ok, pts}] – das Spiel zeigt
-- daraus die Liste "wer hat gebuzzert" farbig (grün richtig / rot falsch). Wird bei jedem Start geleert.
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS quiz_log jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public._quiz_log_add(p_lobby_id uuid, p_seq int, p_player uuid, p_answer text, p_ok boolean, p_pts numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.lobbies
     SET quiz_log = (
       SELECT coalesce(jsonb_agg(e ORDER BY i), '[]'::jsonb) FROM (
         SELECT e, i FROM jsonb_array_elements(coalesce(quiz_log, '[]'::jsonb) || jsonb_build_array(
                  jsonb_build_object('seq', p_seq, 'p', p_player, 'a', p_answer, 'ok', p_ok, 'pts', p_pts))) WITH ORDINALITY t(e, i)
          ORDER BY i DESC LIMIT 40) x)
   WHERE id = p_lobby_id;
END $$;

-- -1 Punkt, aber nie unter 0; liefert -1 (abgezogen) oder 0 (stand schon bei 0)
CREATE OR REPLACE FUNCTION public._quiz_penalty(p_lobby_id uuid, p_player uuid) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.players SET song_points = song_points - 1
   WHERE lobby_id = p_lobby_id AND player_id = p_player AND coalesce(song_points, 0) >= 1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN CASE WHEN v_n > 0 THEN -1 ELSE 0 END;
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
  ELSIF l.quiz_state = 'question' THEN
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSIF l.quiz_state = 'reveal' THEN
    PERFORM public._quiz_next(p_lobby_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_do_answer(p_lobby_id uuid, p_player_id uuid, p_answer text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
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

  v_pts := CASE WHEN v_score >= 1 THEN 2 ELSE 1 END;
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
END $$;

CREATE OR REPLACE FUNCTION public._quiz_begin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_min int; v_max int; v_opts jsonb;
BEGIN
  SELECT game_mode INTO v_mode FROM public.lobbies WHERE id = p_lobby_id;
  -- Jahr raten: Zeitleiste = ältester bis neuester Song der Playlist (mindestens 15 Jahre breit)
  IF v_mode = 'year' THEN
    SELECT min(sp.release_year), max(sp.release_year) INTO v_min, v_max
      FROM public.song_pool sp
      JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id AND tp.is_song_category IS TRUE
      JOIN public.lobbies l ON l.id = p_lobby_id AND lower(tp.text) = lower(coalesce(l.topic_selected, ''))
     WHERE sp.archived_from IS NULL AND sp.release_year IS NOT NULL;
    v_max := coalesce(v_max, extract(year FROM now())::int);
    v_min := least(coalesce(v_min, v_max - 14) - 1, v_max - 14);
    v_opts := jsonb_build_object('yearMin', v_min, 'yearMax', v_max);
  END IF;
  DELETE FROM public.quiz_answers WHERE lobby_id = p_lobby_id;
  UPDATE public.players SET song_points = 0, tiebreak = 0, is_alive = true, eliminated_at_round = NULL WHERE lobby_id = p_lobby_id AND status = 'active';
  UPDATE public.lobbies
     SET phase = 'quiz', explode_at = NULL, holder_player_id = NULL,
         quiz_index = 0, quiz_state = NULL, quiz_options = v_opts, quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL, quiz_log = '[]'::jsonb,
         -- Ziel: Buzzer = zuerst 10 Punkte (höchstens 20 Songs), Jahr raten = nach 8 Songs die meisten Punkte
         quiz_target = CASE WHEN v_mode = 'buzzer' THEN 10 ELSE NULL END,
         quiz_total = CASE WHEN v_mode = 'buzzer' THEN 20 ELSE 8 END,
         used_answers = '{}',
         used_song_ids = CASE WHEN coalesce(series_index, 1) <= 1 THEN '{}' ELSE coalesce(used_song_ids, '{}') END,
         run_started_at = now(), countdown_started_at = NULL, countdown_ends_at = NULL, countdown_starter_player_id = NULL,
         last_activity_at = now()
   WHERE id = p_lobby_id;
  PERFORM public._quiz_next(p_lobby_id);
END $$;

COMMIT;
