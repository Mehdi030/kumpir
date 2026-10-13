-- ============================================================
-- 114: Teleport und Reverse entfernt, Standard 6 Spieler (Wunsch Mehdi 2026-10-13)
-- ============================================================
-- Die Modi waren nie spielbar ("BALD"). set_lobby_mode nimmt sie nicht mehr an; alte Lobbys mit diesen
-- Modi (gibt es keine) würden auf "original" gesetzt. Neue Lobbys: max. 6 Spieler als Standard.
BEGIN;

UPDATE public.lobbies SET game_mode = 'original' WHERE game_mode IN ('teleport', 'reverse');
ALTER TABLE public.lobbies ALTER COLUMN max_players SET DEFAULT 6;

CREATE OR REPLACE FUNCTION public.set_lobby_mode(p_lobby_id uuid, p_me_player_id uuid, p_mode text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
  if v_mode not in ('original','teams','pick','buzzer','snippet','artist','year','gap','duel') then raise exception 'invalid_mode'; end if;
  update public.lobbies
  set game_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

COMMIT;
