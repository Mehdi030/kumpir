-- ============================================================
-- 130: Roulette – Host-Einstellungen, Statistik und Erfolge (Wunsch Mehdi, 2026-10-20)
-- ============================================================
-- Host-Einstellungen (lobbies.letters_cfg): Anzahl Kategorien (1–5, Standard 3), Zeit je Kategorie (30/45/60/90 s, Standard 45) und
-- Kategorien, die NICHT drankommen dürfen ("off"). Es müssen genug Kategorien übrig bleiben (Anzahl + 2), sonst lehnt der Server ab.
-- Statistik: roulette_rounds (je Kategorie und Konto) und roulette_matches (je Spiel) – gewertet nur mit mindestens 2 Menschen
-- ("ranked"); get_my_roulette_stats() liefert die eigene Auswertung. Erfolge: Glückspilz, Wortakrobat, Wörterflut.
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS letters_cfg jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.roulette_rounds (
  user_id uuid NOT NULL,
  lobby_id uuid NOT NULL,
  run_key timestamptz NOT NULL,
  idx int NOT NULL,
  category text NOT NULL,
  letter text NOT NULL,
  correct int NOT NULL,
  bad int NOT NULL,
  dup int NOT NULL,
  place int NOT NULL,
  humans int NOT NULL,
  ranked boolean NOT NULL,
  played_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, lobby_id, run_key, idx)
);
CREATE INDEX IF NOT EXISTS roulette_rounds_user_idx ON public.roulette_rounds (user_id, played_at DESC);
CREATE TABLE IF NOT EXISTS public.roulette_matches (
  user_id uuid NOT NULL,
  lobby_id uuid NOT NULL,
  run_key timestamptz NOT NULL,
  place int NOT NULL,
  total int NOT NULL,
  humans int NOT NULL,
  ranked boolean NOT NULL,
  categories int NOT NULL,
  played_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, lobby_id, run_key)
);
ALTER TABLE public.roulette_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roulette_matches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.roulette_rounds FROM anon, authenticated;
REVOKE ALL ON public.roulette_matches FROM anon, authenticated;

INSERT INTO public.achievements (code, title, description, icon, tier) VALUES
  ('roulette_win',       'Glückspilz',   'Gewinne ein Roulette-Match.',                                     '🎰', 'bronze'),
  ('roulette_words_100', 'Wortakrobat',  'Finde insgesamt 100 richtige Begriffe im Roulette.',              '🔤', 'silver'),
  ('roulette_haul_12',   'Wörterflut',   'Finde 12 richtige Begriffe in einer einzigen Kategorie.',         '🌊', 'gold')
ON CONFLICT (code) DO NOTHING;

