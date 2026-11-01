-- ============================================================
-- 132: Roulette – mehr erkannte Begriffe, bessere Bots, Gleichstand (Wunsch Mehdi, 2026-11-01)
-- ============================================================
-- * word_terms.weight (Bekanntheit = Anzahl Sprachversionen bei Wikipedia) und word_terms.source ('list' = Liste, 'appeal' = per
--   Einspruch angenommen). Die neuen, viel größeren Listen laden: node db/scripts/load-word-lists.mjs
-- * Bots tippen nur aus dem bekannteren Teil der Liste (Anfänger 35 %, Mittel 65 %, Profis alles) und machen als Anfänger/Mittel
--   manchmal Tippfehler (rote Wörter).
-- * Angenommene Einsprüche (nur in gewerteten Spielen mit mindestens 2 Menschen) werden als neue Begriffe gemerkt und gelten künftig.
-- * Gleichstand am Ende: weniger falsche Wörter gewinnt; in der Kategorie-Wertung steht bei gleichen Punkten vorn, wer weniger Falsche hatte.
-- ============================================================
BEGIN;

ALTER TABLE public.word_terms ADD COLUMN IF NOT EXISTS weight int NOT NULL DEFAULT 0;
ALTER TABLE public.word_terms ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'list';
CREATE INDEX IF NOT EXISTS word_terms_weight ON public.word_terms (category_id, initial, weight DESC);

-- Kategorie-Wertung: aufsteigend nach Punkten (Letzter zuerst); bei gleichen Punkten steht der mit MEHR falschen Wörtern weiter unten
CREATE OR REPLACE FUNCTION public._letters_results(p_lobby_id uuid, p_seq int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_results jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(x.r ORDER BY x.pts ASC, x.badn DESC, x.nm), '[]') INTO v_results FROM (
    SELECT jsonb_build_object(
             'playerId', p.player_id, 'name', p.name,
             'points', (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.valid),
             'valid', (SELECT coalesce(jsonb_agg(jsonb_build_object('t', e.text, 'l', e.label) ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.valid),
             'bad', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND NOT coalesce(e.valid, false) AND NOT e.dup),
             'dup', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.dup)
           ) AS r,
           (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND e.valid) AS pts,
           (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = p_seq AND e.player_id = p.player_id AND NOT coalesce(e.valid, false) AND NOT e.dup) AS badn,
           p.name AS nm
      FROM public.players p WHERE p.lobby_id = p_lobby_id AND p.status = 'active'
  ) x;
  RETURN v_results;
END $$;

CREATE OR REPLACE FUNCTION public._letters_reveal(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE l public.lobbies%ROWTYPE; v_letter char(1); v_cat uuid; v_cat_name text; b record; v_n int; v_frac numeric; v_wrong int; v_results jsonb; v_players int; v_secs numeric; v_map int;
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
  SELECT count(*)::int INTO v_players FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active';

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
END $function$;

CREATE OR REPLACE FUNCTION public._quiz_finish(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_top uuid; v_mode text;
BEGIN
  SELECT game_mode INTO v_mode FROM public.lobbies WHERE id = p_lobby_id;
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
    ORDER BY coalesce(song_points, 0) DESC, tiebreak DESC, seat_index LIMIT 1;
  UPDATE public.lobbies SET quiz_state = NULL, quiz_ends_at = NULL, quiz_picker = NULL, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._finish_round(p_lobby_id);
  UPDATE public.lobbies SET holder_player_id = v_top WHERE id = p_lobby_id;
END $function$;

-- Einspruch angenommen: in gewerteten Spielen den Begriff dauerhaft merken (Kategorie der Runde, Gewicht klein, Bots nutzen ihn nie)
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
      IF v_others > 0 AND p_norm ~ '^[a-z]' AND length(p_norm) >= 3 THEN
        INSERT INTO public.word_terms (category_id, label, key_norm, initial, weight, source)
        SELECT (l.quiz_options -> 'cat' ->> 'id')::uuid, a.text, p_norm, left(p_norm, 1), 5, 'appeal'
          FROM public.lobbies l WHERE l.id = p_lobby_id AND l.quiz_options -> 'cat' ->> 'id' IS NOT NULL
        ON CONFLICT DO NOTHING;
      END IF;
    END IF;
  ELSIF cardinality(a.no) * 2 >= v_others THEN
    UPDATE public.letters_appeals SET status = 'rejected' WHERE lobby_id = p_lobby_id AND seq = p_seq AND owner_id = p_owner AND norm = p_norm;
  END IF;
END $$;

COMMIT;
