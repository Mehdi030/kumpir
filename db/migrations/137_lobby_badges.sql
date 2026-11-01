-- ============================================================
-- 137: Erfolgs-Abzeichen neben den Namen in der Lobby (Wunsch Mehdi, 2026-11-02)
-- ============================================================
-- get_lobby_badges(p_lobby_id): je angemeldetem Spieler der Lobby der höchste freigeschaltete Erfolg (Gold vor Silber vor Bronze,
-- bei Gleichstand der neueste) plus Gesamtzahl. Nur Symbol, Titel und Anzahl – keine Konto-Daten.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.get_lobby_badges(p_lobby_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('player_id', t.player_id, 'icon', t.icon, 'title', t.title, 'tier', t.tier, 'n', t.n)), '[]'::jsonb)
    FROM (
      SELECT DISTINCT ON (p.player_id) p.player_id, a.icon, a.title, a.tier,
             count(*) OVER (PARTITION BY p.player_id) AS n
        FROM public.players p
        JOIN public.player_achievements pa ON pa.user_id = p.user_id
        JOIN public.achievements a ON a.code = pa.achievement_code
       WHERE p.lobby_id = p_lobby_id AND p.status = 'active' AND p.user_id IS NOT NULL AND NOT coalesce(p.is_bot, false)
       ORDER BY p.player_id,
                CASE a.tier WHEN 'gold' THEN 3 WHEN 'silver' THEN 2 ELSE 1 END DESC,
                pa.unlocked_at DESC
    ) t;
$$;

REVOKE ALL ON FUNCTION public.get_lobby_badges(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_lobby_badges(uuid) TO anon, authenticated;

COMMIT;
