-- ============================================================
-- 139: Freunde herausfordern – Punkte schlagen als Solo-Spiel (Wunsch Mehdi, 2026-11-02)
-- ============================================================
-- Wer ein Quiz-Spiel (Buzzer, Zeitreise, Roulette) beendet hat, kann einen Link teilen. Der Freund spielt mit denselben
-- Einstellungen allein gegen Bots und versucht, die Punktzahl zu schlagen. Die Punkte rechnet immer der Server aus
-- (players.song_points bzw. Summe der Satz-Punkte), nie der Browser.
--   rpc_challenge_create(lobby, spieler)  -> Code (nur Menschen im beendeten Quiz-Spiel)
--   get_challenge(code)                   -> Einstellungen, Punktzahl zum Schlagen, beste Versuche (für alle lesbar)
--   rpc_challenge_attach(code, lobby, sp) -> verknüpft die neue Solo-Lobby des Freundes mit der Herausforderung
--   rpc_challenge_submit(lobby, sp)       -> speichert das Ergebnis nach dem Spiel (einmal pro Lobby) und liefert den Vergleich
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.challenges (
  code text PRIMARY KEY,
  user_id uuid,
  creator_name text NOT NULL,
  mode text NOT NULL,
  score int NOT NULL,
  series_total int NOT NULL DEFAULT 1,
  round_speed text NOT NULL DEFAULT 'normal',
  round_seconds int NOT NULL DEFAULT 20,
  topic_filter text[] NOT NULL DEFAULT '{}',
  letters_cfg jsonb,
  bots int NOT NULL DEFAULT 3,
  bot_skill int NOT NULL DEFAULT 2,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '30 days'
);
CREATE TABLE IF NOT EXISTS public.challenge_results (
  lobby_id uuid PRIMARY KEY,
  code text NOT NULL REFERENCES public.challenges(code) ON DELETE CASCADE,
  user_id uuid,
  name text NOT NULL,
  score int NOT NULL,
  played_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS challenge_results_code_idx ON public.challenge_results (code, score DESC);
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS challenge_code text;
ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.challenge_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.challenges FROM anon, authenticated;
REVOKE ALL ON public.challenge_results FROM anon, authenticated;

-- Punkte eines Spielers im beendeten Spiel: Einzelspiel = Song-Punkte, Serie = Summe der Satz-Punkte
CREATE OR REPLACE FUNCTION public._challenge_score(p_lobby_id uuid, p_player_id uuid) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN coalesce(l.series_total, 1) > 1
              THEN round(coalesce((SELECT sum(sr.song_points) FROM public.series_results sr WHERE sr.lobby_id = l.id AND sr.player_id = p_player_id), 0))::int
              ELSE round(coalesce((SELECT p.song_points FROM public.players p WHERE p.lobby_id = l.id AND p.player_id = p_player_id), 0))::int END
    FROM public.lobbies l WHERE l.id = p_lobby_id;
$$;
REVOKE ALL ON FUNCTION public._challenge_score(uuid, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.rpc_challenge_create(p_lobby_id uuid, p_player_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; v_name text; v_user uuid; v_code text; v_bots int; v_skill int; v_try int := 0;
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_player_id) THEN RAISE EXCEPTION 'bad_session'; END IF;
  BEGIN PERFORM public._rate_limit('chal:' || public._client_ip(), 30, 3600); EXCEPTION WHEN others THEN RAISE EXCEPTION 'rate_limited'; END;
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
  IF l.phase <> 'finished' THEN RAISE EXCEPTION 'challenge_not_finished'; END IF;
  IF l.game_mode NOT IN ('buzzer', 'year', 'letters') THEN RAISE EXCEPTION 'challenge_bad_mode'; END IF;
  SELECT name, user_id INTO v_name, v_user FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND NOT coalesce(is_bot, false);
  IF v_name IS NULL THEN RAISE EXCEPTION 'challenge_no_player'; END IF;
  SELECT count(*), coalesce(round(avg(bot_skill))::int, 2) INTO v_bots, v_skill FROM public.players WHERE lobby_id = p_lobby_id AND coalesce(is_bot, false) AND status = 'active';
  LOOP
    v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    BEGIN
      INSERT INTO public.challenges (code, user_id, creator_name, mode, score, series_total, round_speed, round_seconds, topic_filter, letters_cfg, bots, bot_skill)
      VALUES (v_code, v_user, v_name, l.game_mode, public._challenge_score(p_lobby_id, p_player_id), coalesce(l.series_total, 1), coalesce(l.round_speed, 'normal'),
              coalesce(l.round_seconds, 20), coalesce(l.topic_filter, '{}'),
              CASE WHEN l.game_mode = 'letters' THEN (coalesce(l.letters_cfg, '{}'::jsonb) - 'custom') END,
              greatest(1, least(5, v_bots)), greatest(1, least(3, v_skill)));
      RETURN v_code;
    EXCEPTION WHEN unique_violation THEN
      v_try := v_try + 1;
      IF v_try > 5 THEN RAISE EXCEPTION 'challenge_code_failed'; END IF;
    END;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.get_challenge(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE c public.challenges%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.challenges WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'code', c.code, 'creator', c.creator_name, 'mode', c.mode, 'score', c.score, 'seriesTotal', c.series_total, 'speed', c.round_speed,
    'roundSeconds', c.round_seconds, 'topicFilter', to_jsonb(c.topic_filter), 'lettersCfg', c.letters_cfg, 'bots', c.bots, 'skill', c.bot_skill,
    'expired', c.expires_at < now(),
    'results', coalesce((SELECT jsonb_agg(jsonb_build_object('name', r.name, 'score', r.score, 'at', r.played_at) ORDER BY r.score DESC, r.played_at)
                           FROM (SELECT * FROM public.challenge_results WHERE code = c.code ORDER BY score DESC, played_at LIMIT 10) r), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.rpc_challenge_attach(p_code text, p_lobby_id uuid, p_player_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE c public.challenges%ROWTYPE;
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_player_id) THEN RAISE EXCEPTION 'bad_session'; END IF;
  SELECT * INTO c FROM public.challenges WHERE code = upper(trim(p_code)) AND expires_at > now();
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_not_found'; END IF;
  UPDATE public.lobbies SET challenge_code = c.code
   WHERE id = p_lobby_id AND host_player_id = p_player_id AND challenge_code IS NULL AND game_mode = c.mode;
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_attach_failed'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_challenge_submit(p_lobby_id uuid, p_player_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l public.lobbies%ROWTYPE; c public.challenges%ROWTYPE; v_name text; v_user uuid; v_score int; v_rank int;
BEGIN
  IF NOT public._verify_session(p_lobby_id, p_player_id) THEN RAISE EXCEPTION 'bad_session'; END IF;
  SELECT * INTO l FROM public.lobbies WHERE id = p_lobby_id;
  IF NOT FOUND OR l.challenge_code IS NULL OR l.phase <> 'finished' THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.challenges WHERE code = l.challenge_code;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT name, user_id INTO v_name, v_user FROM public.players WHERE lobby_id = p_lobby_id AND player_id = p_player_id AND NOT coalesce(is_bot, false);
  IF v_name IS NULL THEN RETURN NULL; END IF;
  v_score := public._challenge_score(p_lobby_id, p_player_id);
  INSERT INTO public.challenge_results (lobby_id, code, user_id, name, score) VALUES (p_lobby_id, c.code, v_user, v_name, v_score) ON CONFLICT (lobby_id) DO NOTHING;
  SELECT score INTO v_score FROM public.challenge_results WHERE lobby_id = p_lobby_id;
  SELECT 1 + count(*) INTO v_rank FROM public.challenge_results WHERE code = c.code AND score > v_score;
  RETURN jsonb_build_object('code', c.code, 'creator', c.creator_name, 'target', c.score, 'score', v_score, 'won', v_score > c.score, 'tie', v_score = c.score, 'rank', v_rank);
END $$;

REVOKE ALL ON FUNCTION public.rpc_challenge_create(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_challenge(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_challenge_attach(text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_challenge_submit(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_challenge_create(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_challenge(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_challenge_attach(text, uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_challenge_submit(uuid, uuid) TO anon, authenticated;

COMMIT;
