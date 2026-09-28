-- ============================================================
-- Migration 023: Session-Token gegen Identitäts-Spoofing
-- ============================================================
-- Die Cheat-Probe (apps/web/scripts/probe-cheats.mjs) hat 5 Exploits
-- nachgewiesen, alle mit derselben Wurzel: players.player_id ist für
-- jeden in der Lobby lesbar (nötig fürs UI), und JEDE RPC hat der
-- mitgeschickten ID blind vertraut. Damit konnte ein einzelner Client:
--   - den Ready-Status fremder Spieler umschalten
--   - im Namen anderer beim Topic abstimmen
--   - im Namen des Halters eine Antwort einreichen
--   - als ALLE Mitspieler gleichzeitig abstimmen (Vote-Stuffing)
--     -> Mehrheit im Alleingang erzwingen, das Kernstück der
--        Topic-Mechanik B komplett ausgehebelt
--
-- Lösung: pro Spieler ein geheimes Session-Token.
--   - Der Client erzeugt es einmal (crypto.randomUUID) und legt es
--     lokal ab; beim Join/Create wird es an die eigene Spieler-Zeile
--     gebunden.
--   - Es wird bei JEDEM Supabase-Request als Header
--     "x-kumpir-session" mitgeschickt (siehe supabaseClient.ts).
--   - Die Spalte ist per Column-Grant für anon/authenticated NICHT
--     lesbar -- Mitspieler sehen weiterhin alle anderen Felder, aber
--     niemals fremde Tokens.
--
-- Bewusst über Header statt zusätzlichem Funktionsparameter: so
-- bleibt JEDE Signatur unverändert, es muss nichts gedroppt werden.
-- Genau ein DROP hat in Migration 019 einen nicht dokumentierten
-- Legacy-Trigger zerschossen (kick_player, siehe Migration 022) --
-- dieses Risiko wird hier gar nicht erst eingegangen.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Spalte + Sichtbarkeit
-- ------------------------------------------------------------
ALTER TABLE public.players
    ADD COLUMN IF NOT EXISTS session_token UUID;

-- anon/authenticated dürfen alles sehen AUSSER session_token.
REVOKE SELECT ON public.players FROM anon, authenticated;
GRANT SELECT (
    id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id,
    seat_index, is_alive, kicked_at, is_online, status, left_at, last_pass_at,
    survival_streak, pass_count, clutch_pass_count, fastest_pass_ms,
    total_hold_ms, is_bot
) ON public.players TO anon, authenticated;


-- ------------------------------------------------------------
-- Helfer: Session prüfen
-- ------------------------------------------------------------
-- Gibt TRUE zurück, wenn der Aufrufer wirklich dieser Spieler ist.
-- Sonderfälle:
--   - Kein request.headers-Kontext (interner Aufruf aus Trigger,
--     psql, cron): erlaubt -- hier gibt es keinen Client, dem man
--     misstrauen müsste.
--   - Bots: haben keinen eigenen Browser. Die Bot-Engine läuft im
--     Host-Client (useBotEngine.ts), daher darf der Host mit seinem
--     Token stellvertretend für is_bot-Spieler handeln.
--   - Zeilen ohne Token (Altbestand vor dieser Migration): erlaubt,
--     damit laufende Partien beim Deploy nicht hart brechen. Neue
--     Joins setzen immer ein Token.
CREATE OR REPLACE FUNCTION public._verify_session(p_lobby_id UUID, p_player_id UUID)
 RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_headers text;
  v_token uuid;
  v_stored uuid;
  v_is_bot boolean;
  v_host uuid;
begin
  v_headers := current_setting('request.headers', true);
  if v_headers is null or v_headers = '' then
    return true;  -- interner Aufruf, kein Client im Spiel
  end if;

  begin
    v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
  exception when others then
    v_token := null;
  end;

  select session_token, coalesce(is_bot, false)
    into v_stored, v_is_bot
  from public.players
  where lobby_id = p_lobby_id and player_id = p_player_id;

  if not found then return false; end if;

  -- Altbestand ohne Token: nicht aussperren.
  if v_stored is null then return true; end if;

  if v_token is not null and v_token = v_stored then return true; end if;

  -- Host handelt stellvertretend für Bots.
  if v_is_bot then
    select host_player_id into v_host from public.lobbies where id = p_lobby_id;
    if v_host is not null and v_token is not null and exists (
      select 1 from public.players
      where lobby_id = p_lobby_id and player_id = v_host and session_token = v_token
    ) then
      return true;
    end if;
  end if;

  return false;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public._verify_session(uuid, uuid) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Token beim Beitreten binden
