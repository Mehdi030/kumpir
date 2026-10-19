-- ============================================================
-- 129: Roulette – Einspruch gegen zu Unrecht rote Wörter (Wunsch Mehdi, 2026-10-19)
-- ============================================================
-- Wer ein rotes Wort für richtig hält, legt Einspruch ein (nur für eigene rote Wörter, solange die Wörter-Karte steht). Die ANDEREN
-- Menschen stimmen mit Daumen hoch/runter ab: mehr als die Hälfte von ihnen "ja" = angenommen (Wort wird grün, +1 Punkt,
-- Ergebnisliste und Gesamtpunkte werden angepasst); die Hälfte oder mehr "nein" = abgelehnt. Wer nicht abstimmt, zählt als "nein"
-- (nicht entschieden bis Fensterende = abgelehnt). Gibt es keinen anderen Menschen (Übung gegen Bots), gilt der Einspruch sofort.
-- Die Wörter-Karte steht 13 s statt 7 s, wenn ein Mensch rote Wörter hat; Einsprüche sind bis 1 s vor Ende der Karte möglich.
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.letters_appeals (
  lobby_id uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  seq int NOT NULL,
  owner_id uuid NOT NULL,
  norm text NOT NULL,
  text text NOT NULL,
  yes uuid[] NOT NULL DEFAULT '{}',
  no uuid[] NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lobby_id, seq, owner_id, norm)
);
ALTER TABLE public.letters_appeals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.letters_appeals FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._letters_reveal(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_letter char(1); v_cat uuid; v_cat_name text; b record; v_n int; v_results jsonb; v_players int; v_secs numeric; v_map int;
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
  -- 129: haben Menschen rote Wörter, bleibt die Wörter-Karte länger stehen (Einspruch möglich)
  v_map := CASE WHEN EXISTS (SELECT 1 FROM public.letters_entries e JOIN public.players p ON p.lobby_id = e.lobby_id AND p.player_id = e.player_id
                              WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND NOT coalesce(e.valid, false) AND NOT e.dup AND NOT coalesce(p.is_bot, false))
                THEN 13 ELSE 7 END;
  v_secs := v_map + (1 + 2.2 * v_players + 1.5) + CASE WHEN l.quiz_index >= l.quiz_total THEN (1 + 2.2 * v_players + 1.5) ELSE 0 END + 3;
  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('letter', upper(v_letter), 'category', v_cat_name, 'index', l.quiz_index, 'last', l.quiz_index >= l.quiz_total, 'mapSecs', v_map, 'results', v_results),
         quiz_started_at = now(), quiz_ends_at = now() + least(v_secs, 100) * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Ergebnisliste (aufsteigend nach Punkten) für eine Kategorie neu zusammenbauen
CREATE OR REPLACE FUNCTION public._letters_results(p_lobby_id uuid, p_seq int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_results jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY (r ->> 'points')::int ASC, r ->> 'name'), '[]') INTO v_results FROM (
    SELECT jsonb_build_object(
             'playerId', p.player_id, 'name', p.name,
             'points', (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.valid),
             'valid', (SELECT coalesce(jsonb_agg(jsonb_build_object('t', e.text, 'l', e.label) ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.valid),
             'bad', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND NOT coalesce(e.valid, false) AND NOT e.dup),
             'dup', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.dup)
           ) AS r
      FROM public.players p WHERE p.lobby_id = p_lobby_id AND p.status = 'active'
  ) x;
  RETURN v_results;
END $$;

-- Einspruch auswerten: angenommen / abgelehnt / noch offen
CREATE OR REPLACE FUNCTION public._letters_appeal_eval(p_lobby_id uuid, p_seq int, p_owner uuid, p_norm text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a public.letters_appeals%ROWTYPE; v_others int;
BEGIN
  SELECT * INTO a FROM public.letters_appeals WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm FOR UPDATE;
  IF NOT FOUND OR a.status <> 'open' THEN RETURN; END IF;
  SELECT count(*) INTO v_others FROM public.players
   WHERE lobby_id = p_lobby_id AND status = 'active' AND NOT coalesce(is_bot, false) AND player_id <> p_owner;
  IF v_others = 0 OR cardinality(a.yes) * 2 > v_others THEN
    UPDATE public.letters_appeals SET status = 'accepted' WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm;
    UPDATE public.letters_entries SET valid = true, dup = false, label = a.text
     WHERE lobby_id = p_lobby_id AND seq = p_seq AND player_id = p_owner AND norm = p_norm AND NOT coalesce(valid, false);
    IF FOUND THEN
      UPDATE public.players SET song_points = coalesce(song_points, 0) + 1 WHERE lobby_id = p_lobby_id AND player_id = p_owner;
      UPDATE public.lobbies SET quiz_reveal = jsonb_set(quiz_reveal, '{results}', public._letters_results(p_lobby_id, p_seq)) WHERE id = p_lobby_id;
    END IF;
  ELSIF cardinality(a.no) * 2 >= v_others THEN
    UPDATE public.letters_appeals SET status = 'rejected' WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm;
  END IF;
END $$;

-- Einspruch einlegen (nur eigenes rotes Wort, nur solange die Wörter-Karte steht)
CREATE OR REPLACE FUNCTION public._letters_do_appeal(p_lobby_id uuid, p_player_id uuid, p_text text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_norm text; v_clean text; v_added int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'letters' OR l.quiz_state <> 'reveal' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF now() > l.quiz_started_at + (coalesce((l.quiz_reveal ->> 'mapSecs')::int, 7) - 1) * interval '1 second' THEN RAISE EXCEPTION 'appeal_closed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active' AND NOT coalesce(is_bot, false)) THEN RAISE EXCEPTION 'not_a_member'; END IF;
  PERFORM public._rate_limit('lappeal:' || p_player_id::text, 40, 60);
  v_clean := left(trim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), 40);
  v_norm := public._ans_norm(v_clean);
  IF NOT EXISTS (SELECT 1 FROM public.letters_entries WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id AND norm = v_norm
                    AND NOT coalesce(valid, false) AND NOT dup) THEN RAISE EXCEPTION 'appeal_not_possible'; END IF;
  INSERT INTO public.letters_appeals (lobby_id, seq, owner_id, norm, text) VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_norm, v_clean) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  IF v_added > 0 THEN
    PERFORM public._letters_appeal_eval(p_lobby_id, l.quiz_seq, p_player_id, v_norm);
    UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  END IF;
  RETURN jsonb_build_object('appealed', v_added > 0);
