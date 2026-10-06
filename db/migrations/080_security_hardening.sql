-- ============================================================
-- Migration 080: Sicherheits-Härtung (Ergebnis des Angriffs-Tests db/scripts/security-attack.mjs)
-- ============================================================
-- Gefunden und behoben:
--  1. Supabase vergibt per Voreinstellung an JEDE Funktion/Tabelle Rechte für Gäste. Über 60 interne
--     Funktionen waren für jeden aufrufbar (z. B. aggregate_player_stats = Statistik aufblähen,
--     rpc_clear_lobby_to_waiting = fremde Lobbys zurücksetzen). Jetzt: alles gesperrt, nur eine
--     Whitelist der wirklich genutzten Funktionen ist freigegeben; neue Funktionen sind standardmäßig zu.
--  2. IDOR: Freundschaften/gemerkte Lobbys/Beitritt/Lobby-Erstellung nahmen die Nutzer-ID als Parameter
--     (jeder konnte als jemand anderes handeln). Jetzt muss sie der eingeloggten Person gehören.
--  3. _verify_session ließ Spieler ohne Sitzungs-Token durch (jeder konnte sie steuern). Jetzt abgewiesen.
--  4. Tabellen: Schreibrechte für anon/authenticated komplett entzogen (Spiel schreibt nur über RPCs);
--     gemerkte Lobbys/Freundschaften nur noch für Beteiligte lesbar; riskante Alt-Policies entfernt.
--  5. cleanup_lobby(…, 0) konnte alle Spieler rauswerfen -> Mindestzeit; rpc_heartbeat prüft Sitzung.
--  6. Zeit-Schutz: Themenwahl/Countdown/Rematch ließen sich von außen vorzeitig auslösen.
--  7. Missbrauchsbremse: Lobby-Erstellung und Tracking pro IP begrenzt, harte Obergrenzen.
--  8. Admin-Aussperr-Schutz: der letzte aktive Admin kann nie gesperrt/herabgestuft/gelöscht werden.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Hilfen: Client-IP, Rate-Limit, Code-Patch
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rate_limits (
  key          text NOT NULL,
  window_start timestamptz NOT NULL,
  n            integer NOT NULL DEFAULT 0,
  PRIMARY KEY (key, window_start)
);
ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rate_limits FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._client_ip()
 RETURNS text LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select coalesce(
    nullif(h ->> 'cf-connecting-ip', ''),
    nullif(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1), ''),
    nullif(h ->> 'x-real-ip', ''),
    'unknown')
  from (select coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json) as h) x;
$function$;

-- Zählt einen Versuch; wirft 'rate_limited', wenn das Limit im Zeitfenster überschritten ist.
-- Interne Aufrufe (ohne HTTP-Anfrage, z. B. pg_cron) werden nicht begrenzt.
CREATE OR REPLACE FUNCTION public._rate_limit(p_key text, p_max integer, p_seconds integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_w timestamptz := date_bin(make_interval(secs => p_seconds), now(), '2000-01-01'::timestamptz);
  v_n integer;
begin
  if coalesce(current_setting('request.headers', true), '') = '' then return; end if;
  insert into public.rate_limits (key, window_start, n) values (p_key, v_w, 1)
  on conflict (key, window_start) do update set n = public.rate_limits.n + 1
  returning n into v_n;
  if v_n > p_max then raise exception 'rate_limited'; end if;
end;
$function$;

-- Ersetzt GENAU EIN Vorkommen von p_anchor (einzeilig!) in der Funktionsdefinition durch p_replacement
-- und spielt sie neu ein. Bricht ab, wenn der Anker fehlt (Schutz vor stillem Fehlschlag).
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(p_sig regprocedure, p_anchor text, p_replacement text)
 RETURNS void LANGUAGE plpgsql
AS $function$
declare d text; i int;
begin
  d := pg_get_functiondef(p_sig);
  i := position(p_anchor in d);
  if i = 0 then raise exception 'Anker nicht gefunden in %: %', p_sig, p_anchor; end if;
  d := substr(d, 1, i - 1) || p_replacement || substr(d, i + length(p_anchor));
  execute d;
end;
$function$;

-- ------------------------------------------------------------
-- 1) Funktionen: alles zu, dann Whitelist
-- ------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

