-- ============================================================
-- 143: Neuer Modus "Hit oder Flop" – 1-gegen-1-Battle mit Jury (Wunsch Mehdi, 2026-11-11)
-- ============================================================
-- Mindestens 3 Leute. Pro Duell: eine Jury (reihum), zwei Battle-Teilnehmer. Beide suchen einen Song aus der Datenbank
-- (oder schreiben einen Namen) und legen eine Stelle (8 Sekunden) fest. Beide Ausschnitte werden nacheinander gespielt, die Jury
-- entscheidet nach dem eingestellten Prinzip (Nostalgie / Sound / Reime / Hit-Faktor / wechselnd), wer gewinnt: +1 Punkt.
-- Es gibt so viele Duelle wie Spieler: jeder ist einmal Jury und tritt zweimal an (fair).
-- Zustände (lobbies.quiz_state): pick -> play_a -> play_b -> judge -> reveal -> (nächstes Duell | Ende)
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS battle_cfg jsonb;
ALTER TABLE public.lobbies DROP CONSTRAINT IF EXISTS lobbies_game_mode_check;
ALTER TABLE public.lobbies ADD CONSTRAINT lobbies_game_mode_check CHECK (game_mode = ANY (ARRAY['original', 'buzzer', 'year', 'letters', 'battle']));

-- Einstellung des Hosts: nach welchem Prinzip entscheidet die Jury?
CREATE OR REPLACE FUNCTION public.set_battle_config(p_lobby_id uuid, p_me_player_id uuid, p_cfg jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_host uuid; v_phase text; v_crit text;
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_me_player_id) THEN RAISE EXCEPTION 'invalid_session'; END IF;
  SELECT host_player_id, phase INTO v_host, v_phase FROM public.lobbies WHERE id = p_lobby_id;
  IF v_host IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
  IF v_host IS DISTINCT FROM p_me_player_id THEN RAISE EXCEPTION 'not_host'; END IF;
  IF v_phase NOT IN ('waiting', 'finished') THEN RAISE EXCEPTION 'lobby_not_waiting'; END IF;
  v_crit := p_cfg ->> 'criterion';
  IF v_crit IS NULL OR v_crit NOT IN ('nostalgia', 'sound', 'lyrics', 'hit', 'random') THEN RAISE EXCEPTION 'battle_bad_config'; END IF;
  UPDATE public.lobbies SET battle_cfg = jsonb_build_object('criterion', v_crit), settings_version = coalesce(settings_version, 0) + 1 WHERE id = p_lobby_id;
END $$;

-- Aktive Spieler in fester Reihenfolge (Sitzplatz, dann Beitritt)
CREATE OR REPLACE FUNCTION public._battle_order(p_lobby_id uuid) RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(array_agg(player_id ORDER BY seat_index NULLS LAST, joined_at, player_id), '{}'::uuid[])
    FROM public.players WHERE lobby_id = p_lobby_id AND status = 'active'
$$;

CREATE OR REPLACE FUNCTION public._battle_crit(p_lobby_id uuid, p_duel int) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN coalesce(battle_cfg ->> 'criterion', 'hit') = 'random'
              THEN (ARRAY['nostalgia', 'sound', 'lyrics', 'hit'])[1 + abs(hashtext(p_lobby_id::text || ':' || p_duel::text)) % 4]
              ELSE coalesce(battle_cfg ->> 'criterion', 'hit') END
    FROM public.lobbies WHERE id = p_lobby_id
$$;

