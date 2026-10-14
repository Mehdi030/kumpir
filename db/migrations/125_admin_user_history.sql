-- ============================================================
-- 125: Schnellmenü (Alt + A): Verlauf eines Spielers (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- admin_user_history(user): letzte 12 Matches des Kontos (Datum, Lobby, Platz, Punkte, Treffer, falsche Antworten)
-- und die letzten 12 Runden-Playlists. Nur Team (mind. Supporter), wie admin_get_user.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_user_history(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return jsonb_build_object(
    'matches', coalesce((
      select jsonb_agg(m order by m."finishedAt" desc) from (
        select finished_at as "finishedAt", lobby_code as "lobbyCode", place, players_count as "players", humans_count as "humans",
               total_points as "points", title_hits as "titles", artist_hits as "artists", wrong_guesses as "wrong", rounds_total as "rounds", ranked,
               playlists
          from public.account_matches where user_id = p_user_id order by finished_at desc limit 12
      ) m
    ), '[]'::jsonb)
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.admin_user_history(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_user_history(uuid) TO authenticated;

COMMIT;