DO $$
declare
  f record;
  -- Spiel-Funktionen: Gäste UND eingeloggte (Sitzungs-Token bzw. Zeit-Prüfung steckt in den Funktionen)
  guest_ok text[] := array[
    'cleanup_lobby', 'get_song_playlists', 'is_username_available', 'kick_player', 'log_event',
    'rpc_add_bot', 'rpc_advance_from_countdown', 'rpc_attempt_pass', 'rpc_begin_topic_vote', 'rpc_create_lobby',
    'rpc_finalize_topic_vote', 'rpc_heartbeat', 'rpc_host_kick_during_round', 'rpc_join_lobby', 'rpc_leave_lobby',
    'rpc_maybe_shorten_topic_vote', 'rpc_rematch', 'rpc_remove_bot', 'rpc_reset_lobby', 'rpc_resolve_stale_attempt',
    'rpc_revenge_flip', 'rpc_server_time', 'rpc_skip_song', 'rpc_start_next_set', 'rpc_start_rematch_if_ready',
    'rpc_tick_game', 'rpc_toggle_ready', 'rpc_vote_topic', 'rpc_vote_answer',
    'set_lobby_answer_mode', 'set_lobby_lock', 'set_lobby_mode', 'set_lobby_series', 'set_lobby_song_answer_mode',
    'set_lobby_topic', 'set_lobby_topic_filter', 'set_max_players', 'transfer_host'
  ];
  -- Konto-Funktionen: nur eingeloggte
  auth_ok text[] := array[
    'admin_whoami', 'admin_list_users', 'admin_get_user', 'admin_set_user_status', 'admin_delete_user', 'admin_set_role',
    'admin_update_user_profile', 'admin_log_password_reset', 'admin_list_lobbies', 'admin_close_lobby',
    'admin_list_songs', 'admin_set_song_archived', 'admin_list_audit', 'admin_song_stats', 'admin_balance_stats',
    'admin_funnel', 'rpc_get_admin_stats', 'get_my_settings', 'get_my_profile_stats', 'set_my_username',
    'update_my_profile', 'set_my_preferences', 'request_account_deletion',
    'rpc_send_friend_request', 'rpc_accept_friend_request', 'rpc_remove_friend', 'rpc_save_lobby', 'rpc_unsave_lobby'
  ];
begin
  for f in
    select p.oid::regprocedure as sig, p.proname, p.pronargs
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
  loop
    -- Alt-Überladungen bleiben gesperrt (nur die neuen Varianten werden von der App genutzt)
    if f.proname = 'rpc_join_lobby' and f.pronargs <> 4 then continue; end if;
    if f.proname = 'rpc_reset_lobby' and f.pronargs <> 2 then continue; end if;
    if f.proname = ANY (guest_ok) then
      execute format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
    elsif f.proname = ANY (auth_ok) then
      execute format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    end if;
  end loop;
end $$;

-- Künftige Funktionen sind standardmäßig NICHT aufrufbar (neue Migrationen müssen bewusst freigeben)
DO $$
begin
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
exception when others then
  raise notice 'Default-Privileges (postgres): %', sqlerrm;
end $$;
DO $$
begin
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
exception when others then
  raise notice 'Default-Privileges (supabase_admin) übersprungen: %', sqlerrm;
end $$;

-- ------------------------------------------------------------
-- 2) Tabellen: keine Schreibrechte für Clients, Lesen nur wo nötig
-- ------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
-- Spalten-Rechte (falls einzeln vergeben) ebenfalls entfernen
DO $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'v', 'p') loop
    execute format('REVOKE INSERT (%1$s), UPDATE (%1$s) ON public.%2$I FROM anon, authenticated',
      (select string_agg(quote_ident(a.attname), ', ') from pg_attribute a where a.attrelid = ('public.' || quote_ident(t.relname))::regclass and a.attnum > 0 and not a.attisdropped),
      t.relname);
  end loop;
end $$;
-- Nie vom Client genutzt (kein Zugriff, auch nicht lesend)
REVOKE ALL ON public.kv_store_8e1b0e4b, public.staff_roles, public.lobby_admin_logs, public.lobby_admin_sessions FROM anon, authenticated;

-- Riskante Alt-Policies (erlaubten theoretisch Schreiben für jeden) entfernen
DO $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies where schemaname = 'public' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL') loop
    execute format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- Gemerkte Lobbys: nur die eigenen; Freundschaften: nur Beteiligte
DROP POLICY IF EXISTS saved_lobbies_read ON public.saved_lobbies;
DO $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies where schemaname = 'public' and tablename in ('saved_lobbies', 'friendships') and cmd = 'SELECT' loop
    execute format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, p.tablename);
  end loop;
end $$;
DROP POLICY IF EXISTS saved_lobbies_own ON public.saved_lobbies;
CREATE POLICY saved_lobbies_own ON public.saved_lobbies FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS friendships_participants ON public.friendships;
CREATE POLICY friendships_participants ON public.friendships FOR SELECT TO authenticated USING (auth.uid() = user_id OR auth.uid() = friend_user_id);
REVOKE SELECT ON public.saved_lobbies, public.friendships FROM anon;

