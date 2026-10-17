-- ============================================================
-- 127: Neuer Modus "Roulette" (Buchstabe + drei Kategorien) – Wunsch Mehdi, 2026-10-17
-- ============================================================
-- Ablauf: Ein Buchstaben-Roulette (A–Z) bleibt bei einem Buchstaben stehen, dazu werden drei Kategorien gezogen
-- (z. B. Rapper, Schauspieler, Länder). Für jede Kategorie haben alle 45 Sekunden Zeit, so viele passende Begriffe mit
-- diesem Anfangsbuchstaben einzutippen wie möglich – jeder sieht nur die eigenen Eingaben. Danach werden die Eingaben
-- geprüft (grün = erkannt, rot = nicht erkannt) und die Rangliste läuft von unten (wenigste Begriffe) nach oben.
-- Punkte = Anzahl richtiger, verschiedener Begriffe; nach 3 Kategorien gewinnt die Summe.
--
-- Neu: word_categories / word_terms (Begriffs-Listen, nur Server; geladen mit db/scripts/load-word-lists.mjs),
--      letters_entries / letters_done (Eingaben, nur Server), Modus 'letters' in der Quiz-Maschine
--      (quiz_state: spin -> question -> reveal, quiz_options = { letter, cats[] }).
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.word_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  kind text NOT NULL DEFAULT 'thing' CHECK (kind IN ('person', 'thing')),
  active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS public.word_terms (
  id bigserial PRIMARY KEY,
  category_id uuid NOT NULL REFERENCES public.word_categories(id) ON DELETE CASCADE,
  label text NOT NULL,          -- so wird der Begriff angezeigt
  key_norm text NOT NULL,       -- normalisierte Schreibweise, unter der er gefunden wird (Personen: voller Name + Nachname)
  initial char(1) NOT NULL,     -- Anfangsbuchstabe der Schreibweise
  UNIQUE (category_id, label, key_norm)
);
CREATE INDEX IF NOT EXISTS word_terms_lookup ON public.word_terms (category_id, initial);
ALTER TABLE public.word_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.word_terms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.word_categories FROM anon, authenticated;
REVOKE ALL ON public.word_terms FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.letters_entries (
  lobby_id uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  seq int NOT NULL,
  player_id uuid NOT NULL,
  text text NOT NULL,
  norm text NOT NULL,
  label text,                   -- erkannter Begriff (so wie in der Liste)
  valid boolean,                -- NULL = noch nicht geprüft
  dup boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lobby_id, seq, player_id, norm)
);
CREATE TABLE IF NOT EXISTS public.letters_done (
  lobby_id uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  seq int NOT NULL,
  player_id uuid NOT NULL,
  PRIMARY KEY (lobby_id, seq, player_id)
);
ALTER TABLE public.letters_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.letters_done ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.letters_entries FROM anon, authenticated;
REVOKE ALL ON public.letters_done FROM anon, authenticated;

ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_game_mode_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_game_mode_check CHECK (game_mode = ANY (ARRAY['original', 'buzzer', 'year', 'letters']));

