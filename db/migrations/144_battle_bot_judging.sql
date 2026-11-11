-- ============================================================
-- 144: Hit oder Flop – Bots bewerten und wählen mit Logik (Wunsch Mehdi, 2026-11-12)
-- ============================================================
-- Vorher: Der Bot als Jury warf praktisch eine Münze (Hash), Bot-Duellanten nahmen einen zufälligen Song.
-- Jetzt bekommt jeder Song für jedes Prinzip einen Wert von 0 bis 1 (_battle_song_score):
--   Hit-Faktor : 60 % Bekanntheit (wie oft Menschen den Song im Quiz erkannt haben, im Vergleich zu allen Songs),
--                25 % wie oft er schon gespielt wurde, 15 % Geschmack des Bots
--   Nostalgie  : 50 % Alter (bis 18 Jahre alt = voller Wert), 30 % Bekanntheit, 20 % Geschmack
--   Sound      : 25 % Bekanntheit, 15 % Beliebtheit, 60 % Geschmack  (Bots haben keine Ohren: Geschmack = fester Zufallswert je Bot + Song)
--   Reime      : 25 % Bekanntheit, 75 % Geschmack                    (keine Textdaten vorhanden)
-- Die Jury (Bot) vergleicht die beiden Werte. Wie sehr sie den Daten folgt, hängt von der Stärke ab (Anfänger 50 %, Mittel 75 %,
-- Profi 92 %, der Rest ist Tagesform). Liegen die Werte fast gleichauf, entscheidet der Geschmack – nie einfach "A".
-- Bot-Duellanten ziehen mehrere Songs (Anfänger 3, Mittel 6, Profi 12) und nehmen den, der zum Prinzip am besten passt.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._battle_song_score(p_song_id uuid, p_crit text, p_taste text) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE s record; v_known numeric; v_pop numeric; v_nost numeric; v_taste numeric;
BEGIN
  v_taste := (abs(hashtext(coalesce(p_taste, '') || ':' || coalesce(p_song_id::text, ''))) % 1000) / 1000.0;
  SELECT plays, hits, release_year INTO s FROM public.song_pool WHERE id = p_song_id;
  IF NOT FOUND THEN RETURN 0.3 + 0.4 * v_taste; END IF;   -- Song nicht in der Datenbank (nur Name getippt): neutral + Geschmack
  SELECT count(*) FILTER (WHERE (x.hits + 1.0) / (x.plays + 3.0) < (s.hits + 1.0) / (s.plays + 3.0))::numeric / greatest(1, count(*)),
         count(*) FILTER (WHERE x.plays < s.plays)::numeric / greatest(1, count(*))
    INTO v_known, v_pop
    FROM public.song_pool x WHERE x.preview_url IS NOT NULL AND x.archived_from IS NULL;
  v_nost := CASE WHEN s.release_year IS NULL THEN 0.3 ELSE least(1, greatest(0, extract(year FROM now())::int - s.release_year) / 18.0) END;
  RETURN CASE p_crit
    WHEN 'hit'       THEN 0.60 * v_known + 0.25 * v_pop + 0.15 * v_taste
    WHEN 'nostalgia' THEN 0.50 * v_nost + 0.30 * v_known + 0.20 * v_taste
    WHEN 'sound'     THEN 0.25 * v_known + 0.15 * v_pop + 0.60 * v_taste
    ELSE                  0.25 * v_known + 0.75 * v_taste
  END;
END $$;

