-- Migration 074: Host-Rolle darf nicht an einen Bot übertragen werden (niemand könnte die Lobby steuern).
CREATE OR REPLACE FUNCTION public.transfer_host(p_lobby_id uuid, p_me_player_id uuid, p_new_host_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_ok boolean;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select l.host_player_id into v_host from public.lobbies l where l.id = p_lobby_id;
  if v_host is null or v_host <> p_me_player_id then raise exception 'not_host'; end if;

  select exists (
    select 1 from public.players p
    where p.lobby_id = p_lobby_id and p.player_id = p_new_host_player_id and p.status = 'active'
      and not coalesce(p.is_bot, false)
  ) into v_ok;

  if not v_ok then raise exception 'new_host_not_active'; end if;

  update public.lobbies set host_player_id = p_new_host_player_id where id = p_lobby_id;
end;
$function$;
