-- ============================================================
-- 123: Zurück ins laufende Spiel (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- Wer ein Match verlassen hat (Hauptmenü-Knopf im Spiel, Verbindung weg), kommt über den Code/Einladung wieder rein,
-- auch wenn die Lobby wegen des laufenden Matches gesperrt ist. Neue Spieler bleiben draußen, Rausgeworfene auch.
-- Er schaut dann zu, bis die nächste Runde beginnt (is_alive bleibt false); in den Quiz-Modi spielt er sofort mit.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_join_lobby(p_code text, p_player_id uuid, p_name text, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_locked boolean;
  v_max_players int;
  v_active_count int;
  v_next_seat int;
  v_headers text;
  v_token uuid;
  v_existing uuid;
  v_own boolean;
  v_account_name text;
begin
  -- (107) Mit Konto steht der Name fest: Anzeigename, sonst Benutzername (ändern nur in den Einstellungen)
  if auth.uid() is not null then
    select coalesce(nullif(btrim(display_name), ''), username) into v_account_name from public.profiles where id = auth.uid();
  end if;
  select id, locked, max_players into v_lobby_id, v_locked, v_max_players
  from public.lobbies where upper(code) = upper(p_code) limit 1;

  if v_lobby_id is null then raise exception 'lobby_not_found'; end if;
  -- 123: Wer schon mal dabei war (verlassen, Verbindung weg), darf auch in ein laufendes Match zurück – nur Neue nicht; Rausgeworfene (kicked_at) auch nicht
  if v_locked and not exists (select 1 from public.players where lobby_id = v_lobby_id and kicked_at is null and (player_id = p_player_id or (p_user_id is not null and user_id = p_user_id))) then
    raise exception 'lobby_locked';
  end if;
  if p_user_id is not null and p_user_id is distinct from auth.uid() then raise exception 'user_mismatch'; end if;
  perform public._rate_limit('join:' || public._client_ip(), 120, 600);

  v_headers := current_setting('request.headers', true);
  if v_headers is not null and v_headers <> '' then
    begin
      v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
    exception when others then
      v_token := null;
    end;
  end if;

  -- Fremdübernahme eines belegten Platzes verhindern (der eigene Platz eines angemeldeten Kontos ist erlaubt)
  select session_token, (auth.uid() is not null and user_id = auth.uid()) into v_existing, v_own
  from public.players where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_existing is null and exists (select 1 from public.players where lobby_id = v_lobby_id and player_id = p_player_id and user_id is not null and user_id is distinct from auth.uid()) then
    raise exception 'identity_taken';
  end if;
  if v_existing is not null and v_token is distinct from v_existing and not coalesce(v_own, false) then
    raise exception 'identity_taken';
  end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  if v_active_count >= v_max_players
     and not exists (select 1 from public.players where lobby_id = v_lobby_id and status = 'active'
                     and (player_id = p_player_id or (p_user_id is not null and user_id = p_user_id))) then
    raise exception 'lobby_full';
  end if;

  if p_user_id is not null then
    update public.players
    set name = left(trim(coalesce(v_account_name, p_name)), 24),
        status = 'active',
        left_at = null,
        kicked_at = null,
        last_seen_at = now(),
        session_token = coalesce(v_token, session_token)
    where lobby_id = v_lobby_id and user_id = p_user_id;

    if found then return; end if;
  end if;

  select coalesce(min(s.i), 0) into v_next_seat
  from generate_series(0, v_max_players - 1) as s(i)
  left join public.players p
    on p.lobby_id = v_lobby_id and p.seat_index = s.i and p.status = 'active'
  where p.id is null;

  insert into public.players (lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at, user_id, session_token)
  values (v_lobby_id, p_player_id, left(trim(coalesce(v_account_name, p_name)), 24), 'active', v_next_seat, now(), now(), p_user_id, v_token)
  on conflict (lobby_id, player_id) do update set
    name = excluded.name,
    status = 'active',
    left_at = null,
    kicked_at = null,
    last_seen_at = now(),
    seat_index = coalesce(public.players.seat_index, excluded.seat_index),
    user_id = coalesce(public.players.user_id, excluded.user_id),
    session_token = coalesce(public.players.session_token, excluded.session_token);
end;
$function$
;

COMMIT;
