-- ============================================================
-- 141: Roulette – fünf Allgemeinwissen-Kategorien + strengere, nachvollziehbare Prüfung (Wunsch Mehdi, 2026-11-04)
-- ============================================================
-- * Aktive Kategorien: Länder, Städte, Tiere, Fußballspieler, Obst & Gemüse (alles andere ist ausgeschaltet, aber noch in der Datenbank;
--   db/scripts/data/active-categories.json steuert das beim Neuladen der Listen). Mehr als 3 Kategorien pro Spiel gehen mit 5 nicht (cats + 2 nötig).
-- * Tippfehler-Toleranz (_letters_close): bis 4 Buchstaben exakt, 5 Buchstaben nur Buchstabendreher, 6–9: 1 Fehler, 10–15: 2, ab 16: 3.
--   Vorher galt schon bei 4 Buchstaben 1 Fehler – "Hose" zählte als "Hase".
-- * _letters_match: die eine Stelle, an der ein Wort gegen die Liste geprüft wird (auch für Tests).
-- * Einspruch ohne andere Menschen wird nur noch angenommen, wenn das Wort einem Begriff der Liste sehr nah kommt (vorher: immer).
-- ============================================================
BEGIN;

-- Tippfehler-Regel für Roulette (strenger als _ans_close, das bei Song-Titeln bleibt)
CREATE OR REPLACE FUNCTION public._letters_close(p_term text, p_typed text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE ca text; cb text; v_len int; i int;
BEGIN
  IF coalesce(p_term, '') = '' OR coalesce(p_typed, '') = '' THEN RETURN false; END IF;
  ca := replace(p_term, ' ', ''); cb := replace(p_typed, ' ', '');
  IF ca = cb THEN RETURN true; END IF;
  v_len := length(ca);
  IF v_len <= 4 THEN RETURN false; END IF;
  IF v_len = 5 THEN
    -- nur zwei vertauschte Nachbarbuchstaben ("Tigre" statt "Tiger")
    IF length(cb) <> 5 THEN RETURN false; END IF;
    FOR i IN 1..4 LOOP
      IF substr(ca, 1, i - 1) || substr(ca, i + 1, 1) || substr(ca, i, 1) || substr(ca, i + 2) = cb THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
  END IF;
  RETURN levenshtein(ca, cb) <= CASE WHEN v_len <= 9 THEN 1 WHEN v_len <= 15 THEN 2 ELSE 3 END;
END $$;

-- Genau eine Prüfstelle: welcher Begriff der Kategorie passt zur Eingabe (und zum Buchstaben)? NULL = keiner.
CREATE OR REPLACE FUNCTION public._letters_match(p_cat uuid, p_letter text, p_norm text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT t.label FROM public.word_terms t
   WHERE t.category_id = p_cat AND t.initial = left(p_norm, 1) AND abs(length(t.key_norm) - length(p_norm)) <= 3
     AND (t.key_norm = p_norm OR public._letters_close(t.key_norm, p_norm))
     AND EXISTS (SELECT 1 FROM public.word_terms q WHERE q.category_id = p_cat AND q.label = t.label AND q.initial = lower(p_letter))
   ORDER BY (t.key_norm = p_norm) DESC, abs(length(t.key_norm) - length(p_norm)) LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._letters_close(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._letters_match(uuid, text, text) FROM PUBLIC;

-- Großzügigere Prüfung nur für Einsprüche ohne andere Menschen: ein Fehler mehr als bei _letters_close (ab 5 Buchstaben)
CREATE OR REPLACE FUNCTION public._letters_match_loose(p_cat uuid, p_letter text, p_norm text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT t.label FROM public.word_terms t
   WHERE t.category_id = p_cat AND t.initial = left(p_norm, 1) AND abs(length(t.key_norm) - length(p_norm)) <= 3 AND length(p_norm) >= 5
     AND levenshtein(replace(t.key_norm, ' ', ''), replace(p_norm, ' ', '')) <= CASE WHEN length(p_norm) <= 9 THEN 2 WHEN length(p_norm) <= 15 THEN 3 ELSE 4 END
     AND EXISTS (SELECT 1 FROM public.word_terms q WHERE q.category_id = p_cat AND q.label = t.label AND q.initial = lower(p_letter))
   ORDER BY levenshtein(replace(t.key_norm, ' ', ''), replace(p_norm, ' ', '')) LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._letters_match_loose(uuid, text, text) FROM PUBLIC;

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
    LEFT JOIN LATERAL (SELECT public._letters_match(v_cat, v_letter, e2.norm) AS label) m ON true
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

CREATE OR REPLACE FUNCTION public._letters_appeal_eval(p_lobby_id uuid, p_seq integer, p_owner uuid, p_norm text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE a public.letters_appeals%ROWTYPE; v_others int; v_cat uuid; v_letter text;
BEGIN
  SELECT * INTO a FROM public.letters_appeals WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm FOR UPDATE;
  IF NOT FOUND OR a.status <> 'open' THEN RETURN; END IF;
  SELECT count(*) INTO v_others FROM public.players
   WHERE lobby_id = p_lobby_id AND status = 'active' AND NOT coalesce(is_bot, false) AND player_id <> p_owner;
  SELECT (quiz_options -> 'cat' ->> 'id')::uuid, lower(quiz_options ->> 'letter') INTO v_cat, v_letter FROM public.lobbies WHERE id = p_lobby_id;
  -- 141: Ohne andere Menschen entscheidet niemand per Abstimmung – dann zählt der Einspruch nur, wenn das Wort einem echten Begriff
  -- der Liste sehr nah kommt (Tippfehler). Vorher wurde ALLES angenommen: so konnte man sich allein beliebig Punkte geben.
  IF (v_others = 0 AND public._letters_match_loose(v_cat, v_letter, p_norm) IS NOT NULL) OR (v_others > 0 AND cardinality(a.yes) * 2 > v_others) THEN
    UPDATE public.letters_appeals SET status = 'accepted' WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm;
    UPDATE public.letters_entries SET valid = true, dup = false, label = a.text
     WHERE lobby_id = p_lobby_id AND seq = p_seq AND player_id = p_owner AND norm = p_norm AND NOT coalesce(valid, false);
    IF FOUND THEN
      UPDATE public.players SET song_points = coalesce(song_points, 0) + 1 WHERE lobby_id = p_lobby_id AND player_id = p_owner;
      UPDATE public.lobbies SET quiz_reveal = jsonb_set(quiz_reveal, '{results}', public._letters_results(p_lobby_id, p_seq)) WHERE id = p_lobby_id;
      IF v_others > 0 AND p_norm ~ '^[a-z]' AND length(p_norm) >= 3 THEN
        INSERT INTO public.word_terms (category_id, label, key_norm, initial, weight, source)
        SELECT (l.quiz_options -> 'cat' ->> 'id')::uuid, a.text, p_norm, left(p_norm, 1), 5, 'appeal'
          FROM public.lobbies l WHERE l.id = p_lobby_id AND l.quiz_options -> 'cat' ->> 'id' IS NOT NULL
        ON CONFLICT DO NOTHING;
      END IF;
    END IF;
  ELSIF v_others = 0 OR cardinality(a.no) * 2 >= v_others THEN
    UPDATE public.letters_appeals SET status = 'rejected' WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public._letters_cfg(p_lobby_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
           'cats', least(coalesce((letters_cfg ->> 'cats')::int, 3), 3),
           'secs', coalesce((letters_cfg ->> 'secs')::int, 45),
           'off', coalesce(letters_cfg -> 'off', '[]'::jsonb))
    FROM public.lobbies WHERE id = p_lobby_id
$function$;

-- Kategorien
UPDATE public.word_categories SET active = (name IN ('Länder', 'Städte', 'Tiere', 'Fußballspieler', 'Obst & Gemüse')) WHERE owner_lobby IS NULL;
-- Lobbys mit mehr als 3 Kategorien oder ausgeschalteten alten Kategorien zurücksetzen
UPDATE public.lobbies SET letters_cfg = jsonb_set(jsonb_set(letters_cfg, '{cats}', to_jsonb(least(coalesce((letters_cfg ->> 'cats')::int, 3), 3))), '{off}', '[]'::jsonb) WHERE letters_cfg IS NOT NULL;

COMMIT;