END $$;

-- Über einen Einspruch abstimmen (Daumen hoch = p_yes true); nicht über die eigenen
CREATE OR REPLACE FUNCTION public._letters_do_appeal_vote(p_lobby_id uuid, p_player_id uuid, p_owner uuid, p_text text, p_yes boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_norm text; v_status text;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'letters' OR l.quiz_state <> 'reveal' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF now() > l.quiz_started_at + (coalesce((l.quiz_reveal ->> 'mapSecs')::int, 7) - 1) * interval '1 second' THEN RAISE EXCEPTION 'appeal_closed'; END IF;
  IF p_player_id = p_owner THEN RAISE EXCEPTION 'appeal_own'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active' AND NOT coalesce(is_bot, false)) THEN RAISE EXCEPTION 'not_a_member'; END IF;
  PERFORM public._rate_limit('lappeal:' || p_player_id::text, 40, 60);
  v_norm := public._ans_norm(left(trim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), 40));
  SELECT status INTO v_status FROM public.letters_appeals WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND owner_id = p_owner AND norm = v_norm;
  IF v_status IS NULL OR v_status <> 'open' THEN RAISE EXCEPTION 'appeal_not_possible'; END IF;
  UPDATE public.letters_appeals
     SET yes = CASE WHEN p_yes THEN array_append(array_remove(yes, p_player_id), p_player_id) ELSE array_remove(yes, p_player_id) END,
         no  = CASE WHEN p_yes THEN array_remove(no, p_player_id) ELSE array_append(array_remove(no, p_player_id), p_player_id) END
   WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND owner_id = p_owner AND norm = v_norm;
  PERFORM public._letters_appeal_eval(p_lobby_id, l.quiz_seq, p_owner, v_norm);
  UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  RETURN jsonb_build_object('voted', true);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_letters_appeal(p_code text, p_player_id uuid, p_text text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public._letters_do_appeal(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_text); END $$;

CREATE OR REPLACE FUNCTION public.rpc_letters_appeal_vote(p_code text, p_player_id uuid, p_owner uuid, p_text text, p_yes boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public._letters_do_appeal_vote(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_owner, p_text, p_yes); END $$;

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
    -- 129: Einsprüche gegen rote Wörter (Besitzer, Text, Ja-/Nein-Stimmen, Stand)
    'appeals', CASE WHEN l.game_mode = 'letters' AND l.quiz_state = 'reveal'
                    THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('o', a.owner_id, 't', a.text, 'y', to_jsonb(a.yes), 'n', to_jsonb(a.no), 's', a.status) ORDER BY a.created_at), '[]')
                            FROM public.letters_appeals a WHERE a.lobby_id = v_id AND a.seq = l.quiz_seq)
                    ELSE '[]'::jsonb END,
    'seq', l.quiz_seq,
    'me', coalesce(v_me, jsonb_build_object('answered', false)),
    -- Jahr raten: wer schon getippt hat (ohne die Jahre selbst – die sieht man erst bei der Auflösung)
    'answered', CASE WHEN l.game_mode = 'year'
                     THEN (SELECT coalesce(jsonb_agg(player_id), '[]') FROM public.quiz_answers WHERE lobby_id = v_id AND seq = l.quiz_seq AND (l.quiz_state <> 'month' OR month IS NOT NULL))
                     ELSE '[]'::jsonb END
  );
END $$;

REVOKE ALL ON FUNCTION public._letters_results(uuid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_appeal_eval(uuid, int, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_do_appeal(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_do_appeal_vote(uuid, uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_letters_appeal(text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_letters_appeal_vote(text, uuid, uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_letters_appeal(text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_letters_appeal_vote(text, uuid, uuid, text, boolean) TO anon, authenticated;

COMMIT;
