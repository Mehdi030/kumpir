-- ============================================================
-- 117: Quiz-Modi zählen die Song-Statistik nur für Menschen (Fund aus dem Gesamttest 2026-10-13)
-- ============================================================
-- Vorher zählte jede Quiz-Frage als "gespielt" und jede richtige Antwort (auch von Bots) als "erraten" ->
-- bei 11 Songs gab es mehr Treffer als Spiele und die Schwierigkeitsstufe (Bonuszeit im Kartoffel-Modus) wurde
-- durch meine Bot-Testspiele leicht verfälscht (Pool: 709 gespielt / 201 erraten, echte Menschen: 466 / 119).
-- Jetzt: gespielt = Zahl der Menschen, die raten dürfen; erraten = richtige Menschen-Antwort; nur Schnipsel,
-- Songwahl, Buzzer, Duell (Lückentitel, Wer singt das?, Jahr raten zählen nicht: dort geht es nicht ums Erkennen).
-- Die bereits verfälschten Zahlen werden NICHT geändert (Neuberechnen nur auf Wunsch).
BEGIN;

CREATE OR REPLACE FUNCTION public._quiz_take_song(p_lobby_id uuid, p_song_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_plays int; v_hits int; v_h int;
BEGIN
  -- 117: Song-Statistik (Schwierigkeit) zählt wie im Kartoffel-Modus nur MENSCHEN und nur dort, wo man den Song
  -- wirklich erkennen muss (Schnipsel, Songwahl, Buzzer, Duell): ein "gespielt" je Mensch, der ihn raten darf.
  SELECT count(*) INTO v_h
  FROM public.players p JOIN public.lobbies l ON l.id = p.lobby_id
  WHERE l.id = p_lobby_id AND p.status = 'active' AND NOT coalesce(p.is_bot, false)
    AND l.game_mode IN ('snippet', 'pick', 'buzzer', 'duel')
    AND (l.game_mode <> 'pick' OR p.player_id IS DISTINCT FROM l.quiz_picker)
    AND (l.game_mode <> 'duel' OR p.player_id::text IN (l.quiz_options ->> 'a', l.quiz_options ->> 'b'));
  UPDATE public.song_pool SET plays = plays + coalesce(v_h, 0) WHERE id = p_song_id RETURNING plays, hits INTO v_plays, v_hits;
  UPDATE public.lobbies
     SET current_song_id = p_song_id, current_song_started_at = now(),
         current_song_difficulty = public._song_difficulty(v_plays, v_hits),
         used_song_ids = array_append(coalesce(used_song_ids, '{}'), p_song_id)
   WHERE id = p_lobby_id;
END $function$;

CREATE OR REPLACE FUNCTION public._quiz_do_answer(p_lobby_id uuid, p_player_id uuid, p_answer text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; a public.quiz_answers%ROWTYPE;
        v_score numeric; v_title text; v_artist text; v_feat text[]; v_rank int; v_pts numeric := 0; v_clean text; v_stage int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RAISE EXCEPTION 'quiz_not_running'; END IF;
  IF l.game_mode NOT IN ('snippet', 'pick', 'gap', 'buzzer', 'duel') THEN RAISE EXCEPTION 'quiz_wrong_action'; END IF;
  IF l.game_mode = 'buzzer' THEN
    IF l.quiz_state <> 'buzzed' OR l.quiz_picker IS DISTINCT FROM p_player_id THEN RAISE EXCEPTION 'quiz_not_your_turn'; END IF;
  ELSIF l.quiz_state <> 'question' THEN RAISE EXCEPTION 'quiz_closed';
  END IF;
  IF NOT (p_player_id = ANY (public._quiz_eligible(p_lobby_id))) AND l.game_mode <> 'buzzer' THEN RAISE EXCEPTION 'quiz_not_your_turn'; END IF;

  v_clean := left(trim(coalesce(p_answer, '')), 60);
  IF v_clean = '' THEN RAISE EXCEPTION 'empty_answer'; END IF;

  SELECT * INTO a FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id;
  IF FOUND AND a.correct THEN RETURN jsonb_build_object('correct', true, 'points', a.points, 'already', true); END IF;
  IF FOUND AND a.answered_at > now() - interval '1 second' AND l.game_mode <> 'buzzer' THEN RAISE EXCEPTION 'too_fast'; END IF;

  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  IF l.game_mode = 'gap' THEN
    v_score := CASE WHEN public._ans_close(public._ans_norm(s.answer), public._ans_norm(v_clean)) THEN 1 ELSE 0 END;
  ELSE
    SELECT title, artist, feat_artists INTO v_title, v_artist, v_feat FROM public.song_pool WHERE id = s.song_id;
    v_score := public._score_song_answer(v_title, v_artist, v_feat, v_clean);
  END IF;

  IF v_score <= 0 THEN
    INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, tries, answered_at)
    VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_clean, 1, now())
    ON CONFLICT (lobby_id, seq, player_id) DO UPDATE SET answer = excluded.answer, tries = quiz_answers.tries + 1, answered_at = now();
    IF l.game_mode = 'buzzer' THEN
      -- falsch: für diesen Song raus, die anderen dürfen weiter buzzern
      UPDATE public.lobbies SET quiz_state = 'question', quiz_locked = array_append(quiz_locked, p_player_id), quiz_picker = NULL,
             quiz_ends_at = greatest(coalesce((quiz_options ->> 'qend')::timestamptz, now()), now() + interval '5 seconds'),
             quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
      IF coalesce(array_length(public._quiz_eligible(p_lobby_id), 1), 0) = 0 THEN PERFORM public._quiz_reveal(p_lobby_id); END IF;
    ELSE
      UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND is_bot) THEN
      INSERT INTO public.answer_misses (lobby_id, song_id, player_id, answer) VALUES (p_lobby_id, s.song_id, p_player_id, v_clean);
    END IF;
    RETURN jsonb_build_object('correct', false);
  END IF;

  SELECT count(*) + 1 INTO v_rank FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND correct;
  IF l.game_mode = 'snippet' THEN
    v_stage := least(3, floor(extract(epoch FROM now() - l.quiz_started_at) / 6)::int);
    v_pts := 4 - v_stage;
  ELSIF l.game_mode = 'buzzer' THEN v_pts := 2;
  ELSIF l.game_mode = 'duel' THEN v_pts := 1;
  ELSE v_pts := public._quiz_rank_points(v_rank);
  END IF;
  IF v_score < 1 AND l.game_mode <> 'gap' THEN v_pts := round(v_pts / 2, 1); END IF;  -- nur Künstler: halbe Punkte

  INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, correct, points, tries, answered_at)
  VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_clean, true, v_pts, 1, now())
  ON CONFLICT (lobby_id, seq, player_id) DO UPDATE SET answer = excluded.answer, correct = true, points = excluded.points,
     tries = quiz_answers.tries + 1, answered_at = now();
  UPDATE public.players SET song_points = coalesce(song_points, 0) + v_pts WHERE lobby_id = p_lobby_id AND player_id = p_player_id;
  -- 117: nur richtige Antworten von Menschen und nur in den Erkennungs-Modi zählen als Treffer
  IF v_score >= 1 AND s.song_id IS NOT NULL AND l.game_mode IN ('snippet', 'pick', 'buzzer', 'duel')
     AND NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND coalesce(is_bot, false)) THEN
    UPDATE public.song_pool SET hits = hits + 1 WHERE id = s.song_id;
  END IF;

  IF l.game_mode = 'buzzer' THEN
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSIF l.game_mode = 'duel' THEN
    UPDATE public.lobbies
       SET quiz_options = jsonb_set(quiz_options, CASE WHEN (quiz_options ->> 'a') = p_player_id::text THEN '{wa}'::text[] ELSE '{wb}'::text[] END,
             to_jsonb(coalesce((quiz_options ->> CASE WHEN (quiz_options ->> 'a') = p_player_id::text THEN 'wa' ELSE 'wb' END)::int, 0) + 1))
     WHERE id = p_lobby_id;
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSE
    UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    PERFORM public._quiz_maybe_early(p_lobby_id);
  END IF;
  RETURN jsonb_build_object('correct', true, 'points', v_pts, 'half', v_score < 1 AND l.game_mode <> 'gap');
END $function$;

COMMIT;
