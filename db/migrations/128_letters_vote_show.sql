-- ============================================================
-- 128: Roulette – Kategorien per Abstimmung, Wörter-Karte, Wertungs-Show (Wunsch Mehdi, 2026-10-19)
-- ============================================================
-- Ablauf neu: Das Roulette dreht sich (Buchstabe), währenddessen erscheinen unten DREI Kategorien zur Abstimmung; die Mehrheit
-- bestimmt die erste. Nach jeder Auflösung wieder drei NEUE, verschiedene Kategorien (Zustand 'vote'), Mehrheit entscheidet,
-- Gleichstand = Los, Bots stimmen zufällig. Bereits gespielte Kategorien kommen nicht noch einmal.
-- Die Auflösung liefert alle Eingaben aller Spieler (richtig mit Schreibweise + Begriff, falsch, doppelt) für die Wörter-Karte
-- und dauert so lange, wie die Wertungs-Show (Trommelwirbel, Konfetti) für alle Spieler braucht.
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.letters_votes (
  lobby_id uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  slot int NOT NULL,
  player_id uuid NOT NULL,
  choice int NOT NULL CHECK (choice BETWEEN 1 AND 3),
  PRIMARY KEY (lobby_id, slot, player_id)
);
ALTER TABLE public.letters_votes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.letters_votes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._quiz_seconds(p_mode text, p_state text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state
    WHEN 'reveal' THEN CASE p_mode WHEN 'year' THEN 8 WHEN 'letters' THEN 20 ELSE 5 END
    WHEN 'spin' THEN CASE p_mode WHEN 'letters' THEN 13 ELSE 8 END
    WHEN 'vote' THEN 12
    WHEN 'buzzed' THEN 7
    WHEN 'month' THEN 12
    ELSE CASE p_mode WHEN 'year' THEN 20 WHEN 'letters' THEN 45 ELSE 30 END
  END::numeric
$$;

-- Drei verschiedene Kategorien zur Auswahl ziehen (Buchstabe steht fest, gespielte Kategorien ausgenommen)
CREATE OR REPLACE FUNCTION public._letters_pick_cands(p_lobby_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter text; v_played jsonb; v_cands jsonb;
BEGIN
  SELECT lower(quiz_options ->> 'letter'), coalesce(quiz_options -> 'played', '[]'::jsonb) INTO v_letter, v_played FROM public.lobbies WHERE id = p_lobby_id;
  SELECT jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name)) INTO v_cands FROM (
    SELECT c.id, c.name FROM public.word_categories c
     WHERE c.active AND NOT (v_played @> to_jsonb(c.id::text))
       AND (SELECT count(DISTINCT t.label) FROM public.word_terms t WHERE t.category_id = c.id AND t.initial = v_letter) >= 6
     ORDER BY random() LIMIT 3
  ) x;
  RETURN coalesce(v_cands, '[]'::jsonb);
END $$;

-- Roulette starten: Buchstabe ziehen (nur Buchstaben mit mindestens 5 Kategorien à 6+ Begriffen) und die erste Abstimmung öffnen
CREATE OR REPLACE FUNCTION public._letters_spin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter char(1);
BEGIN
  DELETE FROM public.letters_votes WHERE lobby_id = p_lobby_id;
  WITH cov AS (
    SELECT t.category_id, t.initial FROM public.word_terms t JOIN public.word_categories c ON c.id = t.category_id AND c.active
     GROUP BY t.category_id, t.initial HAVING count(DISTINCT t.label) >= 6
  )
  SELECT initial INTO v_letter FROM cov GROUP BY initial HAVING count(*) >= 5 ORDER BY random() LIMIT 1;
  IF v_letter IS NULL THEN RAISE EXCEPTION 'letters_no_words'; END IF;
  UPDATE public.lobbies
     SET phase = 'quiz', quiz_state = 'spin', quiz_index = 0, quiz_seq = quiz_seq + 1,
         quiz_options = jsonb_build_object('letter', upper(v_letter), 'played', '[]'::jsonb, 'slot', 1, 'tally', jsonb_build_array(0, 0, 0)),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'spin') * interval '1 second',
         quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
  UPDATE public.lobbies SET quiz_options = quiz_options || jsonb_build_object('cands', public._letters_pick_cands(p_lobby_id)) WHERE id = p_lobby_id;
