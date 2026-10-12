-- ============================================================
-- 104: Öffentliche Lobbys, Wiederbeitreten, klarere Freundschafts-Fehler (Wunsch Mehdi, 2026-10-12)
-- ============================================================
-- * lobbies.privacy wird jetzt genutzt: 'public' = im Hauptmenü unter "Offene Lobbys" sichtbar.
--   set_lobby_privacy (nur Host) schaltet um, get_public_lobbies liefert die Liste (auch für Gäste).
-- * rpc_join_lobby: wer angemeldet ist und schon einen (verlassenen) Platz in der Lobby hat, darf ihn
--   auch von einem anderen Gerät/Browser zurückholen (vorher 'identity_taken').
-- * rpc_send_friend_request: 'already_friends' / 'already_requested'; hat der andere mich schon
--   angefragt, sind wir direkt befreundet.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.set_lobby_privacy(p_lobby_id uuid, p_me_player_id uuid, p_privacy text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;
  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;
  if p_privacy not in ('public', 'private') then raise exception 'invalid_privacy'; end if;
  update public.lobbies set privacy = p_privacy, last_activity_at = now() where id = p_lobby_id;
end;
$function$;

-- Offene Lobbys: öffentlich, nicht gesperrt, noch nicht gestartet, nicht voll, mindestens ein echter Mensch da
CREATE OR REPLACE FUNCTION public.get_public_lobbies()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'humans')::int DESC, x ->> 'createdAt' DESC), '[]'::jsonb)
  FROM (
    SELECT jsonb_build_object(
             'code', l.code,
             'hostName', h.name,
             'hostAvatar', h.avatar_config,
             'players', c.n,
             'humans', c.humans,
             'maxPlayers', l.max_players,
             'speed', l.round_speed,
             'createdAt', l.created_at
           ) AS x
    FROM public.lobbies l
    JOIN LATERAL (
      SELECT count(*) FILTER (WHERE p.status = 'active') AS n,
             count(*) FILTER (WHERE p.status = 'active' AND NOT coalesce(p.is_bot, false)
                                AND p.last_seen_at > now() - interval '2 minutes') AS humans
      FROM public.players p WHERE p.lobby_id = l.id
    ) c ON true
    LEFT JOIN public.players h ON h.lobby_id = l.id AND h.player_id = l.host_player_id
    WHERE l.privacy = 'public'
      AND NOT coalesce(l.locked, false)
      AND l.phase IN ('waiting', 'lobby')
      AND l.created_at > now() - interval '12 hours'
      AND c.humans > 0
      AND c.n < l.max_players
    LIMIT 20
  ) s;
$function$;

GRANT EXECUTE ON FUNCTION public.set_lobby_privacy(uuid, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_lobbies() TO anon, authenticated;

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
begin
  select id, locked, max_players into v_lobby_id, v_locked, v_max_players
  from public.lobbies where upper(code) = upper(p_code) limit 1;

  if v_lobby_id is null then raise exception 'lobby_not_found'; end if;
  if v_locked then raise exception 'lobby_locked'; end if;
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
    set name = left(trim(p_name), 24),
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
  values (v_lobby_id, p_player_id, left(trim(p_name), 24), 'active', v_next_seat, now(), now(), p_user_id, v_token)
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
$function$;

CREATE OR REPLACE FUNCTION public.rpc_send_friend_request(p_from_user_id uuid, p_to_username text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_to_id uuid;
  v_mine text;
  v_theirs text;
BEGIN
    IF auth.uid() IS NULL OR p_from_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    PERFORM public._rate_limit('friendreq:' || auth.uid()::text, 30, 3600);

    SELECT id INTO v_to_id FROM public.profiles
    WHERE LOWER(username) = LOWER(TRIM(p_to_username)) LIMIT 1;

    IF v_to_id IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
    IF v_to_id = p_from_user_id THEN RAISE EXCEPTION 'cannot_befriend_self'; END IF;

    SELECT status INTO v_mine FROM public.friendships WHERE user_id = p_from_user_id AND friend_user_id = v_to_id;
    SELECT status INTO v_theirs FROM public.friendships WHERE user_id = v_to_id AND friend_user_id = p_from_user_id;

    IF v_mine = 'accepted' THEN RAISE EXCEPTION 'already_friends'; END IF;
    IF v_mine = 'pending' THEN RAISE EXCEPTION 'already_requested'; END IF;

    -- Der andere hat mich schon angefragt: direkt befreundet
    IF v_theirs = 'pending' THEN
      UPDATE public.friendships SET status = 'accepted', accepted_at = now()
       WHERE user_id = v_to_id AND friend_user_id = p_from_user_id;
      INSERT INTO public.friendships (user_id, friend_user_id, status, accepted_at)
      VALUES (p_from_user_id, v_to_id, 'accepted', now())
      ON CONFLICT (user_id, friend_user_id) DO UPDATE SET status = 'accepted', accepted_at = now();
      RETURN;
    END IF;

    INSERT INTO public.friendships (user_id, friend_user_id, status)
    VALUES (p_from_user_id, v_to_id, 'pending')
    ON CONFLICT (user_id, friend_user_id) DO NOTHING;
END;
$function$;

COMMIT;