CREATE OR REPLACE FUNCTION public._is_quiz_mode(p_mode text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(p_mode, '') = ANY (ARRAY['buzzer','year','letters']) $$;

CREATE OR REPLACE FUNCTION public._quiz_seconds(p_mode text, p_state text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state
    WHEN 'reveal' THEN CASE p_mode WHEN 'year' THEN 8 WHEN 'letters' THEN 20 ELSE 5 END
    WHEN 'spin' THEN 8
    WHEN 'buzzed' THEN 7
    WHEN 'month' THEN 12
    ELSE CASE p_mode WHEN 'year' THEN 20 WHEN 'letters' THEN 45 ELSE 30 END
  END::numeric
$$;

CREATE OR REPLACE FUNCTION public._trg_vote_cards()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from 'topic_vote' then
    -- 127: Roulette braucht keine Playlist – nichts abzustimmen
    n := case when NEW.game_mode = 'letters' then 1 else coalesce(cardinality(public._vote_topic_pool(NEW.topic_filter)), 0) end;
    NEW.topic_vote_cards := least(3, greatest(n, 1));
    if n <= 1 then
      NEW.topic_vote_ends_at := now();   -- nur eine Playlist: nichts abzustimmen
      NEW.topic_b := NEW.topic_a;
    end if;
  end if;
  return NEW;
end;
$function$;

-- Roulette starten: Buchstabe + 3 Kategorien ziehen (nur Buchstaben, zu denen mindestens 5 Kategorien je 6+ Begriffe haben)
CREATE OR REPLACE FUNCTION public._letters_spin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_letter char(1); v_cats jsonb;
BEGIN
  WITH cov AS (
    SELECT t.category_id, t.initial FROM public.word_terms t JOIN public.word_categories c ON c.id = t.category_id AND c.active
     GROUP BY t.category_id, t.initial HAVING count(DISTINCT t.label) >= 6
  )
  SELECT initial INTO v_letter FROM cov GROUP BY initial HAVING count(*) >= 5 ORDER BY random() LIMIT 1;
  IF v_letter IS NULL THEN RAISE EXCEPTION 'letters_no_words'; END IF;
  SELECT jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name)) INTO v_cats FROM (
    SELECT c.id, c.name FROM public.word_categories c
     WHERE c.active AND (SELECT count(DISTINCT t.label) FROM public.word_terms t WHERE t.category_id = c.id AND t.initial = v_letter) >= 6
     ORDER BY random() LIMIT 3
  ) x;
  UPDATE public.lobbies
     SET phase = 'quiz', quiz_state = 'spin', quiz_index = 0, quiz_seq = quiz_seq + 1,
         quiz_options = jsonb_build_object('letter', upper(v_letter), 'cats', v_cats),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'spin') * interval '1 second',
         quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Nächste Kategorie starten (nach dem Roulette bzw. nach der Auflösung der vorigen)
CREATE OR REPLACE FUNCTION public._letters_begin_category(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.lobbies
     SET quiz_state = 'question', quiz_index = quiz_index + 1, quiz_seq = quiz_seq + 1,
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'question') * interval '1 second',
         quiz_reveal = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Eingabe eines Begriffs (ohne Rückmeldung, ob er stimmt – das sieht man erst bei der Auflösung)
