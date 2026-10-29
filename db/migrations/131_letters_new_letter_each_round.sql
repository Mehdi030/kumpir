-- ============================================================
-- 131: Roulette – jede Kategorie bekommt einen NEUEN Buchstaben (Wunsch Mehdi, 2026-10-29)
-- ============================================================
-- Vorher: ein Buchstabe fürs ganze Spiel, dazwischen nur eine Abstimmung. Jetzt: nach jeder Auflösung dreht das Roulette wieder
-- (Zustand 'spin'), zieht einen anderen Buchstaben (bisher benutzte werden vermieden) und zeigt dazu drei neue Kategorien zur
-- Abstimmung. Es kommen nur Kategorien in Frage, die für den neuen Buchstaben mindestens 6 Begriffe haben, noch nicht gespielt
-- wurden und vom Host nicht ausgeschlossen sind. quiz_options.letters = bisher gezogene Buchstaben.
-- ============================================================
BEGIN;

-- Nächster Buchstabe: mindestens 3 erlaubte, noch nicht gespielte Kategorien mit je 6+ Begriffen; bevorzugt einer, der noch nicht dran war
CREATE OR REPLACE FUNCTION public._letters_next_letter(p_lobby_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_off jsonb; v_played jsonb; v_used jsonb; v_all text[]; v_new text[];
BEGIN
  SELECT coalesce(letters_cfg -> 'off', '[]'::jsonb), coalesce(quiz_options -> 'played', '[]'::jsonb), coalesce(quiz_options -> 'letters', '[]'::jsonb)
    INTO v_off, v_played, v_used FROM public.lobbies WHERE id = p_lobby_id;
  SELECT coalesce(array_agg(z.initial::text), '{}'::text[]) INTO v_all FROM (
    SELECT cov.initial FROM (
      SELECT t.category_id, t.initial FROM public.word_terms t
        JOIN public.word_categories c ON c.id = t.category_id AND c.active
         AND NOT (v_off @> to_jsonb(c.name)) AND NOT (v_played @> to_jsonb(c.id::text))
       GROUP BY t.category_id, t.initial HAVING count(DISTINCT t.label) >= 6
    ) cov GROUP BY cov.initial HAVING count(*) >= 3
  ) z;
  SELECT coalesce(array_agg(x), '{}'::text[]) INTO v_new FROM unnest(v_all) x WHERE NOT (v_used @> to_jsonb(upper(x)));
  IF cardinality(v_new) > 0 THEN RETURN v_new[1 + floor(random() * cardinality(v_new))::int]; END IF;
  IF cardinality(v_all) > 0 THEN RETURN v_all[1 + floor(random() * cardinality(v_all))::int]; END IF;
  RETURN lower(coalesce((SELECT quiz_options ->> 'letter' FROM public.lobbies WHERE id = p_lobby_id), 'a'));
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
         quiz_options = jsonb_build_object('letter', upper(v_letter), 'played', '[]'::jsonb, 'letters', jsonb_build_array(upper(v_letter)), 'slot', 1, 'tally', jsonb_build_array(0, 0, 0)),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'spin') * interval '1 second',
         quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
  UPDATE public.lobbies SET quiz_options = quiz_options || jsonb_build_object('cands', public._letters_pick_cands(p_lobby_id)) WHERE id = p_lobby_id;
END $$;

-- Nach der Auflösung: das Roulette dreht erneut (neuer Buchstabe) und die nächste Abstimmung (drei neue Kategorien) öffnet sich
CREATE OR REPLACE FUNCTION public._letters_start_vote(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter text;
BEGIN
  v_letter := public._letters_next_letter(p_lobby_id);
  UPDATE public.lobbies
     SET quiz_state = 'spin', quiz_seq = quiz_seq + 1, quiz_reveal = NULL,
         quiz_options = (quiz_options - 'cat') || jsonb_build_object(
           'letter', upper(v_letter),
           'letters', coalesce(quiz_options -> 'letters', '[]'::jsonb) || to_jsonb(upper(v_letter)),
           'slot', quiz_index + 1, 'tally', jsonb_build_array(0, 0, 0)),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'spin') * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
  UPDATE public.lobbies SET quiz_options = quiz_options || jsonb_build_object('cands', public._letters_pick_cands(p_lobby_id)) WHERE id = p_lobby_id;
END $$;

REVOKE ALL ON FUNCTION public._letters_next_letter(uuid) FROM PUBLIC;

COMMIT;
