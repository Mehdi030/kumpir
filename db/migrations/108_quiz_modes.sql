-- ============================================================
-- 108: Quiz-Modi (Wunsch Mehdi, 2026-10-13)
-- ============================================================
-- Neben der heißen Kartoffel ("original") gibt es Quiz-Modi, in denen ALLE gleichzeitig raten:
--   artist  – Wer singt das?   4 Künstler zur Auswahl, schnellste richtige Antwort bekommt am meisten
--   snippet – Blitz-Schnipsel  der Song läuft erst 1 s, dann 2, 4, 8 s – je früher erkannt, desto mehr Punkte
--   pick    – Songwahl         reihum wählt einer einen Song (3 zur Auswahl), alle anderen raten
--   buzzer  – Buzzer           wer zuerst drückt, darf antworten; falsch = für diesen Song raus
--   year    – Jahr raten       Erscheinungsjahr schätzen, je näher desto mehr Punkte (song_pool.release_year)
--   gap     – Lückentitel      der Titel wird mit Lücke gezeigt, das fehlende Wort tippen
--   duel    – Duell auf Ansage zwei treten gegeneinander an (Best of 3), die anderen wetten
-- Ablauf: Playlist-Wahl -> Countdown -> phase 'quiz' mit quiz_state pick/bet/question/buzzed/reveal ->
--   nach quiz_total Fragen _finish_round (Rangliste nach players.song_points) -> Zwischenstand/Ende wie gewohnt.
-- Lösungen liegen in quiz_secret / quiz_answers (keine Rechte für Clients); was Clients sehen dürfen,
-- steht in lobbies.quiz_options (Auswahl, Lücken-Titel, Duell-Stand) und nach der Auflösung in quiz_reveal.
-- Jede Änderung zählt lobbies.quiz_rev hoch -> Live-Broadcast der Lobby -> Clients laden rpc_quiz_status.
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies
  ADD COLUMN IF NOT EXISTS quiz_state text,
  ADD COLUMN IF NOT EXISTS quiz_index int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quiz_total int NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS quiz_seq int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quiz_rev int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quiz_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS quiz_ends_at timestamptz,
  ADD COLUMN IF NOT EXISTS quiz_picker uuid,
  ADD COLUMN IF NOT EXISTS quiz_options jsonb,
  ADD COLUMN IF NOT EXISTS quiz_reveal jsonb,
  ADD COLUMN IF NOT EXISTS quiz_locked uuid[] NOT NULL DEFAULT '{}';

ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_game_mode_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_game_mode_check
  CHECK (game_mode = ANY (ARRAY['original','teleport','reverse','teams','pick','buzzer','snippet','artist','year','gap','duel']));
ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_phase_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_phase_check
  CHECK (phase = ANY (ARRAY['waiting','lobby','topic_vote','countdown','running','quiz','finished','rematch_wait','set_summary']));

ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS release_year int;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS team smallint;
GRANT SELECT (team) ON public.players TO anon, authenticated;

-- Geheimnisse der laufenden Frage (Lösung, Auswahl des Song-Wählers)
CREATE TABLE IF NOT EXISTS public.quiz_secret (
  lobby_id uuid PRIMARY KEY REFERENCES public.lobbies(id) ON DELETE CASCADE,
  seq int NOT NULL,
  song_id uuid,
  answer text,          -- artist: richtige Auswahl, gap: fehlendes Wort
  year int,
  pick_options uuid[]
);
ALTER TABLE public.quiz_secret ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quiz_secret FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.quiz_answers (
  lobby_id uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  seq int NOT NULL,
  player_id uuid NOT NULL,
  answer text,
  num int,
  correct boolean NOT NULL DEFAULT false,
  points numeric NOT NULL DEFAULT 0,
  tries int NOT NULL DEFAULT 0,
  answered_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lobby_id, seq, player_id)
);
ALTER TABLE public.quiz_answers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quiz_answers FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.quiz_bets (
  lobby_id uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  duel int NOT NULL,
  player_id uuid NOT NULL,
  pick uuid NOT NULL,
  PRIMARY KEY (lobby_id, duel, player_id)
);
ALTER TABLE public.quiz_bets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quiz_bets FROM anon, authenticated;

