-- ============================================================
-- 134: Roulette – eigene Kategorien, Schwierigkeit, "Hättest du's gewusst?" (Wunsch Mehdi, 2026-11-02)
-- ============================================================
-- * Eigene Kategorien: Der Host legt in der Lobby bis zu 3 eigene Kategorien an (Name + Begriffe). Sie gelten nur für diese Lobby
--   (word_categories.owner_lobby, wird mit der Lobby gelöscht), kommen mit Vorrang zur Abstimmung und werden wie die anderen geprüft.
--   Die Begriffe stehen nur auf dem Server (Spieler sehen nur Name und Anzahl in letters_cfg.custom).
-- * Abstimmungs-Karten bekommen n (Anzahl bekannter Begriffe zum Buchstaben) und lvl (1 leicht, 2 mittel, 3 schwer).
-- * Auflösung enthält missed: bis zu 5 bekannte Begriffe, die keiner getippt hat.
-- ============================================================
BEGIN;

ALTER TABLE public.word_categories ADD COLUMN IF NOT EXISTS owner_lobby uuid REFERENCES public.lobbies(id) ON DELETE CASCADE;
ALTER TABLE public.word_categories DROP CONSTRAINT IF EXISTS word_categories_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS word_categories_name_public ON public.word_categories (name) WHERE owner_lobby IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS word_categories_name_lobby ON public.word_categories (owner_lobby, name) WHERE owner_lobby IS NOT NULL;

-- Drei Kandidaten für die Abstimmung (eigene Kategorien der Lobby bevorzugt), mit Schwierigkeit
CREATE OR REPLACE FUNCTION public._letters_pick_cands(p_lobby_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter text; v_played jsonb; v_cands jsonb; v_off jsonb;
BEGIN
  SELECT lower(quiz_options ->> 'letter'), coalesce(quiz_options -> 'played', '[]'::jsonb) INTO v_letter, v_played FROM public.lobbies WHERE id = p_lobby_id;
  v_off := coalesce((SELECT letters_cfg -> 'off' FROM public.lobbies WHERE id = p_lobby_id), '[]'::jsonb);
  SELECT jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'n', x.n, 'lvl', CASE WHEN x.n >= 40 THEN 1 WHEN x.n >= 15 THEN 2 ELSE 3 END)) INTO v_cands FROM (
    SELECT c.id, c.name, c.owner_lobby, k.n FROM public.word_categories c
      CROSS JOIN LATERAL (SELECT count(DISTINCT t.label)::int AS n FROM public.word_terms t WHERE t.category_id = c.id AND t.initial = v_letter AND t.source = 'list') k
     WHERE c.active AND (c.owner_lobby IS NULL OR c.owner_lobby = p_lobby_id)
       AND NOT (v_played @> to_jsonb(c.id::text)) AND NOT (v_off @> to_jsonb(c.name))
       AND k.n >= CASE WHEN c.owner_lobby IS NULL THEN 6 ELSE 2 END
     ORDER BY CASE WHEN c.owner_lobby IS NOT NULL AND random() < 0.6 THEN 0 ELSE 1 END, random() LIMIT 3
  ) x;
  RETURN coalesce(v_cands, '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public._letters_next_letter(p_lobby_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_off jsonb; v_played jsonb; v_used jsonb; v_all text[]; v_new text[];
BEGIN
  SELECT coalesce(letters_cfg -> 'off', '[]'::jsonb), coalesce(quiz_options -> 'played', '[]'::jsonb), coalesce(quiz_options -> 'letters', '[]'::jsonb)
    INTO v_off, v_played, v_used FROM public.lobbies WHERE id = p_lobby_id;
  SELECT coalesce(array_agg(z.initial::text), '{}'::text[]) INTO v_all FROM (
    SELECT cov.initial FROM (
      SELECT t.category_id, t.initial FROM public.word_terms t
        JOIN public.word_categories c ON c.id = t.category_id AND c.active AND (c.owner_lobby IS NULL OR c.owner_lobby = p_lobby_id)
         AND NOT (v_off @> to_jsonb(c.name)) AND NOT (v_played @> to_jsonb(c.id::text))
       GROUP BY t.category_id, t.initial HAVING count(DISTINCT t.label) >= CASE WHEN bool_or(c.owner_lobby IS NOT NULL) THEN 2 ELSE 6 END
    ) cov GROUP BY cov.initial HAVING count(*) >= 3
  ) z;
  SELECT coalesce(array_agg(x), '{}'::text[]) INTO v_new FROM unnest(v_all) x WHERE NOT (v_used @> to_jsonb(upper(x)));
  IF cardinality(v_new) > 0 THEN RETURN v_new[1 + floor(random() * cardinality(v_new))::int]; END IF;
  IF cardinality(v_all) > 0 THEN RETURN v_all[1 + floor(random() * cardinality(v_all))::int]; END IF;
  RETURN lower(coalesce((SELECT quiz_options ->> 'letter' FROM public.lobbies WHERE id = p_lobby_id), 'a'));
END $function$;

CREATE OR REPLACE FUNCTION public._letters_letters(p_off jsonb, p_need integer)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(array_agg(z.initial::text), '{}'::text[]) FROM (
    SELECT cov.initial FROM (
      SELECT t.category_id, t.initial FROM public.word_terms t
        JOIN public.word_categories c ON c.id = t.category_id AND c.active AND c.owner_lobby IS NULL AND NOT (coalesce(p_off, '[]'::jsonb) @> to_jsonb(c.name))
       GROUP BY t.category_id, t.initial HAVING count(DISTINCT t.label) >= 6
    ) cov GROUP BY cov.initial HAVING count(*) >= greatest(p_need, 3)
  ) z
$function$;

CREATE OR REPLACE FUNCTION public.get_letters_categories()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(name ORDER BY name), '[]'::jsonb) FROM public.word_categories WHERE active AND owner_lobby IS NULL
$function$;