-- Bot-Jury: vergleicht die beiden Songs nach dem Prinzip des Duells
CREATE OR REPLACE FUNCTION public._battle_bot_judge(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_jury uuid; v_skill int; w numeric; v_crit text; v_score numeric[] := ARRAY[0, 0]; v_mood numeric[] := ARRAY[0, 0];
        i int; s text; v_song uuid; v_side text;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.quiz_state <> 'judge' THEN RETURN; END IF;
  v_jury := (l.quiz_options -> 'duel' ->> 'jury')::uuid;
  v_crit := coalesce(l.quiz_options -> 'duel' ->> 'crit', 'hit');
  SELECT coalesce(bot_skill, 2) INTO v_skill FROM public.players WHERE lobby_id = p_lobby_id AND player_id = v_jury;
  w := CASE v_skill WHEN 1 THEN 0.50 WHEN 3 THEN 0.92 ELSE 0.75 END;
  i := 0;
  FOREACH s IN ARRAY ARRAY['a', 'b'] LOOP
    i := i + 1;
    v_song := (l.quiz_options -> 'duel' -> 'picks' -> s ->> 'songId')::uuid;
    IF v_song IS NULL THEN   -- nur Name getippt: gibt es den Song unter diesem Titel in der Datenbank?
      SELECT sp.id INTO v_song FROM public.song_pool sp WHERE sp.lower_title = lower(l.quiz_options -> 'duel' -> 'picks' -> s ->> 'title') LIMIT 1;
    END IF;
    v_mood[i] := (abs(hashtext('m' || v_jury::text || ':' || l.quiz_seq || ':' || s)) % 1000) / 1000.0;
    v_score[i] := w * public._battle_song_score(v_song, v_crit, v_jury::text) + (1 - w) * v_mood[i];
  END LOOP;
  v_side := CASE WHEN abs(v_score[1] - v_score[2]) < 0.03 THEN CASE WHEN v_mood[1] >= v_mood[2] THEN 'a' ELSE 'b' END
                 WHEN v_score[1] > v_score[2] THEN 'a' ELSE 'b' END;
  PERFORM public._battle_reveal(p_lobby_id, v_side);
END $$;

-- Bot-Duellant: zieht mehrere Songs und nimmt den, der zum Prinzip am besten passt (Profis ziehen mehr)
CREATE OR REPLACE FUNCTION public._battle_bot_pick(p_lobby_id uuid, p_side text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_bot uuid; v_skill int; v_n int; v_crit text; s record;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.quiz_state <> 'pick' OR (l.quiz_options -> 'duel' -> 'picks') ? p_side THEN RETURN; END IF;
  v_bot := (l.quiz_options -> 'duel' ->> p_side)::uuid;
  v_crit := coalesce(l.quiz_options -> 'duel' ->> 'crit', 'hit');
  SELECT coalesce(bot_skill, 2) INTO v_skill FROM public.players WHERE lobby_id = p_lobby_id AND player_id = v_bot;
  v_n := CASE v_skill WHEN 1 THEN 3 WHEN 3 THEN 12 ELSE 6 END;
  SELECT c.id, c.title, c.artist, coalesce(c.vocal_start_ms, 0) / 1000 AS vs INTO s FROM (
    SELECT sp.id, sp.title, sp.artist, sp.vocal_start_ms FROM public.song_pool sp
     WHERE sp.preview_url IS NOT NULL AND sp.archived_from IS NULL AND NOT (sp.id = ANY (coalesce(l.used_song_ids, '{}')))
     ORDER BY random() LIMIT v_n) c
   ORDER BY public._battle_song_score(c.id, v_crit, v_bot::text) DESC LIMIT 1;
  IF s.id IS NULL THEN PERFORM public._battle_random_pick(p_lobby_id, p_side); RETURN; END IF;
  UPDATE public.lobbies SET used_song_ids = array_append(coalesce(used_song_ids, '{}'), s.id) WHERE id = p_lobby_id;
  PERFORM public._battle_set_pick(p_lobby_id, p_side, jsonb_build_object('songId', s.id, 'title', s.title, 'artist', s.artist, 'start', greatest(0, least(22, s.vs::int)), 'free', false));
END $$;

-- Takt für Bots: ruft jetzt die Logik statt Zufall
CREATE OR REPLACE FUNCTION public._battle_bot_tick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r record; v_el numeric; s text; v_pid uuid; v_seed text;
BEGIN
  FOR r IN SELECT id, quiz_state, quiz_started_at, quiz_options, quiz_seq FROM public.lobbies WHERE phase = 'quiz' AND game_mode = 'battle' AND quiz_state IN ('pick', 'judge') LOOP
    BEGIN
      v_el := extract(epoch FROM now() - r.quiz_started_at);
      IF r.quiz_state = 'pick' THEN
        FOREACH s IN ARRAY ARRAY['a', 'b'] LOOP
          v_pid := (r.quiz_options -> 'duel' ->> s)::uuid;
          v_seed := v_pid::text || ':' || r.quiz_seq;
          IF EXISTS (SELECT 1 FROM public.players WHERE player_id = v_pid AND lobby_id = r.id AND is_bot)
             AND NOT ((r.quiz_options -> 'duel' -> 'picks') ? s) AND v_el >= 2 + (abs(hashtext('p' || v_seed)) % 4) THEN
            PERFORM public._battle_bot_pick(r.id, s);
          END IF;
        END LOOP;
      ELSE
        v_pid := (r.quiz_options -> 'duel' ->> 'jury')::uuid;
        IF EXISTS (SELECT 1 FROM public.players WHERE player_id = v_pid AND lobby_id = r.id AND is_bot)
           AND v_el >= 3 + (abs(hashtext('j' || v_pid::text || r.quiz_seq)) % 4) THEN
          PERFORM public._battle_bot_judge(r.id);
        END IF;
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION public._battle_song_score(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_bot_judge(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_bot_pick(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_bot_tick() FROM PUBLIC;

COMMIT;