-- ------------------------------------------------------------ Hilfsfunktionen
CREATE OR REPLACE FUNCTION public._is_quiz_mode(p_mode text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(p_mode, '') = ANY (ARRAY['pick','buzzer','snippet','artist','year','gap','duel']) $$;

CREATE OR REPLACE FUNCTION public._quiz_seconds(p_mode text, p_state text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state
    WHEN 'reveal' THEN 5
    WHEN 'pick' THEN 12
    WHEN 'bet' THEN 8
    WHEN 'buzzed' THEN 7
    ELSE CASE p_mode
      WHEN 'artist' THEN 12 WHEN 'snippet' THEN 28 WHEN 'year' THEN 15 WHEN 'gap' THEN 20
      WHEN 'buzzer' THEN 30 WHEN 'pick' THEN 20 WHEN 'duel' THEN 25 ELSE 20 END
  END::numeric
$$;

-- Song der aktuellen Playlist ziehen (je Modus gefiltert), als aktuellen Song setzen
CREATE OR REPLACE FUNCTION public._quiz_take_song(p_lobby_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_plays int; v_hits int;
BEGIN
  UPDATE public.song_pool SET plays = plays + 1 WHERE id = p_song_id RETURNING plays, hits INTO v_plays, v_hits;
  UPDATE public.lobbies
     SET current_song_id = p_song_id, current_song_started_at = now(),
         current_song_difficulty = public._song_difficulty(v_plays, v_hits),
         used_song_ids = array_append(coalesce(used_song_ids, '{}'), p_song_id)
   WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_candidates(p_lobby_id uuid, p_mode text, p_n int) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_topic text; v_used uuid[]; v_ids uuid[];
BEGIN
  SELECT topic_selected, coalesce(used_song_ids, '{}') INTO v_topic, v_used FROM public.lobbies WHERE id = p_lobby_id;
  SELECT array_agg(id) INTO v_ids FROM (
    SELECT sp.id FROM public.song_pool sp
    JOIN public.topic_pool tp ON tp.id = sp.topic_pool_id AND tp.is_song_category IS TRUE AND lower(tp.text) = lower(coalesce(v_topic, ''))
    WHERE sp.archived_from IS NULL AND sp.preview_url IS NOT NULL
      AND NOT (sp.id = ANY (v_used))
      AND (p_mode <> 'year' OR sp.release_year IS NOT NULL)
      AND (p_mode <> 'gap' OR array_length(regexp_split_to_array(public._ans_norm(sp.title), ' '), 1) >= 2)
    ORDER BY random() LIMIT p_n
  ) x;
  RETURN coalesce(v_ids, '{}');
END $$;

-- Wer singt das? 4 Antworten: richtiger Künstler + 3 andere, die keinen Namen mit ihm teilen
CREATE OR REPLACE FUNCTION public._quiz_artist_options(p_song_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_artist text; v_feat text[]; v_topic uuid; v_names text[]; v_opts text[] := '{}'; r record; v_n text[];
BEGIN
  SELECT artist, feat_artists, topic_pool_id INTO v_artist, v_feat, v_topic FROM public.song_pool WHERE id = p_song_id;
  v_names := public._song_artist_names(v_artist, v_feat);
  FOR r IN
    SELECT a FROM (SELECT DISTINCT sp.artist AS a FROM public.song_pool sp
                   WHERE sp.topic_pool_id = v_topic AND sp.archived_from IS NULL AND lower(sp.artist) <> lower(v_artist)) d
    ORDER BY random()
  LOOP
    v_n := public._song_artist_names(r.a, '{}');
    IF NOT (v_n && v_names) THEN
      v_opts := array_append(v_opts, r.a);
      v_names := v_names || v_n;
      EXIT WHEN array_length(v_opts, 1) >= 3;
    END IF;
  END LOOP;
  v_opts := array_append(v_opts, v_artist);
  RETURN (SELECT jsonb_agg(a ORDER BY random()) FROM unnest(v_opts) a);
END $$;

-- Frage starten (Song ist gewählt)
CREATE OR REPLACE FUNCTION public._quiz_start_question(p_lobby_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_title text; v_artist text; v_year int; v_words text[]; v_word text; v_masked text; v_opts jsonb; v_seq int; v_secret text;
BEGIN
  SELECT game_mode, quiz_seq + 1 INTO v_mode, v_seq FROM public.lobbies WHERE id = p_lobby_id;
  SELECT title, artist, release_year INTO v_title, v_artist, v_year FROM public.song_pool WHERE id = p_song_id;
  PERFORM public._quiz_take_song(p_lobby_id, p_song_id);
  v_opts := NULL; v_secret := NULL;
  IF v_mode = 'artist' THEN
    v_opts := jsonb_build_object('choices', public._quiz_artist_options(p_song_id));
    v_secret := v_artist;
  ELSIF v_mode = 'gap' THEN
    -- längstes Wort (mind. 3 Buchstaben) wird zur Lücke
    v_words := regexp_split_to_array(trim(regexp_replace(v_title, '\(.*?\)|\[.*?\]', '', 'g')), '\s+');
    SELECT w INTO v_word FROM unnest(v_words) w WHERE length(regexp_replace(w, '[^[:alpha:]]', '', 'g')) >= 3
      ORDER BY length(regexp_replace(w, '[^[:alpha:]]', '', 'g')) DESC, random() LIMIT 1;
    IF v_word IS NULL THEN v_word := v_words[1]; END IF;
    v_masked := array_to_string(array(SELECT CASE WHEN w = v_word THEN repeat('_', greatest(3, length(regexp_replace(w, '[^[:alpha:]]', '', 'g')))) ELSE w END FROM unnest(v_words) w), ' ');
    v_opts := jsonb_build_object('masked', v_masked, 'letters', length(regexp_replace(v_word, '[^[:alpha:]]', '', 'g')));
    v_secret := regexp_replace(v_word, '[^[:alnum:]äöüÄÖÜß]', '', 'g');
  END IF;
  INSERT INTO public.quiz_secret (lobby_id, seq, song_id, answer, year)
  VALUES (p_lobby_id, v_seq, p_song_id, v_secret, v_year)
  ON CONFLICT (lobby_id) DO UPDATE SET seq = excluded.seq, song_id = excluded.song_id, answer = excluded.answer, year = excluded.year, pick_options = NULL;
  UPDATE public.lobbies
     SET quiz_state = 'question', quiz_seq = v_seq, quiz_started_at = now(),
         quiz_ends_at = now() + public._quiz_seconds(v_mode, 'question') * interval '1 second',
         quiz_options = CASE WHEN v_mode = 'duel' THEN quiz_options ELSE v_opts END,
         quiz_reveal = NULL, quiz_locked = '{}', quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Wer darf gerade antworten?
CREATE OR REPLACE FUNCTION public._quiz_eligible(p_lobby_id uuid) RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(array_agg(p.player_id), '{}')
  FROM public.players p, public.lobbies l
  WHERE l.id = p_lobby_id AND p.lobby_id = l.id AND p.status = 'active'
    AND (l.game_mode <> 'pick' OR p.player_id IS DISTINCT FROM l.quiz_picker)
    AND (l.game_mode <> 'duel' OR p.player_id::text IN (l.quiz_options ->> 'a', l.quiz_options ->> 'b'))
    AND NOT (p.player_id = ANY (l.quiz_locked))
$$;

-- Alle fertig? -> Auflösung gleich (0,8 s Puffer)
CREATE OR REPLACE FUNCTION public._quiz_maybe_early(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_seq int; v_elig uuid[]; v_done int;
BEGIN
  SELECT game_mode, quiz_seq INTO v_mode, v_seq FROM public.lobbies WHERE id = p_lobby_id AND quiz_state = 'question';
  IF NOT FOUND OR v_mode = 'buzzer' THEN RETURN; END IF;
  v_elig := public._quiz_eligible(p_lobby_id);
  IF coalesce(array_length(v_elig, 1), 0) = 0 THEN RETURN; END IF;
  SELECT count(*) INTO v_done FROM public.quiz_answers a
   WHERE a.lobby_id = p_lobby_id AND a.seq = v_seq AND a.player_id = ANY (v_elig)
     AND (a.correct OR v_mode IN ('artist', 'year'));
  IF v_done >= array_length(v_elig, 1) THEN
    UPDATE public.lobbies SET quiz_ends_at = least(quiz_ends_at, now() + interval '800 milliseconds') WHERE id = p_lobby_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_rank_points(p_rank int) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN p_rank <= 1 THEN 3 WHEN p_rank = 2 THEN 2 ELSE 1 END::numeric $$;

-- ------------------------------------------------------------ Ablauf
-- Nächste Frage (bzw. nächstes Duell), oder Runde beenden
CREATE OR REPLACE FUNCTION public._quiz_next(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_ids uuid[]; v_picker uuid; v_n int; v_a uuid; v_b uuid; v_played jsonb;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' THEN RETURN; END IF;

  IF l.quiz_index >= l.quiz_total THEN
    PERFORM public._quiz_finish(p_lobby_id);
    RETURN;
  END IF;

  IF l.game_mode = 'pick' THEN
    SELECT count(*) INTO v_n FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active';
    SELECT player_id INTO v_picker FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active'
      ORDER BY seat_index NULLS LAST, joined_at OFFSET (l.quiz_index % greatest(v_n, 1)) LIMIT 1;
    v_ids := public._quiz_candidates(p_lobby_id, 'pick', 3);
    IF coalesce(array_length(v_ids, 1), 0) = 0 THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
    INSERT INTO public.quiz_secret (lobby_id, seq, pick_options) VALUES (p_lobby_id, l.quiz_seq, v_ids)
    ON CONFLICT (lobby_id) DO UPDATE SET pick_options = excluded.pick_options, song_id = NULL, answer = NULL, year = NULL;
    UPDATE public.lobbies
       SET quiz_index = quiz_index + 1, quiz_state = 'pick', quiz_picker = v_picker,
           quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('pick', 'pick') * interval '1 second',
           quiz_options = NULL, quiz_reveal = NULL, quiz_locked = '{}', current_song_id = NULL,
           quiz_rev = quiz_rev + 1, last_activity_at = now()
     WHERE id = p_lobby_id;
    RETURN;
  END IF;

  IF l.game_mode = 'duel' THEN
    -- zwei Spieler, die bisher am wenigsten Duelle hatten
    v_played := coalesce(l.quiz_options -> 'played', '{}'::jsonb);
    SELECT array_agg(player_id) INTO v_ids FROM (
      SELECT player_id FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active'
      ORDER BY coalesce((v_played ->> player_id::text)::int, 0), random() LIMIT 2
    ) x;
    IF coalesce(array_length(v_ids, 1), 0) < 2 THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
    v_a := v_ids[1]; v_b := v_ids[2];
    v_played := v_played || jsonb_build_object(v_a::text, coalesce((v_played ->> v_a::text)::int, 0) + 1, v_b::text, coalesce((v_played ->> v_b::text)::int, 0) + 1);
    UPDATE public.lobbies
       SET quiz_index = quiz_index + 1, quiz_state = 'bet', quiz_picker = NULL,
           quiz_options = jsonb_build_object('a', v_a, 'b', v_b, 'wa', 0, 'wb', 0, 'song', 0, 'played', v_played),
           quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds('duel', 'bet') * interval '1 second',
           quiz_reveal = NULL, quiz_locked = '{}', current_song_id = NULL, quiz_rev = quiz_rev + 1, last_activity_at = now()
     WHERE id = p_lobby_id;
    RETURN;
  END IF;

  v_ids := public._quiz_candidates(p_lobby_id, l.game_mode, 1);
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  UPDATE public.lobbies SET quiz_index = quiz_index + 1 WHERE id = p_lobby_id;
  PERFORM public._quiz_start_question(p_lobby_id, v_ids[1]);
END $$;

-- Duell: nächster Song desselben Duells
CREATE OR REPLACE FUNCTION public._quiz_duel_song(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_ids uuid[];
BEGIN
  v_ids := public._quiz_candidates(p_lobby_id, 'duel', 1);
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  UPDATE public.lobbies SET quiz_options = jsonb_set(quiz_options, '{song}', to_jsonb(coalesce((quiz_options ->> 'song')::int, 0) + 1)) WHERE id = p_lobby_id;
  PERFORM public._quiz_start_question(p_lobby_id, v_ids[1]);
END $$;

-- Auflösung: Punkte, die erst am Ende feststehen (Jahr, Songwahl, Duell), dann Lösung zeigen
CREATE OR REPLACE FUNCTION public._quiz_reveal(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; v_title text; v_artist text;
        v_correct int; v_elig int; v_results jsonb; v_extra jsonb := '{}'::jsonb; v_winner uuid; v_done boolean := false;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  SELECT title, artist INTO v_title, v_artist FROM public.song_pool WHERE id = s.song_id;

  IF l.game_mode = 'year' AND s.year IS NOT NULL THEN
    UPDATE public.quiz_answers a
       SET points = CASE abs(a.num - s.year) WHEN 0 THEN 5 WHEN 1 THEN 3 WHEN 2 THEN 2 ELSE CASE WHEN abs(a.num - s.year) <= 5 THEN 1 ELSE 0 END END,
           correct = abs(a.num - s.year) <= 2
     WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND a.num IS NOT NULL;
    UPDATE public.players p SET song_points = coalesce(p.song_points, 0) + a.points
      FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq AND p.lobby_id = p_lobby_id AND p.player_id = a.player_id;
  END IF;

  IF l.game_mode = 'pick' AND l.quiz_picker IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE correct) INTO v_correct FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq;
    SELECT count(*) INTO v_elig FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active' AND player_id <> l.quiz_picker;
    IF v_correct > 0 AND v_correct < v_elig OR (v_elig = 1 AND v_correct = 1) THEN
      INSERT INTO public.quiz_answers (lobby_id, seq, player_id, correct, points) VALUES (p_lobby_id, l.quiz_seq, l.quiz_picker, true, 2)
      ON CONFLICT (lobby_id, seq, player_id) DO UPDATE SET points = 2, correct = true;
      UPDATE public.players SET song_points = coalesce(song_points, 0) + 2 WHERE lobby_id = p_lobby_id AND player_id = l.quiz_picker;
      v_extra := jsonb_build_object('pickerBonus', 2);
    END IF;
  END IF;

  IF l.game_mode = 'duel' THEN
    -- Duell entschieden? (2 Siege oder 3 Songs)
    IF (l.quiz_options ->> 'wa')::int >= 2 OR (l.quiz_options ->> 'wb')::int >= 2 OR (l.quiz_options ->> 'song')::int >= 3 THEN
      v_done := true;
      IF (l.quiz_options ->> 'wa')::int > (l.quiz_options ->> 'wb')::int THEN v_winner := (l.quiz_options ->> 'a')::uuid;
      ELSIF (l.quiz_options ->> 'wb')::int > (l.quiz_options ->> 'wa')::int THEN v_winner := (l.quiz_options ->> 'b')::uuid; END IF;
      IF v_winner IS NOT NULL THEN
        UPDATE public.players SET song_points = coalesce(song_points, 0) + 3 WHERE lobby_id = p_lobby_id AND player_id = v_winner;
        UPDATE public.players p SET song_points = coalesce(p.song_points, 0) + 1
          FROM public.quiz_bets b WHERE b.lobby_id = p_lobby_id AND b.duel = l.quiz_index AND b.pick = v_winner
            AND p.lobby_id = p_lobby_id AND p.player_id = b.player_id;
      END IF;
      v_extra := jsonb_build_object('duelDone', true, 'duelWinner', v_winner,
        'betWinners', (SELECT coalesce(jsonb_agg(b.player_id), '[]') FROM public.quiz_bets b WHERE b.lobby_id = p_lobby_id AND b.duel = l.quiz_index AND b.pick = v_winner));
    END IF;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('playerId', a.player_id, 'points', a.points, 'correct', a.correct,
           'answer', CASE WHEN l.game_mode = 'year' THEN a.num::text ELSE NULL END) ORDER BY a.points DESC, a.answered_at), '[]')
    INTO v_results FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.seq = l.quiz_seq;

  UPDATE public.lobbies
     SET quiz_state = 'reveal',
         quiz_reveal = jsonb_build_object('title', v_title, 'artist', v_artist, 'year', s.year, 'word', CASE WHEN l.game_mode = 'gap' THEN s.answer END,
                                          'results', v_results) || v_extra,
         quiz_started_at = now(), quiz_ends_at = now() + public._quiz_seconds(l.game_mode, 'reveal') * interval '1 second',
         quiz_options = CASE WHEN l.game_mode = 'duel' AND v_done THEN quiz_options || jsonb_build_object('done', true) ELSE quiz_options END,
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Runde vorbei: Rangliste nach Punkten (alle "leben"), dann Zwischenstand/Ende wie bei der Kartoffel
CREATE OR REPLACE FUNCTION public._quiz_finish(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_top uuid;
BEGIN
  SELECT player_id INTO v_top FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active'
    ORDER BY coalesce(song_points, 0) DESC, seat_index LIMIT 1;
  UPDATE public.lobbies SET quiz_state = NULL, quiz_ends_at = NULL, quiz_picker = NULL, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._finish_round(p_lobby_id);
  UPDATE public.lobbies SET holder_player_id = v_top WHERE id = p_lobby_id;
END $$;

-- Zeitgesteuerter Schritt (Server-Takt + Clients)
CREATE OR REPLACE FUNCTION public._quiz_tick(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; v_pick uuid; v_end timestamptz;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_ends_at IS NULL OR l.quiz_ends_at > now() THEN RETURN; END IF;

  IF l.quiz_state = 'pick' THEN
    SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
    v_pick := s.pick_options[1 + floor(random() * greatest(array_length(s.pick_options, 1), 1))::int];
    PERFORM public._quiz_start_question(p_lobby_id, v_pick);
  ELSIF l.quiz_state = 'bet' THEN
    PERFORM public._quiz_duel_song(p_lobby_id);
  ELSIF l.quiz_state = 'buzzed' THEN
    -- Zeit zum Antworten abgelaufen: Buzzer-Spieler ist für diesen Song raus
    v_end := greatest(coalesce((l.quiz_options ->> 'qend')::timestamptz, now()), now() + interval '5 seconds');
    UPDATE public.lobbies SET quiz_state = 'question', quiz_locked = array_append(quiz_locked, quiz_picker), quiz_picker = NULL,
                              quiz_ends_at = v_end, quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
    IF coalesce(array_length(public._quiz_eligible(p_lobby_id), 1), 0) = 0 THEN PERFORM public._quiz_reveal(p_lobby_id); END IF;
  ELSIF l.quiz_state = 'question' THEN
    PERFORM public._quiz_reveal(p_lobby_id);
  ELSIF l.quiz_state = 'reveal' THEN
    IF l.game_mode = 'duel' AND NOT coalesce((l.quiz_options ->> 'done')::boolean, false) THEN
      PERFORM public._quiz_duel_song(p_lobby_id);
    ELSE
      PERFORM public._quiz_next(p_lobby_id);
    END IF;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_tick(p_code text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.lobbies WHERE code = upper(trim(p_code)) AND phase = 'quiz' AND quiz_ends_at <= now();
  IF v_id IS NOT NULL THEN PERFORM public._quiz_tick(v_id); END IF;
END $$;

-- Quiz beginnen (nach dem Countdown)
CREATE OR REPLACE FUNCTION public._quiz_begin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text; v_n int;
BEGIN
  SELECT game_mode INTO v_mode FROM public.lobbies WHERE id = p_lobby_id;
  SELECT count(*) INTO v_n FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active';
  DELETE FROM public.quiz_answers WHERE lobby_id = p_lobby_id;
  DELETE FROM public.quiz_bets WHERE lobby_id = p_lobby_id;
  UPDATE public.players SET song_points = 0, is_alive = true, eliminated_at_round = NULL WHERE lobby_id = p_lobby_id AND status = 'active';
  UPDATE public.lobbies
     SET phase = 'quiz', explode_at = NULL, holder_player_id = NULL,
         quiz_index = 0, quiz_state = NULL, quiz_options = NULL, quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL,
         quiz_total = CASE v_mode WHEN 'artist' THEN 10 WHEN 'buzzer' THEN 10 WHEN 'duel' THEN least(4, greatest(2, v_n))
                                  WHEN 'pick' THEN least(12, greatest(6, v_n * 2)) ELSE 8 END,
         used_answers = '{}',
         used_song_ids = CASE WHEN coalesce(series_index, 1) <= 1 THEN '{}' ELSE coalesce(used_song_ids, '{}') END,
         run_started_at = now(), countdown_started_at = NULL, countdown_ends_at = NULL, countdown_starter_player_id = NULL,
         last_activity_at = now()
   WHERE id = p_lobby_id;
  PERFORM public._quiz_next(p_lobby_id);
END $$;

-- ------------------------------------------------------------ Aktionen (intern ohne Sitzungsprüfung, für Bots)
CREATE OR REPLACE FUNCTION public._quiz_do_answer(p_lobby_id uuid, p_player_id uuid, p_answer text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
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
  IF v_score >= 1 AND s.song_id IS NOT NULL THEN UPDATE public.song_pool SET hits = hits + 1 WHERE id = s.song_id; END IF;

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
END $$;

-- Auswahl-Antwort (Wer singt das? / Jahr raten): nur einmal
CREATE OR REPLACE FUNCTION public._quiz_do_choose(p_lobby_id uuid, p_player_id uuid, p_choice text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; v_ok boolean := false; v_rank int; v_pts numeric := 0; v_num int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_state <> 'question' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF l.game_mode NOT IN ('artist', 'year') THEN RAISE EXCEPTION 'quiz_wrong_action'; END IF;
  IF NOT (p_player_id = ANY (public._quiz_eligible(p_lobby_id))) THEN RAISE EXCEPTION 'quiz_not_your_turn'; END IF;
  IF EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND player_id = p_player_id) THEN
    RAISE EXCEPTION 'quiz_already_answered';
  END IF;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  IF l.game_mode = 'artist' THEN
    v_ok := lower(trim(p_choice)) = lower(trim(s.answer));
    IF v_ok THEN
      SELECT count(*) + 1 INTO v_rank FROM public.quiz_answers WHERE lobby_id = p_lobby_id AND seq = l.quiz_seq AND correct;
      v_pts := public._quiz_rank_points(v_rank);
      UPDATE public.players SET song_points = coalesce(song_points, 0) + v_pts WHERE lobby_id = p_lobby_id AND player_id = p_player_id;
    END IF;
  ELSE
    BEGIN v_num := trim(p_choice)::int; EXCEPTION WHEN others THEN RAISE EXCEPTION 'quiz_bad_year'; END;
    IF v_num < 1900 OR v_num > 2100 THEN RAISE EXCEPTION 'quiz_bad_year'; END IF;
  END IF;
  INSERT INTO public.quiz_answers (lobby_id, seq, player_id, answer, num, correct, points, tries, answered_at)
  VALUES (p_lobby_id, l.quiz_seq, p_player_id, left(p_choice, 80), v_num, v_ok, v_pts, 1, now());
  UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  PERFORM public._quiz_maybe_early(p_lobby_id);
  RETURN jsonb_build_object('correct', CASE WHEN l.game_mode = 'artist' THEN v_ok END, 'points', v_pts);
END $$;

CREATE OR REPLACE FUNCTION public._quiz_do_buzz(p_lobby_id uuid, p_player_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'buzzer' OR l.quiz_state <> 'question' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF p_player_id = ANY (l.quiz_locked) THEN RAISE EXCEPTION 'quiz_locked_out'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND status = 'active') THEN RAISE EXCEPTION 'not_a_member'; END IF;
  UPDATE public.lobbies
     SET quiz_state = 'buzzed', quiz_picker = p_player_id,
         quiz_options = coalesce(quiz_options, '{}'::jsonb) || jsonb_build_object('qend', quiz_ends_at),
         quiz_ends_at = now() + public._quiz_seconds('buzzer', 'buzzed') * interval '1 second', quiz_rev = quiz_rev + 1
   WHERE id = p_lobby_id;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_do_pick(p_lobby_id uuid, p_player_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'pick' OR l.quiz_state <> 'pick' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF l.quiz_picker IS DISTINCT FROM p_player_id THEN RAISE EXCEPTION 'quiz_not_your_turn'; END IF;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = p_lobby_id;
  IF NOT (p_song_id = ANY (s.pick_options)) THEN RAISE EXCEPTION 'quiz_bad_choice'; END IF;
  PERFORM public._quiz_start_question(p_lobby_id, p_song_id);
END $$;

CREATE OR REPLACE FUNCTION public._quiz_do_bet(p_lobby_id uuid, p_player_id uuid, p_pick uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id;
  IF l.phase <> 'quiz' OR l.game_mode <> 'duel' OR l.quiz_state <> 'bet' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF p_player_id::text IN (l.quiz_options ->> 'a', l.quiz_options ->> 'b') THEN RAISE EXCEPTION 'quiz_not_your_turn'; END IF;
  IF p_pick::text NOT IN (l.quiz_options ->> 'a', l.quiz_options ->> 'b') THEN RAISE EXCEPTION 'quiz_bad_choice'; END IF;
  INSERT INTO public.quiz_bets (lobby_id, duel, player_id, pick) VALUES (p_lobby_id, l.quiz_index, p_player_id, p_pick)
  ON CONFLICT (lobby_id, duel, player_id) DO UPDATE SET pick = excluded.pick;
  UPDATE public.lobbies SET quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
END $$;

-- ------------------------------------------------------------ Client-Funktionen (mit Sitzungsprüfung)
CREATE OR REPLACE FUNCTION public._quiz_lobby_for(p_code text, p_player_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.lobbies WHERE code = upper(trim(p_code));
  IF v_id IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
  IF NOT public._verify_session(v_id, p_player_id) THEN RAISE EXCEPTION 'invalid_session'; END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_answer(p_code text, p_player_id uuid, p_answer text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public._quiz_do_answer(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_answer); END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_choose(p_code text, p_player_id uuid, p_choice text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public._quiz_do_choose(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_choice); END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_buzz(p_code text, p_player_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN PERFORM public._quiz_do_buzz(public._quiz_lobby_for(p_code, p_player_id), p_player_id); END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_pick(p_code text, p_player_id uuid, p_song_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN PERFORM public._quiz_do_pick(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_song_id); END $$;

CREATE OR REPLACE FUNCTION public.rpc_quiz_bet(p_code text, p_player_id uuid, p_pick uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN PERFORM public._quiz_do_bet(public._quiz_lobby_for(p_code, p_player_id), p_player_id, p_pick); END $$;

-- Was der Client zur laufenden Frage wissen darf
CREATE OR REPLACE FUNCTION public.rpc_quiz_status(p_code text, p_player_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; l public.lobbies%ROWTYPE; s public.quiz_secret%ROWTYPE; v_me jsonb; v_pick jsonb; v_bets jsonb;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  SELECT * INTO l FROM public.lobbies WHERE id = v_id;
  SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = v_id;
  SELECT jsonb_build_object('answered', true, 'correct', a.correct, 'points', a.points, 'tries', a.tries, 'answer', a.answer)
    INTO v_me FROM public.quiz_answers a WHERE a.lobby_id = v_id AND a.seq = l.quiz_seq AND a.player_id = p_player_id;
  IF l.quiz_state = 'pick' AND l.quiz_picker = p_player_id THEN
    SELECT jsonb_agg(jsonb_build_object('id', sp.id, 'title', sp.title, 'artist', sp.artist)) INTO v_pick
      FROM public.song_pool sp WHERE sp.id = ANY (s.pick_options);
  END IF;
  IF l.game_mode = 'duel' THEN
    SELECT jsonb_build_object('a', count(*) FILTER (WHERE pick::text = l.quiz_options ->> 'a'), 'b', count(*) FILTER (WHERE pick::text = l.quiz_options ->> 'b'),
             'mine', max(CASE WHEN player_id = p_player_id THEN pick::text END))
      INTO v_bets FROM public.quiz_bets WHERE lobby_id = v_id AND duel = l.quiz_index;
  END IF;
  RETURN jsonb_build_object(
    'seq', l.quiz_seq,
    'me', coalesce(v_me, jsonb_build_object('answered', false)),
    'answered', (SELECT coalesce(jsonb_agg(player_id), '[]') FROM public.quiz_answers WHERE lobby_id = v_id AND seq = l.quiz_seq AND (correct OR l.game_mode IN ('artist', 'year'))),
    'pickOptions', v_pick,
    'bets', v_bets
  );
END $$;

-- ------------------------------------------------------------ Bots im Quiz
CREATE OR REPLACE FUNCTION public._quiz_bot_tick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r record; v_seed text; v_delay numeric; v_ok boolean; v_el numeric; s public.quiz_secret%ROWTYPE;
        v_answer text; v_choices jsonb; v_year int; v_range int; v_pick uuid;
BEGIN
  FOR r IN
    SELECT l.id AS lobby_id, l.game_mode, l.quiz_state, l.quiz_seq, l.quiz_index, l.quiz_started_at, l.quiz_picker, l.quiz_options, l.quiz_locked,
           p.player_id, coalesce(p.bot_skill, 2) AS skill
    FROM public.lobbies l JOIN public.players p ON p.lobby_id = l.id AND p.is_bot AND p.status = 'active'
    WHERE l.phase = 'quiz' AND l.quiz_state IN ('pick', 'bet', 'question', 'buzzed')
  LOOP
    BEGIN
      v_seed := r.player_id::text || ':' || r.quiz_seq || ':' || r.quiz_state || ':' || r.quiz_index;
      v_el := extract(epoch FROM now() - r.quiz_started_at);
      v_ok := (abs(hashtext('ok' || v_seed)) % 1000) / 1000.0 < (CASE r.skill WHEN 1 THEN 0.45 WHEN 3 THEN 0.85 ELSE 0.65 END);
      v_delay := CASE r.skill WHEN 1 THEN 6 WHEN 3 THEN 1.5 ELSE 3.5 END + (abs(hashtext('d' || v_seed)) % 1000) / 1000.0 * CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 2.5 ELSE 4.5 END;
      IF r.game_mode = 'snippet' THEN v_delay := v_delay * 1.6; END IF;

      IF r.quiz_state = 'pick' THEN
        IF r.quiz_picker = r.player_id AND v_el > 2.5 THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          PERFORM public._quiz_do_pick(r.lobby_id, r.player_id, s.pick_options[1 + abs(hashtext(v_seed)) % greatest(array_length(s.pick_options, 1), 1)]);
        END IF;
      ELSIF r.quiz_state = 'bet' THEN
        IF v_el > 2 AND r.player_id::text NOT IN (r.quiz_options ->> 'a', r.quiz_options ->> 'b')
           AND NOT EXISTS (SELECT 1 FROM public.quiz_bets WHERE lobby_id = r.lobby_id AND duel = r.quiz_index AND player_id = r.player_id) THEN
          PERFORM public._quiz_do_bet(r.lobby_id, r.player_id, (CASE WHEN abs(hashtext(v_seed)) % 2 = 0 THEN r.quiz_options ->> 'a' ELSE r.quiz_options ->> 'b' END)::uuid);
        END IF;
      ELSIF r.quiz_state = 'buzzed' THEN
        IF r.quiz_picker = r.player_id AND v_el > 1.5 THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 2 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
            INTO v_answer FROM public.song_pool WHERE id = s.song_id;
          PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
        END IF;
      ELSIF r.quiz_state = 'question' AND v_el >= v_delay THEN
        IF r.player_id = ANY (public._quiz_eligible(r.lobby_id))
           AND NOT EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = r.lobby_id AND seq = r.quiz_seq AND player_id = r.player_id) THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          IF r.game_mode = 'artist' THEN
            v_choices := r.quiz_options -> 'choices';
            v_answer := CASE WHEN v_ok THEN s.answer ELSE v_choices ->> (abs(hashtext('c' || v_seed)) % greatest(jsonb_array_length(v_choices), 1)) END;
            PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_answer);
          ELSIF r.game_mode = 'year' THEN
            v_range := CASE r.skill WHEN 1 THEN 7 WHEN 3 THEN 2 ELSE 4 END;
            v_year := coalesce(s.year, 2020) + (abs(hashtext('y' || v_seed)) % (2 * v_range + 1)) - v_range;
            PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_year::text);
          ELSIF r.game_mode = 'buzzer' THEN
            IF v_ok AND NOT (r.player_id = ANY (r.quiz_locked)) THEN PERFORM public._quiz_do_buzz(r.lobby_id, r.player_id); END IF;
          ELSIF v_ok THEN
            IF r.game_mode = 'gap' THEN v_answer := s.answer;
            ELSE
              SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 3 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
                INTO v_answer FROM public.song_pool WHERE id = s.song_id;
            END IF;
            PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END $$;

-- ------------------------------------------------------------ Einbindung in den bestehenden Ablauf
CREATE OR REPLACE FUNCTION public._server_tick()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select id, code, phase from public.lobbies
    where (phase = 'running' and explode_at is not null and explode_at <= now())
       or (phase = 'quiz' and quiz_ends_at is not null and quiz_ends_at <= now())
       or (phase = 'topic_vote' and topic_vote_ends_at is not null and topic_vote_ends_at <= now())
       or (phase = 'countdown' and countdown_ends_at is not null and countdown_ends_at <= now())
       or (phase in ('rematch_wait', 'set_summary') and countdown_ends_at is not null and countdown_ends_at <= now())
  loop
    begin
      if r.phase = 'running' then
        perform public.rpc_tick_game(r.code);
      elsif r.phase = 'quiz' then
        perform public._quiz_tick(r.id);
      elsif r.phase = 'topic_vote' then
        perform public.rpc_finalize_topic_vote(r.id);
      elsif r.phase = 'countdown' then
        perform public.rpc_advance_from_countdown(r.id);
      elsif r.phase = 'rematch_wait' then
        perform public.rpc_start_rematch_if_ready(r.code);
      elsif r.phase = 'set_summary' then
        perform public.rpc_start_next_set(r.code);
      end if;
    exception when others then
      null;
    end;
  end loop;
  -- Bots im Quiz (laufen hier mit, damit sie auch ohne offenen Browser antworten)
  begin
    perform public._quiz_bot_tick();
  exception when others then
    null;
  end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_lobby_mode(p_lobby_id uuid, p_me_player_id uuid, p_mode text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
  if v_mode not in ('original','teleport','reverse','teams','pick','buzzer','snippet','artist','year','gap','duel') then raise exception 'invalid_mode'; end if;
  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
  v_phase text;
begin
  select phase, round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_phase, v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'countdown' then return; end if;
  if coalesce(current_setting('request.headers', true), '') <> '' and exists (select 1 from public.lobbies where id = p_lobby_id and countdown_ends_at > now() + interval '1 second') then return; end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  -- Faire Weitergabe-Reihenfolge: Sitzplätze zufällig mischen.
  with act as (
    select player_id, seat_index as old_seat,
           row_number() over (order by seat_index) as rk
    from public.players
    where lobby_id = p_lobby_id and status = 'active'
  ), shuf as (
    select player_id, row_number() over (order by random()) as rk from act
  ), pick as (
    select s.player_id, a.old_seat
    from shuf s join act a on a.rk = s.rk
  )
  update public.players p set seat_index = -(pick.old_seat + 1)
  from pick where p.lobby_id = p_lobby_id and p.player_id = pick.player_id;

  update public.players set seat_index = -seat_index - 1
  where lobby_id = p_lobby_id and status = 'active' and seat_index < 0;

  update public.players set skips_left = 1
  where lobby_id = p_lobby_id and status = 'active';

  -- Quiz-Modi (108): alle raten gleichzeitig, keine Kartoffel
  if public._is_quiz_mode((select game_mode from public.lobbies where id = p_lobby_id)) then
    perform public._quiz_begin(p_lobby_id);
    return;
  end if;

  v_explode_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    greatest(1, v_alive_count),
    greatest(1, v_round_number)
  );

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + (v_explode_seconds * interval '1 second'),
      countdown_started_at = null,
      countdown_ends_at = null,
      countdown_starter_player_id = null,
      used_answers = '{}',
      -- Migration 092: gespielte Songs nur beim ersten Durchgang eines Matches leeren
      used_song_ids = case when coalesce(series_index, 1) <= 1 then '{}' else coalesce(used_song_ids, '{}') end,
      current_attempt_id = null,
      round_bonus_used = 0,
      last_pass_quality = 1,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- Arena-Punkte: im Quiz zählen Songpunkte x5 (statt x15), weil es dort pro Frage Punkte gibt
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  v_ranked boolean := public._lobby_human_count(p_lobby_id) >= 2;
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot, fastest_ms, slowest_ms)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * (case when public._is_quiz_mode((select game_mode from public.lobbies where id = p_lobby_id)) then 5 else 15 end))::int + t.tempo * 5,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot, t.fastest_ms, t.slowest_ms
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.tempo_pass_count, 0) as tempo,
           coalesce(p.is_bot, false) as is_bot,
           p.fastest_pass_ms as fastest_ms,
           p.slowest_pass_ms::int as slowest_ms
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler und nur, wenn mind. 2 Menschen mitspielen (075).
  if v_ranked then
    for r in
      select p.user_id, sr.arena_points, sr.place
      from public.series_results sr
      join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
      where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
    loop
      insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
      values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
      on conflict (user_id, season) do update
        set arena_points = public.season_points.arena_points + excluded.arena_points,
            sets_played = public.season_points.sets_played + 1,
            set_wins = public.season_points.set_wins + excluded.set_wins,
            updated_at = now();
    end loop;
  end if;

  -- Konto-Verlauf (076). Darf das Rundenende niemals blockieren.
  begin
    perform public._record_round_history(p_lobby_id);
  exception when others then
    raise warning 'record_round_history: %', sqlerrm;
  end;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    if v_ranked then
      begin
        perform public.aggregate_player_stats(p_lobby_id);
      exception when others then
        null;
      end;
    end if;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_quiz_answer(text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quiz_choose(text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quiz_buzz(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quiz_pick(text, uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quiz_bet(text, uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quiz_status(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quiz_tick(text) TO anon, authenticated;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_quiz_take_song(uuid,uuid)','_quiz_candidates(uuid,text,int)','_quiz_artist_options(uuid)','_quiz_start_question(uuid,uuid)',
    '_quiz_eligible(uuid)','_quiz_maybe_early(uuid)','_quiz_next(uuid)','_quiz_duel_song(uuid)','_quiz_reveal(uuid)','_quiz_finish(uuid)','_quiz_tick(uuid)',
    '_quiz_begin(uuid)','_quiz_do_answer(uuid,uuid,text)','_quiz_do_choose(uuid,uuid,text)','_quiz_do_buzz(uuid,uuid)','_quiz_do_pick(uuid,uuid,uuid)',
    '_quiz_do_bet(uuid,uuid,uuid)','_quiz_lobby_for(text,uuid)','_quiz_bot_tick()']
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

COMMIT;
