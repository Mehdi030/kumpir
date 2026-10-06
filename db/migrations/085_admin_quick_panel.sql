-- ============================================================
-- 085: Admin-Schnellmenü (Pop-up)
-- ============================================================
--   admin_online_players()  – wer ist gerade verbunden (Mensch, in einer Lobby, Herzschlag < 90 s)
--   admin_kick_player(...)  – Spieler aus der Lobby werfen (Supporter + Admin), mit Protokoll-Eintrag
-- Sperren eines Kontos läuft weiter über admin_set_user_status (Migration 078).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_online_players()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(x order by x."lobbyCode", x.name) from (
      select p.player_id as "playerId", p.name, l.id as "lobbyId", l.code as "lobbyCode", l.phase,
             (l.host_player_id = p.player_id) as "isHost",
             p.user_id as "userId", pr.username, pr.role, pr.status as "accountStatus",
             p.last_seen_at as "lastSeen"
      from public.players p
      join public.lobbies l on l.id = p.lobby_id
      left join public.profiles pr on pr.id = p.user_id
      where p.status = 'active' and not coalesce(p.is_bot, false)
        and p.last_seen_at > now() - interval '90 seconds'
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_kick_player(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  r text := public._require_staff('supporter');
  v_name text; v_code text; v_user uuid; v_alive boolean; v_target_role text; v_username text;
begin
  select p.name, l.code, p.user_id, p.is_alive into v_name, v_code, v_user, v_alive
  from public.players p join public.lobbies l on l.id = p.lobby_id
  where p.lobby_id = p_lobby_id and p.player_id = p_player_id and p.status = 'active';
  if not found then raise exception 'player_not_found'; end if;

  if v_user is not null then
    select role, username into v_target_role, v_username from public.profiles where id = v_user;
    -- Supporter dürfen keine Admins rauswerfen
    if v_target_role = 'admin' and r <> 'admin' then raise exception 'not_authorized'; end if;
  end if;

  update public.players set status = 'kicked', kicked_at = now(), ready = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';

  perform public._on_player_exit(p_lobby_id, p_player_id, coalesce(v_alive, false));

  perform public._audit('player_kicked', v_user, v_name,
    jsonb_build_object('lobby', v_code, 'konto', v_username));
end;
$function$;

REVOKE ALL ON FUNCTION public.admin_online_players() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_online_players() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_kick_player(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_kick_player(uuid, uuid) TO authenticated;

COMMIT;