CREATE OR REPLACE FUNCTION public.set_letters_config(p_lobby_id uuid, p_me_player_id uuid, p_cfg jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  SELECT coalesce(jsonb_agg(c.name ORDER BY c.name), '[]'::jsonb) INTO v_off FROM public.word_categories c WHERE c.active AND c.owner_lobby IS NULL AND (p_cfg -> 'off') @> to_jsonb(c.name);
  IF cardinality(public._letters_letters(v_off, v_cats + 2)) < 3 THEN RAISE EXCEPTION 'letters_too_few_categories'; END IF;
  UPDATE public.lobbies
     SET letters_cfg = (coalesce(letters_cfg, '{}'::jsonb) - 'cats' - 'secs' - 'off') || jsonb_build_object('cats', v_cats, 'secs', v_secs, 'off', v_off), settings_version = coalesce(settings_version, 0) + 1
   WHERE id = p_lobby_id;
END $function$;

CREATE OR REPLACE FUNCTION public._letters_reveal(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE l public.lobbies%ROWTYPE; v_letter char(1); v_cat uuid; v_cat_name text; b record; v_n int; v_frac numeric; v_wrong int; v_results jsonb; v_players int; v_secs numeric; v_map int; v_missed jsonb;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  v_letter := lower(l.quiz_options ->> 'letter');
  v_cat := (l.quiz_options -> 'cat' ->> 'id')::uuid;
  v_cat_name := l.quiz_options -> 'cat' ->> 'name';

  -- Bots (132): tippen wie Menschen unterschiedlicher Stärke. Anfänger kennen nur den bekannteren Teil der Liste (obere 35 %) und
  -- vertippen sich ab und zu (rotes Wort), Mittel 65 %, Profis die ganze Liste. Angenommene Einsprüche (source 'appeal') nutzen sie nie.
  FOR b IN SELECT player_id, coalesce(bot_skill, 2) AS skill FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active' AND is_bot LOOP
    v_n := CASE b.skill WHEN 1 THEN 2 + floor(random() * 4)::int WHEN 3 THEN 7 + floor(random() * 6)::int ELSE 4 + floor(random() * 5)::int END;
    v_frac := CASE b.skill WHEN 1 THEN 0.35 WHEN 3 THEN 1.0 ELSE 0.65 END;
    v_wrong := CASE b.skill WHEN 1 THEN 1 + floor(random() * 2)::int WHEN 3 THEN (random() < 0.2)::int ELSE (random() < 0.5)::int END;
    INSERT INTO public.letters_entries (lobby_id, seq, player_id, text, norm, label, valid)
    SELECT p_lobby_id, l.quiz_seq, b.player_id, x.label, x.key_norm, x.label, true FROM (
      SELECT d.label, d.key_norm, row_number() OVER (ORDER BY d.weight DESC, d.label) AS rn, count(*) OVER () AS cnt FROM (
        SELECT DISTINCT ON (t.label) t.label, t.key_norm, t.weight FROM public.word_terms t
         WHERE t.category_id = v_cat AND t.initial = v_letter AND t.source = 'list' ORDER BY t.label, t.weight DESC, random()
      ) d
    ) x WHERE x.rn <= greatest(v_n, ceil(x.cnt * v_frac)) ORDER BY random() LIMIT v_n
    ON CONFLICT DO NOTHING;
    IF v_wrong > 0 THEN
      INSERT INTO public.letters_entries (lobby_id, seq, player_id, text, norm, label, valid)
      SELECT p_lobby_id, l.quiz_seq, b.player_id, m.txt, public._ans_norm(m.txt), NULL, false FROM (
        SELECT left(t.label, 2) || 'q' || substr(t.label, 4) AS txt FROM (
          SELECT DISTINCT label FROM public.word_terms WHERE category_id = v_cat AND initial = v_letter AND source = 'list' AND length(label) >= 5
        ) t ORDER BY random() LIMIT v_wrong
      ) m WHERE length(public._ans_norm(m.txt)) >= 2
      ON CONFLICT DO NOTHING;
    END IF;
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

  v_results := public._letters_results(p_lobby_id, l.quiz_seq);
  -- 134: "Hättest du's gewusst?" – bekannte Begriffe zum Buchstaben, die niemand getippt hat (die bekanntesten zuerst)
  SELECT coalesce(jsonb_agg(m.label ORDER BY m.weight DESC), '[]'::jsonb) INTO v_missed FROM (
    SELECT d.label, d.weight FROM (
      SELECT DISTINCT ON (t.label) t.label, t.weight FROM public.word_terms t
       WHERE t.category_id = v_cat AND t.initial = v_letter AND t.source = 'list' ORDER BY t.label, t.weight DESC
    ) d
    WHERE NOT EXISTS (SELECT 1 FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.valid AND e.label = d.label)
    ORDER BY d.weight DESC, d.label LIMIT 5
  ) m;
  SELECT count(*)::int INTO v_players FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active';

  -- Dauer: Wörter-Karte 7 s + Wertungs-Show (Trommelwirbel 1 s + 2,2 s je Platz + 1,5 s für den Sieger); nach der letzten Kategorie zusätzlich die Gesamtwertung
  -- 129: haben Menschen rote Wörter, bleibt die Wörter-Karte länger stehen (Einspruch möglich)
  v_map := CASE WHEN EXISTS (SELECT 1 FROM public.letters_entries e JOIN public.players p ON p.lobby_id = e.lobby_id AND p.player_id = e.player_id
                              WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND NOT coalesce(e.valid, false) AND NOT e.dup AND NOT coalesce(p.is_bot, false))
                THEN 13 ELSE 7 END;
  v_secs := v_map + (1 + 2.2 * v_players + 1.5) + CASE WHEN l.quiz_index >= l.quiz_total THEN (1 + 2.2 * v_players + 1.5) ELSE 0 END + 3;
  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('letter', upper(v_letter), 'category', v_cat_name, 'index', l.quiz_index, 'last', l.quiz_index >= l.quiz_total, 'mapSecs', v_map, 'missed', v_missed, 'results', v_results),
         quiz_started_at = now(), quiz_ends_at = now() + least(v_secs, 100) * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $function$;

-- Host legt die eigenen Kategorien fest (ersetzt die bisherigen): [{ name, terms: [text] }], höchstens 3, je 8–400 Begriffe
CREATE OR REPLACE FUNCTION public.set_letters_custom(p_lobby_id uuid, p_me_player_id uuid, p_items jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_host uuid; v_phase text; it jsonb; v_name text; v_terms text[]; v_cat uuid; v_list jsonb := '[]'::jsonb; v_names text[] := '{}'; v_keep text[];
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_me_player_id) THEN RAISE EXCEPTION 'invalid_session'; END IF;
  SELECT host_player_id, phase INTO v_host, v_phase FROM public.lobbies WHERE id = p_lobby_id;
  IF v_host IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
  IF v_host IS DISTINCT FROM p_me_player_id THEN RAISE EXCEPTION 'not_host'; END IF;
  IF v_phase NOT IN ('waiting', 'finished') THEN RAISE EXCEPTION 'lobby_not_waiting'; END IF;
  PERFORM public._rate_limit('lcustom:' || p_me_player_id::text, 12, 60);
  IF jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array' OR jsonb_array_length(p_items) > 3 THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
  -- Einträge mit keep=true behalten ihre Begriffe (ohne sie neu zu schicken), alle anderen bisherigen werden ersetzt
  v_keep := ARRAY(SELECT lower(e ->> 'name') FROM jsonb_array_elements(p_items) e WHERE (e ->> 'keep') = 'true');
  DELETE FROM public.word_categories WHERE owner_lobby = p_lobby_id AND NOT (lower(name) = ANY (v_keep));
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_name := left(trim(regexp_replace(coalesce(it ->> 'name', ''), '\s+', ' ', 'g')), 24);
    IF length(v_name) < 2 THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
    IF (it ->> 'keep') = 'true' THEN
      SELECT c.id INTO v_cat FROM public.word_categories c WHERE c.owner_lobby = p_lobby_id AND lower(c.name) = lower(v_name);
      IF v_cat IS NULL THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
      v_names := array_append(v_names, lower(v_name));
      v_list := v_list || jsonb_build_object('name', v_name, 'n', (SELECT count(DISTINCT label) FROM public.word_terms WHERE category_id = v_cat));
      CONTINUE;
    END IF;
    IF lower(v_name) = ANY (v_names) OR EXISTS (SELECT 1 FROM public.word_categories WHERE owner_lobby IS NULL AND lower(name) = lower(v_name)) THEN RAISE EXCEPTION 'letters_name_taken'; END IF;
    v_names := array_append(v_names, lower(v_name));
    IF jsonb_typeof(coalesce(it -> 'terms', 'null'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'letters_bad_config'; END IF;
    SELECT array_agg(DISTINCT x.t) INTO v_terms FROM (
      SELECT left(trim(regexp_replace(e, '\s+', ' ', 'g')), 40) AS t FROM jsonb_array_elements_text(it -> 'terms') e LIMIT 600
    ) x WHERE length(x.t) >= 2 AND public._ans_norm(x.t) ~ '^[a-z]';
    IF coalesce(cardinality(v_terms), 0) < 8 THEN RAISE EXCEPTION 'letters_too_few_terms'; END IF;
    INSERT INTO public.word_categories (name, kind, active, owner_lobby) VALUES (v_name, 'thing', true, p_lobby_id) RETURNING id INTO v_cat;
    INSERT INTO public.word_terms (category_id, label, key_norm, initial, weight, source)
    SELECT v_cat, t, public._ans_norm(t), left(public._ans_norm(t), 1), 80, 'list' FROM unnest(v_terms) t
     WHERE length(public._ans_norm(t)) >= 2 ON CONFLICT DO NOTHING;
    v_list := v_list || jsonb_build_object('name', v_name, 'n', cardinality(v_terms));
  END LOOP;
  UPDATE public.lobbies SET letters_cfg = (coalesce(letters_cfg, '{}'::jsonb) - 'custom') || jsonb_build_object('custom', v_list),
         settings_version = coalesce(settings_version, 0) + 1 WHERE id = p_lobby_id;
END $$;

REVOKE ALL ON FUNCTION public.set_letters_custom(uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_letters_custom(uuid, uuid, jsonb) TO anon, authenticated;

COMMIT;