CREATE OR REPLACE FUNCTION public._letters_do_submit(p_lobby_id uuid, p_player_id uuid, p_text text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_clean text; v_norm text; v_n int; v_added int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'letters' OR l.quiz_state <> 'question' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF l.quiz_ends_at IS NOT NULL AND l.quiz_ends_at < now() - interval '1 second' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active') THEN RAISE EXCEPTION 'not_a_member'; END IF;
  PERFORM public._rate_limit('letters:' || p_player_id::text, 200, 60);
  v_clean := left(trim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), 40);
  v_norm := public._ans_norm(v_clean);
  IF length(v_norm) < 2 THEN RAISE EXCEPTION 'empty_answer'; END IF;
  SELECT count(*) INTO v_n FROM public.letters_entries WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id;
  IF v_n >= 60 THEN RAISE EXCEPTION 'letters_too_many'; END IF;
  INSERT INTO public.letters_entries (lobby_id, seq, player_id, text, norm) VALUES (p_lobby_id, l.quiz_seq, p_player_id, v_clean, v_norm)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN jsonb_build_object('added', v_added > 0, 'count', v_n + v_added);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_letters_submit(p_code text, p_player_id uuid, p_text text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public._letters_do_submit(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_text); END $$;

-- "Fertig": sind alle Menschen fertig, geht es sofort zur Auflösung
CREATE OR REPLACE FUNCTION public.rpc_letters_done(p_code text, p_player_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; l public.lobbies%ROWTYPE; v_left int;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  SELECT * INTO l FROM public.lobbies WHERE id = v_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'letters' OR l.quiz_state <> 'question' THEN RETURN; END IF;
  INSERT INTO public.letters_done (lobby_id, seq, player_id) VALUES (v_id, l.quiz_seq, p_player_id) ON CONFLICT DO NOTHING;
  UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = v_id;
  SELECT count(*) INTO v_left FROM public.players p
   WHERE p.lobby_id = v_id AND p.status = 'active' AND NOT coalesce(p.is_bot, false)
     AND NOT EXISTS (SELECT 1 FROM public.letters_done d WHERE d.lobby_id = v_id AND d.seq = l.quiz_seq AND d.player_id = p.player_id);
  IF v_left = 0 THEN
    UPDATE public.lobbies SET quiz_ends_at = least(quiz_ends_at, now() + interval '800 milliseconds') WHERE id = v_id;
  END IF;
END $$;

-- Auflösung: Bots tippen, alle Eingaben prüfen, Punkte, Ergebnisse (aufsteigend: Letzter zuerst)
CREATE OR REPLACE FUNCTION public._letters_reveal(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_letter char(1); v_cat uuid; v_cat_name text; b record; v_n int; v_results jsonb;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  v_letter := lower(l.quiz_options ->> 'letter');
  v_cat := ((l.quiz_options -> 'cats' -> (l.quiz_index - 1)) ->> 'id')::uuid;
  v_cat_name := (l.quiz_options -> 'cats' -> (l.quiz_index - 1)) ->> 'name';

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
  -- Vorfilter (gleicher erster Buchstabe, ähnliche Länge) hält die Prüfung schnell.
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

  SELECT coalesce(jsonb_agg(r ORDER BY (r ->> 'points')::int ASC, r ->> 'name'), '[]') INTO v_results FROM (
    SELECT jsonb_build_object(
             'playerId', p.player_id, 'name', p.name,
             'points', (SELECT count(*) FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND e.valid),
             'valid', (SELECT coalesce(jsonb_agg(e.label ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND e.valid),
             'bad', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND NOT coalesce(e.valid, false) AND NOT e.dup),
             'dup', (SELECT coalesce(jsonb_agg(e.text ORDER BY e.created_at), '[]') FROM public.letters_entries e WHERE e.lobby_id = p_lobby_id AND e.seq = l.quiz_seq AND e.player_id = p.player_id AND e.dup)
           ) AS r
      FROM public.players p WHERE p.lobby_id = p_lobby_id AND p.status = 'active'
  ) x;

  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('letter', upper(v_letter), 'category', v_cat_name, 'index', l.quiz_index, 'results', v_results),
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('letters', 'reveal') * interval '1 second',
         quiz_rev = quiz_rev + 1, last_activity_at = now()
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
         quiz_total = CASE WHEN v_mode = 'buzzer' THEN 20 WHEN v_mode = 'letters' THEN 3 ELSE 8 END,
         used_answers = '{}',
         used_song_ids = CASE WHEN coalesce(series_index, 1) <= 1 THEN '{}' ELSE coalesce(used_song_ids, '{}') END,
         run_started_at = now(), countdown_started_at = NULL, countdown_ends_at = NULL, countdown_starter_player_id = NULL,
         last_activity_at = now()
   WHERE id = p_lobby_id;
  IF v_mode = 'letters' THEN PERFORM public._letters_spin(p_lobby_id); ELSE PERFORM public._quiz_next(p_lobby_id); END IF;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_next(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_ids uuid[];
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RETURN; END IF;
  -- 127: Roulette – nächste Kategorie oder Ende nach 3 Kategorien
  IF l.game_mode = 'letters' THEN
    IF l.quiz_index >= l.quiz_total THEN PERFORM public._quiz_finish(p_lobby_id); ELSE PERFORM public._letters_begin_category(p_lobby_id); END IF;
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
  ELSIF l.quiz_state = 'spin' THEN
    PERFORM public._letters_begin_category(p_lobby_id);
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
  -- 127: Roulette hat keinen Song – eigene Auflösung (Begriffe prüfen, Punkte, Rangliste)
  IF l.game_mode = 'letters' THEN
    PERFORM public._letters_reveal(p_lobby_id);
    RETURN;
  END IF;
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
    'seq', l.quiz_seq,
    'me', coalesce(v_me, jsonb_build_object('answered', false)),
    -- Jahr raten: wer schon getippt hat (ohne die Jahre selbst – die sieht man erst bei der Auflösung)
    'answered', CASE WHEN l.game_mode = 'year'
                     THEN (SELECT coalesce(jsonb_agg(player_id), '[]') FROM public.quiz_answers WHERE lobby_id = v_id AND seq = l.quiz_seq AND (l.quiz_state <> 'month' OR month IS NOT NULL))
                     ELSE '[]'::jsonb END
  );
END $$;

CREATE OR REPLACE FUNCTION public.set_lobby_mode(p_lobby_id uuid, p_me_player_id uuid, p_mode text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_mode text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  v_mode := btrim(coalesce(p_mode, ''));
  if v_mode not in ('original','buzzer','year','letters') then raise exception 'invalid_mode'; end if;
  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_preferences(p_prefs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  p jsonb := coalesce(p_prefs, '{}'::jsonb);
  h jsonb := coalesce(p_prefs -> 'host', '{}'::jsonb);
  s jsonb := coalesce(p_prefs -> 'solo', '{}'::jsonb);
  out jsonb := '{}'::jsonb;
  host_out jsonb := '{}'::jsonb;
  solo_out jsonb := '{}'::jsonb;
  v_ex jsonb;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'prefs_invalid'; end if;

  if p ->> 'lang' in ('de', 'en', 'fr') then out := out || jsonb_build_object('lang', p ->> 'lang'); end if;
  if jsonb_typeof(p -> 'muted') = 'boolean' then out := out || jsonb_build_object('muted', (p ->> 'muted')::boolean); end if;
  if jsonb_typeof(p -> 'volume') = 'number' and (p ->> 'volume')::numeric between 0 and 1 then
    out := out || jsonb_build_object('volume', round((p ->> 'volume')::numeric, 2));
  end if;

  if jsonb_typeof(h -> 'maxPlayers') = 'number' and (h ->> 'maxPlayers')::numeric between 2 and 12 then
    host_out := host_out || jsonb_build_object('maxPlayers', (h ->> 'maxPlayers')::numeric::int);
  end if;
  if h ->> 'speed' in ('fast', 'normal', 'calm') then host_out := host_out || jsonb_build_object('speed', h ->> 'speed'); end if;
  if h ->> 'rounds' in ('1', '3', '5') then host_out := host_out || jsonb_build_object('rounds', (h ->> 'rounds')::int); end if;
  if h ->> 'answerMode' in ('text', 'voice') then host_out := host_out || jsonb_build_object('answerMode', h ->> 'answerMode'); end if;
  if h ->> 'mode' in ('original', 'buzzer', 'year', 'letters') then host_out := host_out || jsonb_build_object('mode', h ->> 'mode'); end if;
  if jsonb_typeof(h -> 'excludedPlaylists') = 'array' then
    select coalesce(jsonb_agg(distinct tp.text), '[]'::jsonb) into v_ex
    from public.topic_pool tp
    where tp.is_song_category is true
      and tp.text in (select jsonb_array_elements_text(h -> 'excludedPlaylists'));
    host_out := host_out || jsonb_build_object('excludedPlaylists', v_ex);
  end if;
  if host_out <> '{}'::jsonb then out := out || jsonb_build_object('host', host_out); end if;

  if jsonb_typeof(s -> 'bots') = 'number' and (s ->> 'bots')::numeric between 1 and 5 then
    solo_out := solo_out || jsonb_build_object('bots', (s ->> 'bots')::numeric::int);
  end if;
  if s ->> 'skill' in ('mixed', '1', '2', '3') then solo_out := solo_out || jsonb_build_object('skill', s ->> 'skill'); end if;
  if s ->> 'mode' in ('original', 'buzzer', 'year', 'letters') then solo_out := solo_out || jsonb_build_object('mode', s ->> 'mode'); end if;
  if s ->> 'speed' in ('fast', 'normal', 'calm') then solo_out := solo_out || jsonb_build_object('speed', s ->> 'speed'); end if;
  if solo_out <> '{}'::jsonb then out := out || jsonb_build_object('solo', solo_out); end if;

  update public.profiles set preferences = out where id = v_uid;
  return out;
end;
$function$;

-- Rechte: das Spiel darf nur die zwei Eingabe-Funktionen aufrufen (alles andere bleibt intern)
REVOKE ALL ON FUNCTION public.rpc_letters_submit(text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_letters_done(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_letters_submit(text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_letters_done(text, uuid) TO anon, authenticated;

COMMIT;