-- Einstellungen mit Standardwerten
CREATE OR REPLACE FUNCTION public._letters_cfg(p_lobby_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object(
           'cats', coalesce((letters_cfg ->> 'cats')::int, 3),
           'secs', coalesce((letters_cfg ->> 'secs')::int, 45),
           'off', coalesce(letters_cfg -> 'off', '[]'::jsonb))
    FROM public.lobbies WHERE id = p_lobby_id
$$;

-- Buchstaben, bei denen mindestens p_need erlaubte Kategorien je 6+ Begriffe haben
CREATE OR REPLACE FUNCTION public._letters_letters(p_off jsonb, p_need int) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(array_agg(z.initial::text), '{}'::text[]) FROM (
    SELECT cov.initial FROM (
      SELECT t.category_id, t.initial FROM public.word_terms t
        JOIN public.word_categories c ON c.id = t.category_id AND c.active AND NOT (coalesce(p_off, '[]'::jsonb) @> to_jsonb(c.name))
       GROUP BY t.category_id, t.initial HAVING count(DISTINCT t.label) >= 6
    ) cov GROUP BY cov.initial HAVING count(*) >= greatest(p_need, 3)
  ) z
$$;

CREATE OR REPLACE FUNCTION public._letters_pick_cands(p_lobby_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter text; v_played jsonb; v_cands jsonb; v_off jsonb;
BEGIN
  SELECT lower(quiz_options ->> 'letter'), coalesce(quiz_options -> 'played', '[]'::jsonb) INTO v_letter, v_played FROM public.lobbies WHERE id = p_lobby_id;
  v_off := coalesce((SELECT letters_cfg -> 'off' FROM public.lobbies WHERE id = p_lobby_id), '[]'::jsonb);
  SELECT jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name)) INTO v_cands FROM (
    SELECT c.id, c.name FROM public.word_categories c
     WHERE c.active AND NOT (v_played @> to_jsonb(c.id::text)) AND NOT (v_off @> to_jsonb(c.name))
       AND (SELECT count(DISTINCT t.label) FROM public.word_terms t WHERE t.category_id = c.id AND t.initial = v_letter) >= 6
     ORDER BY random() LIMIT 3
  ) x;
  RETURN coalesce(v_cands, '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public._letters_spin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter char(1); v_arr text[]; v_cfg jsonb;
BEGIN
  DELETE FROM public.letters_votes WHERE lobby_id = p_lobby_id;
  v_cfg := public._letters_cfg(p_lobby_id);
  -- nur Buchstaben, bei denen genug Kategorien (Anzahl + 2 zur Auswahl) mit je 6+ Begriffen zur Verfügung stehen
  v_arr := public._letters_letters(v_cfg -> 'off', (v_cfg ->> 'cats')::int + 2);
  IF coalesce(cardinality(v_arr), 0) = 0 THEN RAISE EXCEPTION 'letters_no_words'; END IF;
  v_letter := v_arr[1 + floor(random() * cardinality(v_arr))::int];
  IF v_letter IS NULL THEN RAISE EXCEPTION 'letters_no_words'; END IF;
  UPDATE public.lobbies
     SET phase = 'quiz', quiz_state = 'spin', quiz_index = 0, quiz_seq = quiz_seq + 1,
         quiz_options = jsonb_build_object('letter', upper(v_letter), 'played', '[]'::jsonb, 'slot', 1, 'tally', jsonb_build_array(0, 0, 0)),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'spin') * interval '1 second',
         quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
  UPDATE public.lobbies SET quiz_options = quiz_options || jsonb_build_object('cands', public._letters_pick_cands(p_lobby_id)) WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._letters_begin_category(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_slot int; v_cnt int[] := ARRAY[0, 0, 0]; v_max int; v_pick int; b record; c int; v_n int; v_cat jsonb;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  v_slot := coalesce((l.quiz_options ->> 'slot')::int, 1);
  FOR b IN SELECT player_id FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active' AND is_bot LOOP
    INSERT INTO public.letters_votes (lobby_id, slot, player_id, choice) VALUES (p_lobby_id, v_slot, b.player_id, 1 + floor(random() * 3)::int) ON CONFLICT DO NOTHING;
  END LOOP;
  FOR c IN 1..3 LOOP
    SELECT count(*)::int INTO v_n FROM public.letters_votes v
      JOIN public.players p ON p.lobby_id = v.lobby_id AND p.player_id = v.player_id AND p.status = 'active'
     WHERE v.lobby_id = p_lobby_id AND v.slot = v_slot AND v.choice = c;
    v_cnt[c] := v_n;
  END LOOP;
  v_max := greatest(v_cnt[1], v_cnt[2], v_cnt[3]);
  SELECT x INTO v_pick FROM unnest(ARRAY[1, 2, 3]) x WHERE v_cnt[x] = v_max ORDER BY random() LIMIT 1;
  v_cat := l.quiz_options -> 'cands' -> (v_pick - 1);
  IF v_cat IS NULL THEN RAISE EXCEPTION 'letters_no_cands'; END IF;
  UPDATE public.lobbies
     SET quiz_state = 'question', quiz_index = quiz_index + 1, quiz_seq = quiz_seq + 1,
         quiz_options = (quiz_options - 'cands' - 'tally') || jsonb_build_object('cat', v_cat, 'played', coalesce(quiz_options -> 'played', '[]'::jsonb) || to_jsonb(v_cat ->> 'id')),
         quiz_started_at = now(), quiz_ends_at = now() + coalesce((l.letters_cfg ->> 'secs')::int, 45) * interval '1 second',
         quiz_reveal = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
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
  DELETE FROM public.letters_entries WHERE lobby_id = p_lobby_id;
  DELETE FROM public.letters_done WHERE lobby_id = p_lobby_id;
  UPDATE public.players SET song_points = 0, tiebreak = 0, is_alive = true, eliminated_at_round = NULL WHERE lobby_id = p_lobby_id AND status = 'active';
  UPDATE public.lobbies
     SET phase = 'quiz', explode_at = NULL, holder_player_id = NULL,
         quiz_index = 0, quiz_state = NULL, quiz_options = v_opts, quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL, quiz_log = '[]'::jsonb,
         -- Ziel: Buzzer = zuerst 10 Punkte (höchstens 20 Songs), Jahr raten = nach 8 Songs die meisten Punkte
         quiz_target = CASE WHEN v_mode = 'buzzer' THEN 10 ELSE NULL END,
         quiz_total = CASE WHEN v_mode = 'buzzer' THEN 20 WHEN v_mode = 'letters' THEN coalesce((SELECT (letters_cfg ->> 'cats')::int FROM public.lobbies WHERE id = p_lobby_id), 3) ELSE 8 END,
         used_answers = '{}',
         used_song_ids = CASE WHEN coalesce(series_index, 1) <= 1 THEN '{}' ELSE coalesce(used_song_ids, '{}') END,
         run_started_at = now(), countdown_started_at = NULL, countdown_ends_at = NULL, countdown_starter_player_id = NULL,
         last_activity_at = now()
   WHERE id = p_lobby_id;
  IF v_mode = 'letters' THEN PERFORM public._letters_spin(p_lobby_id); ELSE PERFORM public._quiz_next(p_lobby_id); END IF;
END $$;

-- Host stellt das Roulette ein (nur in der Lobby): { cats: 1–5, secs: 30|45|60|90, off: [Kategorienamen] }
CREATE OR REPLACE FUNCTION public.set_letters_config(p_lobby_id uuid, p_me_player_id uuid, p_cfg jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_host uuid; v_phase text; v_cats int; v_secs int; v_off jsonb;
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_me_player_id) THEN RAISE EXCEPTION 'invalid_session'; END IF;
  SELECT host_player_id, phase INTO v_host, v_phase FROM public.lobbies WHERE id = p_lobby_id;
  IF v_host IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
  IF v_host IS DISTINCT FROM p_me_player_id THEN RAISE EXCEPTION 'not_host'; END IF;
  IF v_phase NOT IN ('waiting', 'finished') THEN RAISE EXCEPTION 'lobby_not_waiting'; END IF;
  IF jsonb_typeof(coalesce(p_cfg, 'null'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
  BEGIN
    v_cats := (p_cfg ->> 'cats')::int;
    v_secs := (p_cfg ->> 'secs')::int;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'letters_bad_config';
  END;
  IF v_cats IS NULL OR v_cats NOT BETWEEN 1 AND 5 OR v_secs IS NULL OR v_secs NOT IN (30, 45, 60, 90) THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
  IF jsonb_typeof(coalesce(p_cfg -> 'off', '[]'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
  -- nur echte Kategorienamen übernehmen
  SELECT coalesce(jsonb_agg(c.name ORDER BY c.name), '[]'::jsonb) INTO v_off FROM public.word_categories c WHERE c.active AND (p_cfg -> 'off') @> to_jsonb(c.name);
  IF cardinality(public._letters_letters(v_off, v_cats + 2)) < 3 THEN RAISE EXCEPTION 'letters_too_few_categories'; END IF;
  UPDATE public.lobbies
     SET letters_cfg = jsonb_build_object('cats', v_cats, 'secs', v_secs, 'off', v_off), settings_version = coalesce(settings_version, 0) + 1
   WHERE id = p_lobby_id;
END $$;

-- Alle Kategorien (für die Auswahl in der Lobby)
CREATE OR REPLACE FUNCTION public.get_letters_categories() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(jsonb_agg(name ORDER BY name), '[]'::jsonb) FROM public.word_categories WHERE active
$$;

-- Erfolge (nur gewertete Spiele = mindestens 2 Menschen)
CREATE OR REPLACE FUNCTION public._award_roulette_achievements(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF public._lobby_human_count(p_lobby_id) < 2 THEN RETURN; END IF;
  INSERT INTO public.player_achievements (user_id, achievement_code, lobby_id)
  SELECT u.user_id, a.code, p_lobby_id
    FROM (SELECT DISTINCT p.user_id FROM public.players p WHERE p.lobby_id = p_lobby_id AND p.user_id IS NOT NULL AND NOT coalesce(p.is_bot, false)) u
    JOIN public.achievements a ON a.code IN ('roulette_win', 'roulette_words_100', 'roulette_haul_12')
   WHERE (a.code = 'roulette_win' AND EXISTS (SELECT 1 FROM public.roulette_matches m WHERE m.user_id = u.user_id AND m.ranked AND m.place = 1))
      OR (a.code = 'roulette_words_100' AND (SELECT coalesce(sum(r.correct), 0) FROM public.roulette_rounds r WHERE r.user_id = u.user_id AND r.ranked) >= 100)
      OR (a.code = 'roulette_haul_12' AND EXISTS (SELECT 1 FROM public.roulette_rounds r WHERE r.user_id = u.user_id AND r.ranked AND r.correct >= 12))
  ON CONFLICT (user_id, achievement_code) DO NOTHING;
END $$;

-- Eine fertige Kategorie für alle angemeldeten Menschen festhalten
CREATE OR REPLACE FUNCTION public._letters_record_round(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_humans int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id;
  IF l.quiz_reveal ->> 'category' IS NULL THEN RETURN; END IF;
  v_humans := public._lobby_human_count(p_lobby_id);
  WITH cnt AS (
    SELECT p.player_id, p.user_id, coalesce(p.is_bot, false) AS is_bot,
           count(*) FILTER (WHERE e.valid) AS correct,
           count(*) FILTER (WHERE e.norm IS NOT NULL AND NOT coalesce(e.valid, false) AND NOT e.dup) AS bad,
           count(*) FILTER (WHERE e.dup) AS dup
      FROM public.players p
      LEFT JOIN public.letters_entries e ON e.lobby_id = p.lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id
     WHERE p.lobby_id = p_lobby_id AND p.status = 'active'
     GROUP BY p.player_id, p.user_id, p.is_bot
  )
  INSERT INTO public.roulette_rounds (user_id, lobby_id, run_key, idx, category, letter, correct, bad, dup, place, humans, ranked)
  SELECT c.user_id, p_lobby_id, l.run_started_at, l.quiz_index, l.quiz_reveal ->> 'category', l.quiz_reveal ->> 'letter',
         c.correct, c.bad, c.dup, 1 + (SELECT count(*) FROM cnt c2 WHERE c2.correct > c.correct), v_humans, v_humans >= 2
    FROM cnt c WHERE c.user_id IS NOT NULL AND NOT c.is_bot AND l.run_started_at IS NOT NULL
  ON CONFLICT DO NOTHING;
  PERFORM public._award_roulette_achievements(p_lobby_id);
END $$;

-- Das fertige Spiel festhalten (nach der Wertung: Platz aus series_results)
CREATE OR REPLACE FUNCTION public._letters_record_match(p_lobby_id uuid, p_run timestamptz, p_total int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_humans int;
BEGIN
  IF p_run IS NULL THEN RETURN; END IF;
  v_humans := public._lobby_human_count(p_lobby_id);
  INSERT INTO public.roulette_matches (user_id, lobby_id, run_key, place, total, humans, ranked, categories)
  SELECT p.user_id, p_lobby_id, p_run,
         coalesce((SELECT sr.place FROM public.series_results sr WHERE sr.lobby_id = p_lobby_id AND sr.player_id = p.player_id ORDER BY sr.set_index DESC LIMIT 1), 99),
         coalesce(p.song_points, 0)::int, v_humans, v_humans >= 2, p_total
    FROM public.players p
   WHERE p.lobby_id = p_lobby_id AND p.status = 'active' AND p.user_id IS NOT NULL AND NOT coalesce(p.is_bot, false)
  ON CONFLICT DO NOTHING;
  PERFORM public._award_roulette_achievements(p_lobby_id);
END $$;

CREATE OR REPLACE FUNCTION public._quiz_next(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_ids uuid[];
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RETURN; END IF;
  -- 127: Roulette – nächste Kategorie oder Ende nach 3 Kategorien
  IF l.game_mode = 'letters' THEN
    -- 130: Runde (und am Ende das Match) für Statistik und Erfolge festhalten – die Einsprüche sind dann entschieden
    PERFORM public._letters_record_round(p_lobby_id);
    IF l.quiz_index >= l.quiz_total THEN
      PERFORM public._quiz_finish(p_lobby_id);
      PERFORM public._letters_record_match(p_lobby_id, l.run_started_at, l.quiz_total);
    ELSE
      PERFORM public._letters_start_vote(p_lobby_id);
    END IF;
    RETURN;
  END IF;
  IF l.quiz_target IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active' AND coalesce(song_points, 0) >= l.quiz_target) THEN
    PERFORM public._quiz_finish(p_lobby_id); RETURN;
  END IF;
  IF l.quiz_index >= l.quiz_total THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  v_ids := public._quiz_candidates(p_lobby_id, l.game_mode, 1);
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  UPDATE public.lobbies SET quiz_index = quiz_index + 1 WHERE id = p_lobby_id;
  PERFORM public._quiz_start_question(p_lobby_id, v_ids[1]);
END $$;

-- Eigene Roulette-Auswertung (Profil > Statistik)
CREATE OR REPLACE FUNCTION public.get_my_roulette_stats() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_logged_in'; END IF;
  RETURN jsonb_build_object(
    'matches', (SELECT count(*) FROM public.roulette_matches WHERE user_id = v_uid AND ranked),
    'wins', (SELECT count(*) FROM public.roulette_matches WHERE user_id = v_uid AND ranked AND place = 1),
    'practiceMatches', (SELECT count(*) FROM public.roulette_matches WHERE user_id = v_uid AND NOT ranked),
    'rounds', (SELECT count(*) FROM public.roulette_rounds WHERE user_id = v_uid),
    'words', (SELECT coalesce(sum(correct), 0) FROM public.roulette_rounds WHERE user_id = v_uid),
    'bad', (SELECT coalesce(sum(bad), 0) FROM public.roulette_rounds WHERE user_id = v_uid),
    'bestRound', (SELECT jsonb_build_object('correct', r.correct, 'category', r.category, 'letter', r.letter)
                    FROM public.roulette_rounds r WHERE r.user_id = v_uid ORDER BY r.correct DESC, r.played_at DESC LIMIT 1),
    'categories', coalesce((SELECT jsonb_agg(x ORDER BY (x ->> 'rounds')::int DESC, x ->> 'name') FROM (
        SELECT jsonb_build_object('name', category, 'rounds', count(*), 'words', sum(correct), 'best', max(correct), 'avg', round(avg(correct)::numeric, 1)) AS x
          FROM public.roulette_rounds WHERE user_id = v_uid GROUP BY category) q), '[]'::jsonb),
    'recent', coalesce((SELECT jsonb_agg(jsonb_build_object('category', category, 'letter', letter, 'correct', correct, 'place', place, 'ranked', ranked, 'at', played_at) ORDER BY played_at DESC)
                          FROM (SELECT * FROM public.roulette_rounds WHERE user_id = v_uid ORDER BY played_at DESC LIMIT 8) t), '[]'::jsonb)
  );
END $$;

REVOKE ALL ON FUNCTION public._letters_cfg(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_letters(jsonb, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._award_roulette_achievements(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_record_round(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_record_match(uuid, timestamptz, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_letters_config(uuid, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_letters_categories() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_roulette_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_letters_config(uuid, uuid, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_letters_categories() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_roulette_stats() TO authenticated;

COMMIT;