END $$;

-- Nach der Auflösung: nächste Abstimmung (drei neue Kategorien)
CREATE OR REPLACE FUNCTION public._letters_start_vote(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.lobbies
     SET quiz_state = 'vote', quiz_seq = quiz_seq + 1, quiz_reveal = NULL,
         quiz_options = (quiz_options - 'cat') || jsonb_build_object('slot', quiz_index + 1, 'tally', jsonb_build_array(0, 0, 0)),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'vote') * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
  UPDATE public.lobbies SET quiz_options = quiz_options || jsonb_build_object('cands', public._letters_pick_cands(p_lobby_id)) WHERE id = p_lobby_id;
END $$;

-- Abstimmung auswerten (Mehrheit, Gleichstand = Los, Bots stimmen zufällig) und die Kategorie starten
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
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'question') * interval '1 second',
         quiz_reveal = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Stimme für eine der drei Kategorien (1–3); umentscheiden ist erlaubt. Haben alle Menschen gewählt, geht es früher weiter
CREATE OR REPLACE FUNCTION public._letters_do_vote(p_lobby_id uuid, p_player_id uuid, p_choice int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_slot int; v_tally jsonb; v_left int; v_min timestamptz;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'letters' OR l.quiz_state NOT IN ('spin', 'vote') THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF p_choice NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'quiz_bad_choice'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active') THEN RAISE EXCEPTION 'not_a_member'; END IF;
  PERFORM public._rate_limit('lvote:' || p_player_id::text, 60, 60);
  v_slot := coalesce((l.quiz_options ->> 'slot')::int, 1);
  INSERT INTO public.letters_votes (lobby_id, slot, player_id, choice) VALUES (p_lobby_id, v_slot, p_player_id, p_choice)
  ON CONFLICT (lobby_id, slot, player_id) DO UPDATE SET choice = excluded.choice;
  SELECT jsonb_build_array(
           count(*) FILTER (WHERE v.choice = 1), count(*) FILTER (WHERE v.choice = 2), count(*) FILTER (WHERE v.choice = 3)) INTO v_tally
    FROM public.letters_votes v JOIN public.players p ON p.lobby_id = v.lobby_id AND p.player_id = v.player_id AND p.status = 'active'
   WHERE v.lobby_id = p_lobby_id AND v.slot = v_slot;
  UPDATE public.lobbies SET quiz_options = quiz_options || jsonb_build_object('tally', v_tally), quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  SELECT count(*) INTO v_left FROM public.players p
   WHERE p.lobby_id = p_lobby_id AND p.status = 'active' AND NOT coalesce(p.is_bot, false)
     AND NOT EXISTS (SELECT 1 FROM public.letters_votes v WHERE v.lobby_id = p_lobby_id AND v.slot = v_slot AND v.player_id = p.player_id);
  IF v_left = 0 THEN
    -- beim Roulette erst, wenn die Walze durch ist (mindestens 7 Sekunden)
    v_min := CASE WHEN l.quiz_state = 'spin' THEN l.quiz_started_at + interval '7 seconds' ELSE now() END;
    UPDATE public.lobbies SET quiz_ends_at = least(quiz_ends_at, greatest(v_min, now() + interval '800 milliseconds')) WHERE id = p_lobby_id;
  END IF;
  RETURN jsonb_build_object('choice', p_choice);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_letters_vote(p_code text, p_player_id uuid, p_choice int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public._letters_do_vote(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_choice); END $$;

-- Auflösung: Bots tippen, alle Eingaben prüfen, Punkte, Ergebnisse (aufsteigend: Letzter zuerst) mit allen Eingaben für die Wörter-Karte
CREATE OR REPLACE FUNCTION public._letters_reveal(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_letter char(1); v_cat uuid; v_cat_name text; b record; v_n int; v_results jsonb; v_players int; v_secs numeric;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  v_letter := lower(l.quiz_options ->> 'letter');
  v_cat := (l.quiz_options -> 'cat' ->> 'id')::uuid;
  v_cat_name := l.quiz_options -> 'cat' ->> 'name';

  -- Bots: je nach Stärke ein paar zufällige, richtige Begriffe
  FOR b IN SELECT player_id, coalesce(bot_skill, 2) AS skill FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active' AND is_bot LOOP
    v_n := CASE b.skill WHEN 1 THEN 2 + floor(random() * 4)::int WHEN 3 THEN 7 + floor(random() * 6)::int ELSE 4 + floor(random() * 5)::int END;
    INSERT INTO public.letters_entries (lobby_id, seq, player_id, text, norm, label, valid)
    SELECT p_lobby_id, l.quiz_seq, b.player_id, x.label, x.key_norm, x.label, true FROM (
      SELECT DISTINCT ON (t.label) t.label, t.key_norm FROM public.word_terms t
       WHERE t.category_id = v_cat AND t.initial = v_letter ORDER BY t.label, random()
    ) x ORDER BY random() LIMIT v_n
    ON CONFLICT DO NOTHING;
  END LOOP;

  -- Menschen: jede Eingabe gegen die Liste prüfen (exakt oder mit kleinem Tippfehler). Der Begriff muss zum Buchstaben passen:
  -- mindestens eine seiner Schreibweisen (bei Personen Vor- oder Nachname, bei Vereinen mit/ohne "FC" …) beginnt damit.
  UPDATE public.letters_entries e
     SET label = m.label, valid = (m.label IS NOT NULL)
    FROM public.letters_entries e2
    LEFT JOIN LATERAL (
      SELECT t.label FROM public.word_terms t
       WHERE t.category_id = v_cat AND t.initial = left(e2.norm, 1) AND abs(length(t.key_norm) - length(e2.norm)) <= 3
         AND (t.key_norm = e2.norm OR public._ans_close(t.key_norm, e2.norm))
         AND EXISTS (SELECT 1 FROM public.word_terms q WHERE q.category_id = v_cat AND q.label = t.label AND q.initial = v_letter)
       ORDER BY (t.key_norm = e2.norm) DESC, abs(length(t.key_norm) - length(e2.norm)) LIMIT 1
    ) m ON true
   WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.valid IS NULL
     AND e2.lobby_id = e.lobby_id AND e2.seq = e.seq AND e2.player_id = e.player_id AND e2.norm = e.norm;

  -- derselbe Begriff zweimal (z. B. "Bayern" und "Bayern München") zählt nur einmal
  UPDATE public.letters_entries e SET valid = false, dup = true
    FROM (SELECT lobby_id, seq, player_id, norm, row_number() OVER (PARTITION BY player_id, label ORDER BY created_at, norm) AS rn
            FROM public.letters_entries WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND valid) d
   WHERE e.lobby_id = d.lobby_id AND e.seq = d.seq AND e.player_id = d.player_id AND e.norm = d.norm AND d.rn > 1;

  -- Punkte = richtige, verschiedene Begriffe
  UPDATE public.players p SET song_points = coalesce(p.song_points, 0) + c.n
    FROM (SELECT player_id, count(*) AS n FROM public.letters_entries WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND valid GROUP BY player_id) c
   WHERE p.lobby_id = p_lobby_id AND p.player_id = c.player_id;

  SELECT coalesce(jsonb_agg(r ORDER BY (r ->> 'points')::int ASC, r ->> 'name'), '[]'), count(*)::int INTO v_results, v_players FROM (
    SELECT jsonb_build_object(
             'playerId', p.player_id, 'name', p.name,
             'points', (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND e.valid),
             'valid', (SELECT coalesce(jsonb_agg(jsonb_build_object('t', e.text, 'l', e.label) ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND e.valid),
             'bad', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND NOT coalesce(e.valid, false) AND NOT e.dup),
             'dup', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND e.dup)
           ) AS r
      FROM public.players p WHERE p.lobby_id = p_lobby_id AND p.status = 'active'
  ) x;

  -- Dauer: Wörter-Karte 7 s + Wertungs-Show (Trommelwirbel 1 s + 2,2 s je Platz + 1,5 s für den Sieger); nach der letzten Kategorie zusätzlich die Gesamtwertung
  v_secs := 7 + (1 + 2.2 * v_players + 1.5) + CASE WHEN l.quiz_index >= l.quiz_total THEN (1 + 2.2 * v_players + 1.5) ELSE 0 END + 3;
  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('letter', upper(v_letter), 'category', v_cat_name, 'index', l.quiz_index, 'last', l.quiz_index >= l.quiz_total, 'results', v_results),
         quiz_started_at = now(), quiz_ends_at = now() + least(v_secs, 100) * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_next(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_ids uuid[];
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RETURN; END IF;
  -- 127: Roulette – nächste Kategorie oder Ende nach 3 Kategorien
  IF l.game_mode = 'letters' THEN
    IF l.quiz_index >= l.quiz_total THEN PERFORM public._quiz_finish(p_lobby_id); ELSE PERFORM public._letters_start_vote(p_lobby_id); END IF;
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
  ELSIF l.quiz_state IN ('spin', 'vote') THEN
    PERFORM public._letters_begin_category(p_lobby_id);
  ELSIF l.quiz_state IN ('question', 'month') THEN
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSIF l.quiz_state = 'reveal' THEN
    PERFORM public._quiz_next(p_lobby_id);
  END IF;
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
    -- 127: Roulette – meine bisherigen Eingaben (nur meine) und wer schon "fertig" gedrückt hat
    'mine', CASE WHEN l.game_mode = 'letters'
                 THEN (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = v_id AND e.seq = l.quiz_seq AND e.player_id = p_player_id)
                 ELSE '[]'::jsonb END,
    'done', CASE WHEN l.game_mode = 'letters'
                 THEN (SELECT coalesce(jsonb_agg(d.player_id), '[]') FROM public.letters_done d WHERE d.lobby_id = v_id AND d.seq = l.quiz_seq)
                 ELSE '[]'::jsonb END,
    -- 128: meine Stimme bei der Kategorie-Abstimmung (Roulette)
    'myvote', CASE WHEN l.game_mode = 'letters' AND l.quiz_state IN ('spin', 'vote')
                   THEN (SELECT v.choice FROM public.letters_votes v WHERE v.lobby_id = v_id AND v.slot = coalesce((l.quiz_options ->> 'slot')::int, 1) AND v.player_id = p_player_id)
                   ELSE NULL END,
    'voted', CASE WHEN l.game_mode = 'letters' AND l.quiz_state IN ('spin', 'vote')
                  THEN (SELECT coalesce(jsonb_agg(v.player_id), '[]') FROM public.letters_votes v WHERE v.lobby_id = v_id AND v.slot = coalesce((l.quiz_options ->> 'slot')::int, 1))
                  ELSE '[]'::jsonb END,
    'seq', l.quiz_seq,
    'me', coalesce(v_me, jsonb_build_object('answered', false)),
    -- Jahr raten: wer schon getippt hat (ohne die Jahre selbst – die sieht man erst bei der Auflösung)
    'answered', CASE WHEN l.game_mode = 'year'
                     THEN (SELECT coalesce(jsonb_agg(player_id), '[]') FROM public.quiz_answers WHERE lobby_id = v_id AND seq = l.quiz_seq AND (l.quiz_state <> 'month' OR month IS NOT NULL))
                     ELSE '[]'::jsonb END
  );
END $$;

REVOKE ALL ON FUNCTION public.rpc_letters_vote(text, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_letters_vote(text, uuid, int) TO anon, authenticated;

COMMIT;
