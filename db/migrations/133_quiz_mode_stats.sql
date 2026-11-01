-- ============================================================
-- 133: Modus-Statistik für Buzzer und Jahr raten (Wunsch Mehdi, 2026-11-01)
-- ============================================================
-- Wie beim Roulette (130): je beendetem Spiel und angemeldetem Menschen eine Zeile (Platz, Punkte, Treffer), gewertet nur mit
-- mindestens 2 Menschen. get_my_mode_stats() liefert die eigene Auswertung (Profil > Statistik).
--   Buzzer:     hits = richtige Antworten, answers = alle Antworten
--   Jahr raten: hits = Volltreffer (5 Punkte),  answers = alle Tipps
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.quiz_mode_matches (
  user_id uuid NOT NULL,
  lobby_id uuid NOT NULL,
  run_key timestamptz NOT NULL,
  mode text NOT NULL,
  place int NOT NULL,
  total int NOT NULL,
  humans int NOT NULL,
  ranked boolean NOT NULL,
  hits int NOT NULL,
  answers int NOT NULL,
  played_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, lobby_id, run_key)
);
ALTER TABLE public.quiz_mode_matches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quiz_mode_matches FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._quiz_record_match(p_lobby_id uuid, p_mode text, p_run timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_humans int;
BEGIN
  IF p_run IS NULL THEN RETURN; END IF;
  v_humans := public._lobby_human_count(p_lobby_id);
  INSERT INTO public.quiz_mode_matches (user_id, lobby_id, run_key, mode, place, total, humans, ranked, hits, answers)
  SELECT p.user_id, p_lobby_id, p_run, p_mode,
         coalesce((SELECT sr.place FROM public.series_results sr WHERE sr.lobby_id = p_lobby_id AND sr.player_id = p.player_id ORDER BY sr.set_index DESC LIMIT 1), 99),
         round(coalesce(p.song_points, 0))::int, v_humans, v_humans >= 2,
         (SELECT count(*) FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.player_id = p.player_id AND (CASE WHEN p_mode = 'year' THEN a.points >= 5 ELSE a.correct END))::int,
         (SELECT count(*) FROM public.quiz_answers a WHERE a.lobby_id = p_lobby_id AND a.player_id = p.player_id)::int
    FROM public.players p
   WHERE p.lobby_id = p_lobby_id AND p.status = 'active' AND p.user_id IS NOT NULL AND NOT coalesce(p.is_bot, false)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public._quiz_finish(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_top uuid; v_mode text; v_run timestamptz;
BEGIN
  SELECT game_mode, run_started_at INTO v_mode, v_run FROM public.lobbies WHERE id = p_lobby_id;
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
  -- 133: Buzzer / Jahr raten – Spiel für die Modus-Statistik im Profil festhalten
  IF v_mode IN ('buzzer', 'year') THEN PERFORM public._quiz_record_match(p_lobby_id, v_mode, v_run); END IF;
  UPDATE public.lobbies SET holder_player_id = v_top WHERE id = p_lobby_id;
END $function$;

CREATE OR REPLACE FUNCTION public.get_my_mode_stats() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_logged_in'; END IF;
  RETURN coalesce((SELECT jsonb_object_agg(x.mode, x.j) FROM (
    SELECT m.mode, jsonb_build_object(
             'matches', count(*) FILTER (WHERE m.ranked),
             'wins', count(*) FILTER (WHERE m.ranked AND m.place = 1),
             'practice', count(*) FILTER (WHERE NOT m.ranked),
             'hits', coalesce(sum(m.hits), 0),
             'answers', coalesce(sum(m.answers), 0),
             'bestTotal', coalesce(max(m.total), 0),
             'avgPlace', round(avg(m.place) FILTER (WHERE m.ranked)::numeric, 1)) AS j
      FROM public.quiz_mode_matches m WHERE m.user_id = v_uid GROUP BY m.mode
  ) x), '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public._quiz_record_match(uuid, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_mode_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_mode_stats() TO authenticated;

COMMIT;