-- ------------------------------------------------------------
-- Wichtig: ein bereits gesetztes Token darf NICHT von einem fremden
-- Client überschrieben werden -- sonst könnte man einen Sitzplatz per
-- rpc_join_lobby mit bekannter player_id einfach übernehmen.
CREATE OR REPLACE FUNCTION public.rpc_join_lobby(
    p_code TEXT,
    p_player_id UUID,
    p_name TEXT,
    p_user_id UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
begin
  select id, locked, max_players into v_lobby_id, v_locked, v_max_players
  from public.lobbies where upper(code) = upper(p_code) limit 1;

  if v_lobby_id is null then raise exception 'lobby_not_found'; end if;
  if v_locked then raise exception 'lobby_locked'; end if;

  v_headers := current_setting('request.headers', true);
  if v_headers is not null and v_headers <> '' then
    begin
      v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
    exception when others then
      v_token := null;
    end;
  end if;

  -- Fremdübernahme eines belegten Platzes verhindern
  select session_token into v_existing
  from public.players where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_existing is not null and v_token is distinct from v_existing then
    raise exception 'identity_taken';
  end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  if v_active_count >= v_max_players then raise exception 'lobby_full'; end if;

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


-- Host bekommt sein Token direkt beim Erstellen gebunden.
CREATE OR REPLACE FUNCTION public.rpc_create_lobby(
    p_host_name TEXT,
    p_privacy TEXT,
    p_max_players INTEGER,
    p_round_seconds INTEGER,
    p_user_id UUID DEFAULT NULL,
    p_round_speed TEXT DEFAULT 'normal'
) RETURNS TABLE(code TEXT, host_player_id UUID)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid := gen_random_uuid();
  v_code text;
  v_host_player_id uuid := gen_random_uuid();
  v_round_speed text := btrim(coalesce(p_round_speed, 'normal'));
  v_privacy text := btrim(coalesce(p_privacy, 'private'));
  v_headers text;
  v_token uuid;
begin
  if v_round_speed not in ('fast', 'normal', 'calm') then
    v_round_speed := 'normal';
  end if;
  if v_privacy not in ('private', 'public') then
    v_privacy := 'private';
  end if;

  v_headers := current_setting('request.headers', true);
  if v_headers is not null and v_headers <> '' then
    begin
      v_token := nullif(v_headers::json ->> 'x-kumpir-session', '')::uuid;
    exception when others then
      v_token := null;
    end;
  end if;

  v_code := public.generate_lobby_code(4);

  insert into public.lobbies (
    id, code, host_player_id, status, privacy, max_players, round_seconds, round_speed,
    created_at, last_activity_at, host_user_id
  ) values (
    v_lobby_id, upper(v_code), v_host_player_id, 'waiting', v_privacy,
    greatest(2, least(p_max_players, 12)),
    coalesce(p_round_seconds, 25),
    v_round_speed,
    now(), now(), p_user_id
  );

  insert into public.players (id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id, session_token)
  values (gen_random_uuid(), v_lobby_id, v_host_player_id, left(trim(p_host_name), 24), false, now(), now(), p_user_id, v_token);

  return query select upper(v_code), v_host_player_id;
end;
$function$;


-- Bots erben das Token des Hosts NICHT -- _verify_session erlaubt dem
-- Host stellvertretendes Handeln über die is_bot-Sonderregel.


-- ------------------------------------------------------------
-- Geschützte Spiel-Aktionen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_toggle_ready(p_lobby_id uuid, p_player_id uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_new boolean;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  update public.players
  set ready = not coalesce(ready,false), last_seen_at = now()
  where lobby_id = p_lobby_id and player_id = p_player_id
  returning ready into v_new;

  if v_new is null then raise exception 'Player not found in lobby'; end if;

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
  return v_new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_vote_topic(p_lobby_id uuid, p_player_id uuid, p_choice integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if p_choice not in (1,2,3) then raise exception 'Invalid choice %', p_choice; end if;

  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  insert into public.topic_votes (lobby_id, player_id, choice)
  values (p_lobby_id, p_player_id, p_choice)
  on conflict (lobby_id, player_id)
  do update set choice = excluded.choice;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, coalesce(v_lobby.topic_selected, v_lobby.topic, ''))
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;
  return v_attempt;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_vote_answer(
    p_attempt_id UUID, p_voter_id UUID, p_accept BOOLEAN
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_attempt public.pass_attempts%ROWTYPE;
  v_alive int; v_needed int;
begin
  select * into v_attempt from public.pass_attempts where id = p_attempt_id for update;
  if not found then raise exception 'attempt_not_found'; end if;

  if not public._verify_session(v_attempt.lobby_id, p_voter_id) then
    raise exception 'invalid_session';
  end if;

  if v_attempt.status <> 'pending' then raise exception 'attempt_closed'; end if;
  if v_attempt.holder_player_id = p_voter_id then raise exception 'holder_cannot_vote'; end if;

  insert into public.pass_attempt_votes (attempt_id, voter_id, accept)
    values (p_attempt_id, p_voter_id, p_accept)
    on conflict (attempt_id, voter_id) do nothing;

  update public.pass_attempts
  set accept_count = (select count(*) from public.pass_attempt_votes where attempt_id = p_attempt_id and accept = true),
      reject_count = (select count(*) from public.pass_attempt_votes where attempt_id = p_attempt_id and accept = false)
  where id = p_attempt_id
  returning * into v_attempt;

  select count(*) into v_alive
  from public.players
  where lobby_id = v_attempt.lobby_id and status = 'active' and is_alive = true
    and player_id <> v_attempt.holder_player_id;

  v_needed := (v_alive / 2) + 1;

  if v_attempt.accept_count >= v_needed then
    perform public._finalize_attempt_accept(v_attempt.id);
  elsif v_attempt.reject_count >= v_needed then
    perform public._finalize_attempt_reject(v_attempt.id);
  end if;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_leave_lobby(p_lobby_id UUID, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