-- Spielstart: so viele Duelle wie Spieler
CREATE OR REPLACE FUNCTION public._battle_begin(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.lobbies SET quiz_total = cardinality(public._battle_order(p_lobby_id)), quiz_index = 0, quiz_target = NULL WHERE id = p_lobby_id;
  PERFORM public._battle_next(p_lobby_id);
END $$;

-- Nächstes Duell: Jury = der Reihe nach, die beiden Nächsten treten an (jeder: einmal Jury, zweimal Battle)
CREATE OR REPLACE FUNCTION public._battle_next(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_ord uuid[]; n int; d int;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  v_ord := public._battle_order(p_lobby_id);
  n := cardinality(v_ord);
  IF n < 3 OR l.quiz_index >= l.quiz_total THEN PERFORM public._quiz_finish(p_lobby_id); RETURN; END IF;
  d := l.quiz_index;
  UPDATE public.lobbies
     SET quiz_index = quiz_index + 1, quiz_seq = quiz_seq + 1, quiz_state = 'pick', quiz_started_at = now(),
         quiz_ends_at = now() + interval '90 seconds', quiz_reveal = NULL, quiz_locked = '{}', quiz_picker = NULL,
         quiz_options = jsonb_build_object('duel', jsonb_build_object(
           'n', d + 1, 'jury', v_ord[1 + d % n], 'a', v_ord[1 + (d + 1) % n], 'b', v_ord[1 + (d + 2) % n],
           'crit', public._battle_crit(p_lobby_id, d), 'picks', '{}'::jsonb, 'clip', 8)),
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Beide haben gewählt: Ausschnitt A läuft (8 s + 2 s Puffer)
CREATE OR REPLACE FUNCTION public._battle_start_play(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.lobbies SET quiz_state = 'play_a', quiz_started_at = now(), quiz_ends_at = now() + interval '10 seconds', quiz_rev = quiz_rev + 1, last_activity_at = now() WHERE id = p_lobby_id;
END $$;

-- Eine Wahl eintragen (aus einer Wahl-RPC, dem Takt oder einem Bot); sind beide da, geht es weiter
CREATE OR REPLACE FUNCTION public._battle_set_pick(p_lobby_id uuid, p_side text, p_pick jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.quiz_state <> 'pick' OR (l.quiz_options -> 'duel' -> 'picks') ? p_side THEN RETURN; END IF;
  UPDATE public.lobbies SET quiz_options = jsonb_set(quiz_options, ARRAY['duel', 'picks', p_side], p_pick), quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  IF (SELECT (quiz_options -> 'duel' -> 'picks') ?& ARRAY['a', 'b'] FROM public.lobbies WHERE id = p_lobby_id) THEN
    PERFORM public._battle_start_play(p_lobby_id);
  END IF;
END $$;

-- Zufälliger Song für jemanden, der nicht rechtzeitig gewählt hat (und für Bots)
CREATE OR REPLACE FUNCTION public._battle_random_pick(p_lobby_id uuid, p_side text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE s record;
BEGIN
  SELECT sp.id, sp.title, sp.artist, coalesce(sp.vocal_start_ms, 0) / 1000 AS vs INTO s
    FROM public.song_pool sp
   WHERE sp.preview_url IS NOT NULL AND sp.archived_from IS NULL
     AND NOT (sp.id = ANY (coalesce((SELECT used_song_ids FROM public.lobbies WHERE id = p_lobby_id), '{}')))
   ORDER BY random() LIMIT 1;
  IF s.id IS NULL THEN
    PERFORM public._battle_set_pick(p_lobby_id, p_side, jsonb_build_object('songId', NULL, 'title', '?', 'artist', NULL, 'start', 0, 'free', true));
    RETURN;
  END IF;
  UPDATE public.lobbies SET used_song_ids = array_append(coalesce(used_song_ids, '{}'), s.id) WHERE id = p_lobby_id;
  PERFORM public._battle_set_pick(p_lobby_id, p_side, jsonb_build_object('songId', s.id, 'title', s.title, 'artist', s.artist, 'start', greatest(0, least(22, s.vs::int)), 'free', false));
END $$;

-- Entscheidung der Jury (side = 'a' | 'b' | NULL für unentschieden); +1 Punkt für den Sieger
CREATE OR REPLACE FUNCTION public._battle_reveal(p_lobby_id uuid, p_side text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_duel jsonb; v_winner uuid;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.quiz_state NOT IN ('judge', 'play_a', 'play_b', 'pick') THEN RETURN; END IF;
  v_duel := l.quiz_options -> 'duel';
  IF p_side IN ('a', 'b') THEN
    v_winner := (v_duel ->> p_side)::uuid;
    UPDATE public.players SET song_points = coalesce(song_points, 0) + 1 WHERE lobby_id = p_lobby_id AND player_id = v_winner;
  END IF;
  UPDATE public.lobbies
     SET quiz_state = 'reveal', quiz_started_at = now(), quiz_ends_at = now() + interval '9 seconds',
         quiz_reveal = jsonb_build_object('winner', p_side, 'winnerId', v_winner, 'jury', v_duel -> 'jury', 'crit', v_duel -> 'crit', 'n', v_duel -> 'n',
                                          'a', jsonb_build_object('playerId', v_duel -> 'a') || coalesce(v_duel -> 'picks' -> 'a', '{}'::jsonb),
                                          'b', jsonb_build_object('playerId', v_duel -> 'b') || coalesce(v_duel -> 'picks' -> 'b', '{}'::jsonb)),
         quiz_rev = quiz_rev + 1, last_activity_at = now()
   WHERE id = p_lobby_id;
END $$;

-- Takt (Zeit abgelaufen)
CREATE OR REPLACE FUNCTION public._battle_tick(p_lobby_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; s text;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'battle' OR l.quiz_ends_at IS NULL OR l.quiz_ends_at > now() THEN RETURN; END IF;
  IF l.quiz_state = 'pick' THEN
    FOREACH s IN ARRAY ARRAY['a', 'b'] LOOP
      IF NOT ((SELECT quiz_options -> 'duel' -> 'picks' FROM public.lobbies WHERE id = p_lobby_id) ? s) THEN PERFORM public._battle_random_pick(p_lobby_id, s); END IF;
    END LOOP;
  ELSIF l.quiz_state = 'play_a' THEN
    UPDATE public.lobbies SET quiz_state = 'play_b', quiz_started_at = now(), quiz_ends_at = now() + interval '10 seconds', quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  ELSIF l.quiz_state = 'play_b' THEN
    UPDATE public.lobbies SET quiz_state = 'judge', quiz_started_at = now(), quiz_ends_at = now() + interval '45 seconds', quiz_rev = quiz_rev + 1 WHERE id = p_lobby_id;
  ELSIF l.quiz_state = 'judge' THEN
    PERFORM public._battle_reveal(p_lobby_id, NULL);   -- Jury hat nicht entschieden: unentschieden, kein Punkt
  ELSIF l.quiz_state = 'reveal' THEN
    PERFORM public._battle_next(p_lobby_id);
  END IF;
END $$;

-- Bots: wählen einen Zufallssong und entscheiden (als Jury) nach ein paar Sekunden
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
            PERFORM public._battle_random_pick(r.id, s);
          END IF;
        END LOOP;
      ELSE
        v_pid := (r.quiz_options -> 'duel' ->> 'jury')::uuid;
        IF EXISTS (SELECT 1 FROM public.players WHERE player_id = v_pid AND lobby_id = r.id AND is_bot)
           AND v_el >= 3 + (abs(hashtext('j' || v_pid::text || r.quiz_seq)) % 4) THEN
          PERFORM public._battle_reveal(r.id, CASE WHEN abs(hashtext('w' || v_pid::text || r.quiz_seq)) % 2 = 0 THEN 'a' ELSE 'b' END);
        END IF;
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END $$;

-- Song suchen (nur in einem Battle-Spiel, nur für Mitspieler)
CREATE OR REPLACE FUNCTION public.rpc_battle_search(p_code text, p_player_id uuid, p_query text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; v_q text;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  IF NOT EXISTS (SELECT 1 FROM public.lobbies WHERE id = v_id AND game_mode = 'battle' AND phase = 'quiz') THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  PERFORM public._rate_limit('battlesearch:' || p_player_id::text, 90, 60);
  v_q := lower(trim(left(coalesce(p_query, ''), 40)));
  IF length(v_q) < 2 THEN RETURN '[]'::jsonb; END IF;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'artist', x.artist, 'year', x.release_year, 'vs', greatest(0, least(22, coalesce(x.vocal_start_ms, 0) / 1000)))) FROM (
      SELECT sp.id, sp.title, sp.artist, sp.release_year, sp.vocal_start_ms FROM public.song_pool sp
       WHERE sp.preview_url IS NOT NULL AND sp.archived_from IS NULL
         AND (lower(sp.title) LIKE '%' || v_q || '%' OR lower(sp.artist) LIKE '%' || v_q || '%')
       ORDER BY (lower(sp.title) LIKE v_q || '%') DESC, sp.plays DESC NULLS LAST, sp.title LIMIT 12
    ) x), '[]'::jsonb);
END $$;

-- Song + Stelle festlegen (endgültig). Entweder ein Song aus der Datenbank oder nur ein Name (dann ohne Ausschnitt).
CREATE OR REPLACE FUNCTION public.rpc_battle_pick(p_code text, p_player_id uuid, p_song_id uuid, p_text text, p_start int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; l public.lobbies%ROWTYPE; v_side text; v_clean text; s record;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  SELECT * INTO l FROM public.lobbies WHERE id = v_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'battle' OR l.quiz_state <> 'pick' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  v_side := CASE WHEN p_player_id = (l.quiz_options -> 'duel' ->> 'a')::uuid THEN 'a' WHEN p_player_id = (l.quiz_options -> 'duel' ->> 'b')::uuid THEN 'b' END;
  IF v_side IS NULL THEN RAISE EXCEPTION 'battle_not_battler'; END IF;
  IF (l.quiz_options -> 'duel' -> 'picks') ? v_side THEN RAISE EXCEPTION 'battle_already_picked'; END IF;
  v_clean := left(trim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), 60);
  IF p_song_id IS NOT NULL THEN
    SELECT sp.title, sp.artist INTO s FROM public.song_pool sp WHERE sp.id = p_song_id AND sp.preview_url IS NOT NULL AND sp.archived_from IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'battle_bad_song'; END IF;
    PERFORM public._battle_set_pick(v_id, v_side, jsonb_build_object('songId', p_song_id, 'title', s.title, 'artist', s.artist, 'start', greatest(0, least(22, coalesce(p_start, 0))), 'free', false));
  ELSE
    IF length(v_clean) < 2 THEN RAISE EXCEPTION 'battle_no_song'; END IF;
    PERFORM public._battle_set_pick(v_id, v_side, jsonb_build_object('songId', NULL, 'title', v_clean, 'artist', NULL, 'start', 0, 'free', true));
  END IF;
END $$;

-- Die Jury entscheidet
CREATE OR REPLACE FUNCTION public.rpc_battle_judge(p_code text, p_player_id uuid, p_side text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; l public.lobbies%ROWTYPE;
BEGIN
  v_id := public._quiz_lobby_for(p_code, p_player_id);
  SELECT * INTO l FROM public.lobbies WHERE id = v_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.game_mode <> 'battle' OR l.quiz_state <> 'judge' THEN RAISE EXCEPTION 'quiz_closed'; END IF;
  IF p_player_id IS DISTINCT FROM (l.quiz_options -> 'duel' ->> 'jury')::uuid THEN RAISE EXCEPTION 'battle_not_jury'; END IF;
  IF p_side NOT IN ('a', 'b') THEN RAISE EXCEPTION 'battle_bad_side'; END IF;
  PERFORM public._battle_reveal(v_id, p_side);
END $$;

CREATE OR REPLACE FUNCTION public._quiz_begin(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF v_mode = 'letters' THEN PERFORM public._letters_spin(p_lobby_id);
  ELSIF v_mode = 'battle' THEN PERFORM public._battle_begin(p_lobby_id);
  ELSE PERFORM public._quiz_next(p_lobby_id); END IF;
END $function$;

CREATE OR REPLACE FUNCTION public._quiz_tick(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE l public.lobbies%ROWTYPE; v_end timestamptz; v_pen numeric;
BEGIN
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id FOR UPDATE;
  IF l.phase <> 'quiz' OR l.quiz_ends_at IS NULL OR l.quiz_ends_at > now() THEN RETURN; END IF;
  IF l.game_mode = 'battle' THEN PERFORM public._battle_tick(p_lobby_id); RETURN; END IF;
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
END $function$;

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
  if v_mode not in ('original','buzzer','year','letters','battle') then raise exception 'invalid_mode'; end if;
  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public._is_quiz_mode(p_mode text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT coalesce(p_mode, '') = ANY (ARRAY['buzzer','year','letters','battle']) $function$;

CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id for update;
  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  -- 143: Hit oder Flop braucht mindestens 3 Leute (Jury + zwei Battle-Teilnehmer)
  if (select game_mode from public.lobbies where id = p_lobby_id) = 'battle'
     and (select count(*) from public.players where lobby_id = p_lobby_id and status = 'active') < 3 then
    raise exception 'battle_need_three';
  end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(p_lobby_id);

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public._quiz_bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_m int; v_seed text; v_delay numeric; v_ok boolean; v_el numeric; s public.quiz_secret%ROWTYPE; v_answer text; v_year int; v_range int;
BEGIN
  PERFORM public._battle_bot_tick();
  FOR r IN
    SELECT l.id AS lobby_id, l.game_mode, l.quiz_state, l.quiz_seq, l.quiz_index, l.quiz_started_at, l.quiz_picker, l.quiz_locked, l.quiz_options,
           p.player_id, coalesce(p.bot_skill, 2) AS skill
    FROM public.lobbies l JOIN public.players p ON p.lobby_id = l.id AND p.is_bot AND p.status = 'active'
    WHERE l.phase = 'quiz' AND l.quiz_state IN ('question', 'buzzed', 'month')
  LOOP
    BEGIN
      v_seed := r.player_id::text || ':' || r.quiz_seq || ':' || r.quiz_state || ':' || r.quiz_index;
      v_el := extract(epoch FROM now() - r.quiz_started_at);
      v_ok := (abs(hashtext('ok' || v_seed)) % 1000) / 1000.0 < (CASE r.skill WHEN 1 THEN 0.45 WHEN 3 THEN 0.85 ELSE 0.65 END);
      v_delay := CASE r.skill WHEN 1 THEN 6 WHEN 3 THEN 1.5 ELSE 3.5 END + (abs(hashtext('d' || v_seed)) % 1000) / 1000.0 * CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 2.5 ELSE 4.5 END;
      IF r.game_mode = 'buzzer' THEN v_delay := v_delay * 2.2 + 2; END IF;

      IF r.quiz_state = 'buzzed' THEN
        IF r.quiz_picker = r.player_id AND v_el > 1.5 THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 2 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
            INTO v_answer FROM public.song_pool WHERE id = s.song_id;
          PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
        END IF;
      ELSIF r.quiz_state = 'month' AND r.game_mode = 'year' AND v_el >= 1.5 + (abs(hashtext('m' || v_seed)) % 1000) / 1000.0 * 4
            AND (r.quiz_options -> 'tie' -> 'players') ? r.player_id::text
            AND NOT EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = r.lobby_id AND seq = r.quiz_seq AND player_id = r.player_id AND month IS NOT NULL) THEN
        SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
        v_m := ((coalesce(s.month, 6) - 1 + (abs(hashtext('mo' || v_seed)) % (2 * (CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 1 ELSE 3 END) + 1)) - (CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 1 ELSE 3 END) + 24) % 12) + 1;
        PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_m::text);
      ELSIF r.quiz_state = 'question' AND v_el >= v_delay THEN
        IF r.game_mode = 'buzzer' THEN
          IF v_ok AND NOT (r.player_id = ANY (r.quiz_locked)) THEN PERFORM public._quiz_do_buzz(r.lobby_id, r.player_id); END IF;
        ELSIF r.game_mode = 'year'
              AND NOT EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = r.lobby_id AND seq = r.quiz_seq AND player_id = r.player_id) THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          v_range := CASE r.skill WHEN 1 THEN 7 WHEN 3 THEN 2 ELSE 4 END;
          v_year := coalesce(s.year, 2020) + (abs(hashtext('y' || v_seed)) % (2 * v_range + 1)) - v_range;
          v_year := greatest(coalesce((r.quiz_options ->> 'yearMin')::int, 1900), least(coalesce((r.quiz_options ->> 'yearMax')::int, 2100), v_year));
          PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_year::text);
        END IF;
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END $function$;

CREATE OR REPLACE FUNCTION public._trg_vote_cards()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from 'topic_vote' then
    -- 127: Roulette braucht keine Playlist – nichts abzustimmen
    n := case when NEW.game_mode in ('letters', 'battle') then 1 else coalesce(cardinality(public._vote_topic_pool(NEW.topic_filter)), 0) end;
    NEW.topic_vote_cards := least(3, greatest(n, 1));
    if n <= 1 then
      NEW.topic_vote_ends_at := now();   -- nur eine Playlist: nichts abzustimmen
      NEW.topic_b := NEW.topic_a;
    end if;
  end if;
  return NEW;
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
  if h ->> 'mode' in ('original', 'buzzer', 'year', 'letters', 'battle') then host_out := host_out || jsonb_build_object('mode', h ->> 'mode'); end if;
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
  if s ->> 'mode' in ('original', 'buzzer', 'year', 'letters', 'battle') then solo_out := solo_out || jsonb_build_object('mode', s ->> 'mode'); end if;
  if s ->> 'speed' in ('fast', 'normal', 'calm') then solo_out := solo_out || jsonb_build_object('speed', s ->> 'speed'); end if;
  if solo_out <> '{}'::jsonb then out := out || jsonb_build_object('solo', solo_out); end if;

  update public.profiles set preferences = out where id = v_uid;
  return out;
end;
$function$;

-- Rechte: interne Funktionen gesperrt, die RPCs für Spieler offen (Prüfung der Sitzung steckt in den Funktionen)
REVOKE ALL ON FUNCTION public._battle_order(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_crit(uuid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_begin(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_next(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_start_play(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_set_pick(uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_random_pick(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_reveal(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_tick(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._battle_bot_tick() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_battle_config(uuid, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_battle_search(text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_battle_pick(text, uuid, uuid, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_battle_judge(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_battle_config(uuid, uuid, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_battle_search(text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_battle_pick(text, uuid, uuid, text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_battle_judge(text, uuid, text) TO anon, authenticated;

COMMIT;