-- ------------------------------------------------------------
-- 3) IDOR-Fixes: Handeln nur als man selbst
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_send_friend_request(p_from_user_id uuid, p_to_username text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_to_id UUID;
BEGIN
    IF auth.uid() IS NULL OR p_from_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    PERFORM public._rate_limit('friendreq:' || auth.uid()::text, 30, 3600);

    SELECT id INTO v_to_id FROM public.profiles
    WHERE LOWER(username) = LOWER(TRIM(p_to_username)) LIMIT 1;

    IF v_to_id IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
    IF v_to_id = p_from_user_id THEN RAISE EXCEPTION 'cannot_befriend_self'; END IF;

    INSERT INTO public.friendships (user_id, friend_user_id, status)
    VALUES (p_from_user_id, v_to_id, 'pending')
    ON CONFLICT (user_id, friend_user_id) DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_accept_friend_request(p_me_user_id uuid, p_from_user_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_me_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;

    UPDATE public.friendships SET status = 'accepted', accepted_at = NOW()
    WHERE user_id = p_from_user_id AND friend_user_id = p_me_user_id AND status = 'pending';
    IF NOT FOUND THEN RAISE EXCEPTION 'request_not_found'; END IF;

    INSERT INTO public.friendships (user_id, friend_user_id, status, accepted_at)
    VALUES (p_me_user_id, p_from_user_id, 'accepted', NOW())
    ON CONFLICT (user_id, friend_user_id) DO UPDATE SET status = 'accepted', accepted_at = NOW();
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_remove_friend(p_me_user_id uuid, p_friend_user_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_me_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    DELETE FROM public.friendships
    WHERE (user_id = p_me_user_id AND friend_user_id = p_friend_user_id)
       OR (user_id = p_friend_user_id AND friend_user_id = p_me_user_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_save_lobby(p_user_id uuid, p_lobby_code text, p_nickname text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    PERFORM public._rate_limit('savelobby:' || auth.uid()::text, 60, 3600);
    INSERT INTO public.saved_lobbies (user_id, lobby_code, nickname, last_used)
    VALUES (p_user_id, UPPER(LEFT(TRIM(p_lobby_code), 12)), LEFT(TRIM(p_nickname), 40), NOW())
    ON CONFLICT (user_id, lobby_code) DO UPDATE SET nickname = EXCLUDED.nickname, last_used = NOW();
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_unsave_lobby(p_user_id uuid, p_lobby_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'auth_required'; END IF;
    DELETE FROM public.saved_lobbies WHERE user_id = p_user_id AND lobby_code = UPPER(TRIM(p_lobby_code));
END;
$function$;

-- Beitritt: Konto-ID muss die eigene sein; fremde, tokenlose Plätze nicht übernehmbar
SELECT pg_temp.patch_fn(
  'public.rpc_join_lobby(text, uuid, text, uuid)'::regprocedure,
  'if v_locked then raise exception ''lobby_locked''; end if;',
  'if v_locked then raise exception ''lobby_locked''; end if;
  if p_user_id is not null and p_user_id is distinct from auth.uid() then raise exception ''user_mismatch''; end if;
  perform public._rate_limit(''join:'' || public._client_ip(), 120, 600);');
SELECT pg_temp.patch_fn(
  'public.rpc_join_lobby(text, uuid, text, uuid)'::regprocedure,
  'if v_existing is not null and v_token is distinct from v_existing then',
  'if v_existing is null and exists (select 1 from public.players where lobby_id = v_lobby_id and player_id = p_player_id and user_id is not null and user_id is distinct from auth.uid()) then
    raise exception ''identity_taken'';
  end if;
  if v_existing is not null and v_token is distinct from v_existing then');

-- Lobby erstellen: eigene Konto-ID, Rate-Limit pro IP, harte Obergrenze
SELECT pg_temp.patch_fn(
  'public.rpc_create_lobby(text, text, integer, integer, uuid, text)'::regprocedure,
  'v_code := public.generate_lobby_code(4);',
  'if p_user_id is not null and p_user_id is distinct from auth.uid() then raise exception ''user_mismatch''; end if;
  perform public._rate_limit(''createlobby:'' || public._client_ip(), 20, 600);
  if (select count(*) from public.lobbies) >= 1000 then raise exception ''rate_limited''; end if;
  v_code := public.generate_lobby_code(4);');

-- ------------------------------------------------------------
-- 4) Sitzung: kein Durchwinken mehr für Spieler ohne Token
-- ------------------------------------------------------------
SELECT pg_temp.patch_fn(
  'public._verify_session(uuid, uuid)'::regprocedure,
  'if v_stored is null then return true; end if;',
  'if v_stored is null then return false; end if;  -- 080: Plätze ohne Token sind nicht steuerbar');

CREATE OR REPLACE FUNCTION public.rpc_heartbeat(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public._verify_session(p_lobby_id, p_player_id) then return; end if;  -- still ignorieren, kein Fehler im Hintergrund
  update public.players
  set last_seen_at = now(), status = 'active'
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';
end;
$function$;

-- cleanup_lobby: Mindestzeit, damit niemand alle Spieler per "0 Sekunden" rauswerfen kann
SELECT pg_temp.patch_fn(
  'public.cleanup_lobby(uuid, integer)'::regprocedure,
  'declare',
  'declare
  p_stale_seconds_eff integer;');
SELECT pg_temp.patch_fn(
  'public.cleanup_lobby(uuid, integer)'::regprocedure,
  'select host_player_id, phase',
  'p_stale_seconds_eff := greatest(coalesce(p_stale_seconds, 60), 30);
  select host_player_id, phase');
SELECT pg_temp.patch_fn(
  'public.cleanup_lobby(uuid, integer)'::regprocedure,
  'last_seen_at < (now() - make_interval(secs => p_stale_seconds))',
  'last_seen_at < (now() - make_interval(secs => p_stale_seconds_eff))');

-- ------------------------------------------------------------
-- 5) Zeit-Schutz: nur von außen (HTTP) nicht vor Ablauf auslösbar; pg_cron/intern unverändert
-- ------------------------------------------------------------
SELECT pg_temp.patch_fn(
  'public.rpc_finalize_topic_vote(uuid)'::regprocedure,
  'if not found then return; end if;',
  'if not found then return; end if;
  if coalesce(current_setting(''request.headers'', true), '''') <> '''' and exists (select 1 from public.lobbies where id = p_lobby_id and topic_vote_ends_at > now() + interval ''1 second'') then return; end if;');
SELECT pg_temp.patch_fn(
  'public.rpc_advance_from_countdown(uuid)'::regprocedure,
  'if v_phase is distinct from ''countdown'' then return; end if;',
  'if v_phase is distinct from ''countdown'' then return; end if;
  if coalesce(current_setting(''request.headers'', true), '''') <> '''' and exists (select 1 from public.lobbies where id = p_lobby_id and countdown_ends_at > now() + interval ''1 second'') then return; end if;');
SELECT pg_temp.patch_fn(
  'public.rpc_start_rematch_if_ready(text)'::regprocedure,
  'if v_lobby_id is null then raise exception ''Lobby nicht gefunden''; end if;',
  'if v_lobby_id is null then raise exception ''Lobby nicht gefunden''; end if;
  if coalesce(current_setting(''request.headers'', true), '''') <> '''' and exists (select 1 from public.lobbies where id = v_lobby_id and countdown_ends_at > now() + interval ''1 second'') then return; end if;');

-- Tracking: Obergrenze pro IP (verhindert Datenmüll-Flut)
SELECT pg_temp.patch_fn(
  'public.log_event(text, text, jsonb)'::regprocedure,
  'if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;',
  'if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;
  begin perform public._rate_limit(''log:'' || public._client_ip(), 300, 60); exception when others then return; end;');

-- Hygiene: fester search_path für alle SECURITY-DEFINER-Funktionen
DO $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('ALTER FUNCTION %s SET search_path TO ''public''', f.sig);
  end loop;
end $$;

-- Aufräumen der Rate-Limit-Tabelle (stündlich)
DO $$
begin
  if exists (select 1 from cron.job where jobname = 'kumpir-ratelimit-cleanup') then perform cron.unschedule('kumpir-ratelimit-cleanup'); end if;
  perform cron.schedule('kumpir-ratelimit-cleanup', '23 * * * *', $job$delete from public.rate_limits where window_start < now() - interval '2 hours'$job$);
end $$;

-- ------------------------------------------------------------
-- 6) Admin-Aussperr-Schutz
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._protect_last_admin()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if OLD.role = 'admin' and OLD.status = 'active'
     and (TG_OP = 'DELETE' or NEW.role is distinct from 'admin' or NEW.status is distinct from 'active')
     and not exists (select 1 from public.profiles p where p.id <> OLD.id and p.role = 'admin' and p.status = 'active') then
    raise exception 'last_admin_protected';
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end;
$function$;
DROP TRIGGER IF EXISTS profiles_protect_last_admin ON public.profiles;
CREATE TRIGGER profiles_protect_last_admin BEFORE UPDATE OF role, status OR DELETE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public._protect_last_admin();

-- Admin-Konten werden nie per Auth-Sperre blockiert (auch nicht durch Supporter-/Admin-Aktionen anderer)
SELECT pg_temp.patch_fn(
  'public._set_login_blocked(uuid, boolean)'::regprocedure,
  'update auth.users set banned_until',
  'if p_blocked and exists (select 1 from public.profiles where id = p_user_id and role = ''admin'') then
    raise exception ''admin_cannot_be_blocked'';
  end if;
  update auth.users set banned_until');

COMMIT;
