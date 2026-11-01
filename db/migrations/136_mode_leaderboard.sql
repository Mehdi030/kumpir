-- ============================================================
-- 136: Bestenliste je Modus (Wunsch Mehdi, 2026-11-02)
-- ============================================================
-- get_mode_leaderboard(p_mode): die Top 25 angemeldeten Spieler für Buzzer ('buzzer'), Jahr raten ('year') und Roulette ('letters'),
-- gewertet nur aus Spielen mit mindestens 2 Menschen (ranked). Sortiert nach Siegen, dann Gesamtpunkten, dann Spielen.
-- Jeder darf sie lesen (es stehen nur Spielername und Zahlen drin), die Tabellen selbst bleiben gesperrt.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.get_mode_leaderboard(p_mode text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v jsonb;
BEGIN
  IF p_mode NOT IN ('buzzer', 'year', 'letters') THEN RAISE EXCEPTION 'bad_mode'; END IF;
  IF p_mode = 'letters' THEN
    SELECT coalesce(jsonb_agg(r ORDER BY (r->>'wins')::int DESC, (r->>'points')::int DESC, (r->>'matches')::int DESC), '[]'::jsonb) INTO v
      FROM (
        SELECT jsonb_build_object('user_id', m.user_id, 'username', pr.username, 'matches', count(*), 'wins', count(*) FILTER (WHERE m.place = 1),
                                  'points', sum(m.total), 'best', max(m.total), 'hits', NULL::int, 'answers', NULL::int) AS r
          FROM public.roulette_matches m JOIN public.profiles pr ON pr.id = m.user_id
         WHERE m.ranked
         GROUP BY m.user_id, pr.username
         ORDER BY count(*) FILTER (WHERE m.place = 1) DESC, sum(m.total) DESC, count(*) DESC
         LIMIT 25
      ) t;
  ELSE
    SELECT coalesce(jsonb_agg(r ORDER BY (r->>'wins')::int DESC, (r->>'points')::int DESC, (r->>'matches')::int DESC), '[]'::jsonb) INTO v
      FROM (
        SELECT jsonb_build_object('user_id', m.user_id, 'username', pr.username, 'matches', count(*), 'wins', count(*) FILTER (WHERE m.place = 1),
                                  'points', sum(m.total), 'best', max(m.total), 'hits', sum(m.hits), 'answers', sum(m.answers)) AS r
          FROM public.quiz_mode_matches m JOIN public.profiles pr ON pr.id = m.user_id
         WHERE m.ranked AND m.mode = p_mode
         GROUP BY m.user_id, pr.username
         ORDER BY count(*) FILTER (WHERE m.place = 1) DESC, sum(m.total) DESC, count(*) DESC
         LIMIT 25
      ) t;
  END IF;
  RETURN v;
END $$;

REVOKE ALL ON FUNCTION public.get_mode_leaderboard(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_mode_leaderboard(text) TO anon, authenticated;

COMMIT;
