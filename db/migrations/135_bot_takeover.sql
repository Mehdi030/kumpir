-- ============================================================
-- 135: Bot übernimmt, wenn jemand rausfliegt – und gibt zurück (Wunsch Mehdi, 2026-11-02)
-- ============================================================
-- * Wer mitten im Spiel (Phase running/quiz) mehr als 40 s kein Lebenszeichen schickt, oder das Spiel verlässt, wird zum Bot
--   (players.was_human = true, is_bot = true): der Platz spielt weiter (Weitergeben, Antworten, Roulette-Wörter …), wie jeder Bot.
-- * Kommt der Mensch zurück (Heartbeat oder erneutes Beitreten), spielt er sofort wieder selbst (is_bot = false, was_human = false).
-- * Es wird nur umgestellt, wenn noch ein anderer Mensch aktiv ist (sonst wäre die Lobby leer).
-- ============================================================
BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS was_human boolean NOT NULL DEFAULT false;
GRANT SELECT (was_human) ON public.players TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._away_tick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.players p
     SET is_bot = true, was_human = true, bot_skill = coalesce(p.bot_skill, 2), ready = false
    FROM public.lobbies l
   WHERE l.id = p.lobby_id AND l.phase IN ('running', 'quiz')
     AND p.status = 'active' AND NOT coalesce(p.is_bot, false)
     AND (p.last_seen_at IS NULL OR p.last_seen_at < now() - interval '40 seconds')
     AND EXISTS (SELECT 1 FROM public.players q WHERE q.lobby_id = p.lobby_id AND q.player_id <> p.player_id AND q.status = 'active'
                   AND NOT coalesce(q.is_bot, false) AND q.last_seen_at >= now() - interval '40 seconds');
END $$;
REVOKE ALL ON FUNCTION public._away_tick() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.rpc_heartbeat(p_lobby_id uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public._verify_session(p_lobby_id, p_player_id) then return; end if;  -- still ignorieren, kein Fehler im Hintergrund
  update public.players
  set last_seen_at = now(), status = 'active',
      -- 135: war ein Bot für diesen Spieler eingesprungen, übernimmt er wieder selbst
      is_bot = case when was_human then false else is_bot end, was_human = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';
end;
$function$;

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
        is_bot = case when was_human then false else is_bot end, was_human = false,
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
    is_bot = case when public.players.was_human then false else public.players.is_bot end, was_human = false,
    seat_index = coalesce(public.players.seat_index, excluded.seat_index),
    user_id = coalesce(public.players.user_id, excluded.user_id),
    session_token = coalesce(public.players.session_token, excluded.session_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_leave_lobby(p_lobby_id uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_new_host uuid;
  v_phase text;
  v_convert boolean := false;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, phase into v_host, v_phase from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;

  -- 135: mitten im laufenden Spiel übernimmt ein Bot den Platz (wenn noch ein anderer Mensch da ist); kommt man zurück, spielt man selbst weiter
  v_convert := v_phase in ('running', 'quiz')
    and exists (select 1 from public.players where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active' and not coalesce(is_bot, false))
    and exists (select 1 from public.players where lobby_id = p_lobby_id and player_id <> p_player_id and status = 'active' and not coalesce(is_bot, false));
  if v_convert then
    update public.players
    set is_bot = true, was_human = true, bot_skill = coalesce(bot_skill, 2), ready = false
    where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';
  else
    update public.players
    set status = 'left', left_at = now(), ready = false
    where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';
  end if;

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

COMMIT;
