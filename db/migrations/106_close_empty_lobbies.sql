-- ============================================================
-- 106: Leere Lobbys schließen sich sofort (Wunsch Mehdi, 2026-10-12)
-- ============================================================
-- * rpc_leave_lobby: verlässt der letzte Mensch die Lobby (Bots zählen nicht), wird sie gelöscht.
-- * close_empty_lobbies (pg_cron jede Minute): Lobbys, in denen seit 3 Minuten kein Mensch mehr ein
--   Lebenszeichen geschickt hat (Tab zu, Handy weg), werden ebenfalls gelöscht. 3 Minuten, weil Browser
--   den Herzschlag in Hintergrund-Tabs auf ~1x pro Minute drosseln.
-- Bisher blieben solche Lobbys bis zu 60 Minuten stehen (cleanup_expired_lobbies, bleibt als Netz).
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_leave_lobby(p_lobby_id uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_new_host uuid;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;

  update public.players
  set status = 'left', left_at = now(), ready = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';

  if not found then return; end if;

  -- Letzter Mensch weg: Lobby schließen
  if not exists (select 1 from public.players
                 where lobby_id = p_lobby_id and status = 'active' and not coalesce(is_bot, false)) then
    delete from public.lobbies where id = p_lobby_id;
    return;
  end if;

  if v_host = p_player_id then
    select player_id into v_new_host
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and coalesce(is_bot, false) = false
    order by seat_index asc nulls last, joined_at asc
    limit 1;

    if v_new_host is not null then
      update public.lobbies
      set host_player_id = v_new_host, last_activity_at = now()
      where id = p_lobby_id;
    end if;
  end if;

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.close_empty_lobbies()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  delete from public.lobbies l
  where l.created_at < now() - interval '3 minutes'
    and not exists (
      select 1 from public.players p
      where p.lobby_id = l.id and p.status = 'active' and not coalesce(p.is_bot, false)
        and p.last_seen_at > now() - interval '3 minutes'
    );
end;
$function$;
REVOKE EXECUTE ON FUNCTION public.close_empty_lobbies() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule('kumpir-close-empty-lobbies') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'kumpir-close-empty-lobbies');
SELECT cron.schedule('kumpir-close-empty-lobbies', '* * * * *', 'select public.close_empty_lobbies()');

COMMIT;
