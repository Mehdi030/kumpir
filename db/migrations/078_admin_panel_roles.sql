-- ============================================================
-- Migration 078: Admin-Panel, Rollen, Löschanträge, Playlist-Auswahl
-- ============================================================
-- Rollen (profiles.role):  user | supporter | admin
--   supporter: Nutzer ansehen/sperren/entsperren (nur normale Nutzer), Namen/Avatar
--              zurücksetzen, Löschanträge sehen und ablehnen, Lobbys schließen, Protokoll
--   admin:     zusätzlich Konten endgültig löschen, Rollen vergeben, Songs archivieren,
--              Statistik/Auswertung
-- Konto-Status (profiles.status): active | suspended | deletion_requested
--   Löschantrag durch den Spieler: Zugang sofort zu (Auth-Sperre + alle Sitzungen beendet),
--   endgültig gelöscht wird nur durch einen Admin. Bis dahin kann das Team ihn ablehnen.
-- Playlists: Abstimmung nur noch aus Musik-Playlists (vorher konnten bei leerem Filter
--   56 alte Nicht-Musik-Themen gezogen werden -> Runde ohne Song). Leerer Filter = alle.
-- Alle Admin-Aktionen landen im Protokoll (admin_audit).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Spalten
-- ------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'user';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status_reason text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status_changed_at timestamptz;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS status_changed_by uuid;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS deletion_requested_at timestamptz;

DO $$ begin
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check CHECK (role IN ('user', 'supporter', 'admin'));
exception when duplicate_object then null; end $$;
DO $$ begin
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_status_check CHECK (status IN ('active', 'suspended', 'deletion_requested'));
exception when duplicate_object then null; end $$;

UPDATE public.profiles SET role = 'admin' WHERE coalesce(is_platform_admin, false) AND role <> 'admin';

ALTER TABLE public.song_pool ADD COLUMN IF NOT EXISTS archived_from text;

-- Protokoll
CREATE TABLE IF NOT EXISTS public.admin_audit (
  id           bigserial PRIMARY KEY,
  created_at   timestamptz NOT NULL DEFAULT now(),
  actor_id     uuid,
  actor_name   text,
  action       text NOT NULL,
  target_id    uuid,
  target_label text,
  details      jsonb
);
CREATE INDEX IF NOT EXISTS admin_audit_created_idx ON public.admin_audit (created_at DESC);
ALTER TABLE public.admin_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_audit FROM anon, authenticated;

-- ------------------------------------------------------------
-- Rollen-Hilfen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_role()
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select case when p.role in ('admin', 'supporter') and p.status = 'active' then p.role end
  from public.profiles p where p.id = auth.uid();
$function$;

-- p_min = 'supporter' (Supporter oder Admin) | 'admin'
CREATE OR REPLACE FUNCTION public._require_staff(p_min text)
 RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r text := public._staff_role();
begin
  if r is null or (p_min = 'admin' and r <> 'admin') then
    raise exception 'not_authorized';
  end if;
  return r;
end;
$function$;

-- Bestehende Admin-Auswertungen (076) laufen weiter über diese Funktion
CREATE OR REPLACE FUNCTION public._require_platform_admin()
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('admin');
end;
$function$;

CREATE OR REPLACE FUNCTION public._audit(p_action text, p_target uuid, p_label text, p_details jsonb DEFAULT NULL)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  insert into public.admin_audit (actor_id, actor_name, action, target_id, target_label, details)
  values (auth.uid(), (select coalesce(username, email) from public.profiles where id = auth.uid()), p_action, p_target, p_label, p_details);
$function$;

-- Zugang sperren/öffnen (Auth-Ebene). Sperre bis 2999 statt "infinity" (wird von der Auth-API sicher gelesen).
CREATE OR REPLACE FUNCTION public._set_login_blocked(p_user_id uuid, p_blocked boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  update auth.users set banned_until = case when p_blocked then '2999-12-31 00:00:00+00'::timestamptz end where id = p_user_id;
  if p_blocked then
    delete from auth.sessions where user_id = p_user_id;  -- alle Geräte sofort abmelden (Refresh-Tokens fallen mit)
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public._staff_role() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._require_staff(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._audit(text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_login_blocked(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Spieler: Löschung beantragen (ersetzt das sofortige Selbst-Löschen)
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.delete_my_account() FROM authenticated;

CREATE OR REPLACE FUNCTION public.request_account_deletion(p_reason text DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from public.profiles where id = v_uid and role = 'admin') then
    raise exception 'admin_cannot_delete';
  end if;
  update public.profiles
     set status = 'deletion_requested', deletion_requested_at = now(),
         status_reason = nullif(left(trim(coalesce(p_reason, '')), 300), ''),
         status_changed_at = now(), status_changed_by = v_uid
   where id = v_uid;
  perform public._audit('deletion_requested', v_uid, (select coalesce(username, email) from public.profiles where id = v_uid), null);
  perform public._set_login_blocked(v_uid, true);
end;
$function$;
REVOKE ALL ON FUNCTION public.request_account_deletion(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(text) TO authenticated;

-- Eigene Einstellungen liefern zusätzlich Rolle + Status (Client meldet gesperrte Konten ab).
-- VOLATILE (nicht STABLE): legt im Notfall ein fehlendes Profil an – das war in 077 als STABLE markiert.
CREATE OR REPLACE FUNCTION public.get_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  select username, display_name, avatar_emoji, avatar_color, preferences, email, username_changed_at, role, status
    into r from public.profiles where id = v_uid;
  if not found then
    insert into public.profiles (id, username, email, created_at)
    select id, public._unique_username(split_part(email, '@', 1)), email, now() from auth.users where id = v_uid
    on conflict (id) do nothing;
    return jsonb_build_object('username', (select username from public.profiles where id = v_uid), 'displayName', null, 'avatarEmoji', null,
                              'avatarColor', null, 'preferences', '{}'::jsonb, 'role', 'user', 'status', 'active');
  end if;
  return jsonb_build_object(
    'username', r.username,
    'displayName', r.display_name,
    'avatarEmoji', r.avatar_emoji,
    'avatarColor', r.avatar_color,
    'preferences', coalesce(r.preferences, '{}'::jsonb),
    'usernameChangedAt', r.username_changed_at,
    'role', r.role,
    'status', r.status
  );
end;
$function$;

-- ------------------------------------------------------------
-- Playlists: nur Musik-Playlists, leerer Filter = alle
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._vote_topic_pool(p_filter text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(t.text), '{}')
  from public.topic_pool t
  where t.active is true and t.is_song_category is true
    and (p_filter is null or cardinality(p_filter) = 0 or t.text = any(p_filter));
$function$;

CREATE OR REPLACE FUNCTION public.set_lobby_topic_filter(p_lobby_id uuid, p_me_player_id uuid, p_categories text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_clean text[];
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  -- Nur echte, aktive Musik-Playlists übernehmen; nichts ausgewählt = alle (NULL).
  select coalesce(array_agg(distinct tp.text), '{}')
    into v_clean
  from public.topic_pool tp
  where tp.active is true and tp.is_song_category is true and tp.text = any(coalesce(p_categories, '{}'));

  update public.lobbies
  set topic_filter = nullif(v_clean, '{}'),
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

-- Alle Musik-Playlists mit Songanzahl (für die Auswahl in Host/Lobby/Profil)
CREATE OR REPLACE FUNCTION public.get_song_playlists()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('name', t.text, 'songs', t.n) order by t.text), '[]'::jsonb)
  from (
    select tp.text, count(sp.id)::int as n
    from public.topic_pool tp
    left join public.song_pool sp on sp.topic_pool_id = tp.id
    where tp.active is true and tp.is_song_category is true
    group by tp.text
  ) t;
$function$;
GRANT EXECUTE ON FUNCTION public.get_song_playlists() TO anon, authenticated;

-- Vorlieben: zusätzlich host.excludedPlaylists (rausgenommene Playlists; neue Playlists sind automatisch drin)
CREATE OR REPLACE FUNCTION public.set_my_preferences(p_prefs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  p jsonb := coalesce(p_prefs, '{}'::jsonb);
  h jsonb := coalesce(p_prefs -> 'host', '{}'::jsonb);
  s jsonb := coalesce(p_prefs -> 'solo', '{}'::jsonb);
  out jsonb := '{}'::jsonb;
  host_out jsonb := '{}'::jsonb;
  solo_out jsonb := '{}'::jsonb;
  v_ex jsonb;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'prefs_invalid'; end if;

  if p ->> 'lang' in ('de', 'en') then out := out || jsonb_build_object('lang', p ->> 'lang'); end if;
  if jsonb_typeof(p -> 'muted') = 'boolean' then out := out || jsonb_build_object('muted', (p ->> 'muted')::boolean); end if;
  if jsonb_typeof(p -> 'volume') = 'number' and (p ->> 'volume')::numeric between 0 and 1 then
    out := out || jsonb_build_object('volume', round((p ->> 'volume')::numeric, 2));
  end if;

  if jsonb_typeof(h -> 'maxPlayers') = 'number' and (h ->> 'maxPlayers')::numeric between 2 and 12 then
    host_out := host_out || jsonb_build_object('maxPlayers', (h ->> 'maxPlayers')::numeric::int);
  end if;
  if h ->> 'speed' in ('fast', 'normal', 'calm') then host_out := host_out || jsonb_build_object('speed', h ->> 'speed'); end if;
  if h ->> 'rounds' in ('1', '3', '5') then host_out := host_out || jsonb_build_object('rounds', (h ->> 'rounds')::int); end if;
  if h ->> 'answerMode' in ('text', 'voice') then host_out := host_out || jsonb_build_object('answerMode', h ->> 'answerMode'); end if;
  if jsonb_typeof(h -> 'excludedPlaylists') = 'array' then
    select coalesce(jsonb_agg(distinct tp.text), '[]'::jsonb) into v_ex
    from public.topic_pool tp
    where tp.is_song_category is true
      and tp.text in (select jsonb_array_elements_text(h -> 'excludedPlaylists'));
    host_out := host_out || jsonb_build_object('excludedPlaylists', v_ex);
  end if;
  if host_out <> '{}'::jsonb then out := out || jsonb_build_object('host', host_out); end if;

  if jsonb_typeof(s -> 'bots') = 'number' and (s ->> 'bots')::numeric between 1 and 5 then
    solo_out := solo_out || jsonb_build_object('bots', (s ->> 'bots')::numeric::int);
  end if;
  if s ->> 'skill' in ('mixed', '1', '2', '3') then solo_out := solo_out || jsonb_build_object('skill', s ->> 'skill'); end if;
  if solo_out <> '{}'::jsonb then out := out || jsonb_build_object('solo', solo_out); end if;

  update public.profiles set preferences = out where id = v_uid;
  return out;
end;
$function$;

-- ------------------------------------------------------------
-- Admin-Panel: Übersicht / Nutzer
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_whoami()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r text := public._require_staff('supporter');
begin
  return jsonb_build_object(
    'role', r,
    'counts', jsonb_build_object(
      'users', (select count(*) from auth.users),
      'deletionRequests', (select count(*) from public.profiles where status = 'deletion_requested'),
      'suspended', (select count(*) from public.profiles where status = 'suspended'),
      'staff', (select count(*) from public.profiles where role in ('admin', 'supporter')),
      'activeLobbies', (select count(*) from public.lobbies where last_activity_at > now() - interval '30 minutes'),
      'runningGames', (select count(*) from public.lobbies where phase in ('topic_vote', 'countdown', 'running', 'set_summary')),
      'newUsers7d', (select count(*) from auth.users where created_at > now() - interval '7 days')
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_users(p_search text DEFAULT NULL, p_filter text DEFAULT 'all', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(x) from (
      select u.id, p.username, p.display_name as "displayName", p.avatar_emoji as "avatarEmoji", p.avatar_color as "avatarColor",
             coalesce(p.role, 'user') as role, coalesce(p.status, 'active') as status, p.status_reason as "statusReason",
             p.deletion_requested_at as "deletionRequestedAt", u.email, u.created_at as "createdAt",
             u.last_sign_in_at as "lastSignInAt", (u.email_confirmed_at is not null) as confirmed,
             (select count(*) from public.account_matches m where m.user_id = u.id)::int as matches
      from auth.users u
      left join public.profiles p on p.id = u.id
      where (v_q is null
             or p.username ilike '%' || v_q || '%'
             or p.display_name ilike '%' || v_q || '%'
             or u.email ilike '%' || v_q || '%'
             or u.id::text = v_q)
        and (coalesce(p_filter, 'all') = 'all'
             or (p_filter = 'deletion' and p.status = 'deletion_requested')
             or (p_filter = 'suspended' and p.status = 'suspended')
             or (p_filter = 'staff' and p.role in ('admin', 'supporter')))
      order by (p.status = 'deletion_requested') desc nulls last, u.created_at desc
      limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(0, coalesce(p_offset, 0))
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_user(p_user_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return (
    select jsonb_build_object(
      'id', u.id, 'email', u.email, 'createdAt', u.created_at, 'lastSignInAt', u.last_sign_in_at,
      'confirmed', u.email_confirmed_at is not null, 'bannedUntil', u.banned_until,
      'username', p.username, 'displayName', p.display_name, 'avatarEmoji', p.avatar_emoji, 'avatarColor', p.avatar_color,
      'role', coalesce(p.role, 'user'), 'status', coalesce(p.status, 'active'), 'statusReason', p.status_reason,
      'statusChangedAt', p.status_changed_at, 'deletionRequestedAt', p.deletion_requested_at,
      'stats', jsonb_build_object(
        'matches', (select count(*) from public.account_matches where user_id = u.id),
        'matchWins', (select count(*) from public.account_matches where user_id = u.id and place = 1 and ranked),
        'rounds', (select count(*) from public.account_rounds where user_id = u.id),
        'titles', (select coalesce(sum(title_hits), 0) from public.account_rounds where user_id = u.id),
        'achievements', (select count(*) from public.player_achievements where user_id = u.id),
        'lastPlayed', (select max(finished_at) from public.account_matches where user_id = u.id)
      ),
      'audit', coalesce((
        select jsonb_agg(a order by a.created_at desc) from (
          select created_at, actor_name, action, details from public.admin_audit
          where target_id = u.id order by created_at desc limit 20
        ) a
      ), '[]'::jsonb)
    )
    from auth.users u left join public.profiles p on p.id = u.id
    where u.id = p_user_id
  );
end;
$function$;

-- Sperren / Entsperren / Löschantrag ablehnen
CREATE OR REPLACE FUNCTION public.admin_set_user_status(p_user_id uuid, p_status text, p_reason text DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  me text := public._require_staff('supporter');
  t record;
begin
  if p_status not in ('active', 'suspended') then raise exception 'status_invalid'; end if;
  if p_user_id = auth.uid() then raise exception 'not_on_self'; end if;
  select coalesce(p.role, 'user') as role, coalesce(p.status, 'active') as status, coalesce(p.username, u.email) as label
    into t from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  if t.role <> 'user' and me <> 'admin' then raise exception 'not_authorized'; end if;  -- Supporter dürfen kein Team-Konto sperren

  update public.profiles
     set status = p_status,
         status_reason = case when p_status = 'active' then null else nullif(left(trim(coalesce(p_reason, '')), 300), '') end,
         deletion_requested_at = case when p_status = 'active' then null else deletion_requested_at end,
         status_changed_at = now(), status_changed_by = auth.uid()
   where id = p_user_id;
  perform public._set_login_blocked(p_user_id, p_status <> 'active');
  perform public._audit(
    case when p_status = 'active' then (case when t.status = 'deletion_requested' then 'deletion_rejected' else 'unsuspended' end) else 'suspended' end,
    p_user_id, t.label, jsonb_build_object('reason', p_reason, 'previous', t.status));
end;
$function$;

-- Endgültig löschen (nur Admin, nie Team-Konten, nie sich selbst)
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare t record;
begin
  perform public._require_staff('admin');
  if p_user_id = auth.uid() then raise exception 'not_on_self'; end if;
  select coalesce(p.role, 'user') as role, coalesce(p.status, 'active') as status, coalesce(p.username, u.email) as label, u.email
    into t from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  if t.role <> 'user' then raise exception 'staff_cannot_be_deleted'; end if;
  perform public._audit('deleted', p_user_id, t.label, jsonb_build_object('status', t.status, 'email', t.email));
  delete from auth.users where id = p_user_id;  -- Profil, Verlauf, Achievements, Freunde per CASCADE
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_role(p_user_id uuid, p_role text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare t record;
begin
  perform public._require_staff('admin');
  if p_role not in ('user', 'supporter', 'admin') then raise exception 'role_invalid'; end if;
  if p_user_id = auth.uid() then raise exception 'not_on_self'; end if;  -- verhindert, dass man sich selbst aussperrt
  select coalesce(role, 'user') as role, coalesce(username, email) as label into t from public.profiles where id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  update public.profiles set role = p_role, is_platform_admin = (p_role = 'admin') where id = p_user_id;
  perform public._audit('role_changed', p_user_id, t.label, jsonb_build_object('from', t.role, 'to', p_role));
end;
$function$;

-- Moderation: Benutzername ändern, Spielername/Avatar zurücksetzen
CREATE OR REPLACE FUNCTION public.admin_update_user_profile(p_user_id uuid, p_username text DEFAULT NULL, p_reset_display_name boolean DEFAULT false, p_reset_avatar boolean DEFAULT false)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  me text := public._require_staff('supporter');
  t record;
  v text := nullif(public.normalize_username(coalesce(p_username, '')), '');
begin
  select coalesce(role, 'user') as role, coalesce(username, email) as label, username into t from public.profiles where id = p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  if t.role <> 'user' and me <> 'admin' then raise exception 'not_authorized'; end if;
  if v is not null and v is distinct from t.username then
    if not public._valid_username(v) then raise exception 'username_invalid'; end if;
    if exists (select 1 from public.profiles where lower(username) = v and id <> p_user_id) then raise exception 'username_taken'; end if;
    update public.profiles set username = v, username_changed_at = now() where id = p_user_id;
  end if;
  if p_reset_display_name then update public.profiles set display_name = null where id = p_user_id; end if;
  if p_reset_avatar then update public.profiles set avatar_emoji = null, avatar_color = null where id = p_user_id; end if;
  perform public._audit('profile_moderated', p_user_id, t.label,
    jsonb_build_object('username', v, 'resetDisplayName', p_reset_display_name, 'resetAvatar', p_reset_avatar));
end;
$function$;

-- Für den Passwort-Reset aus dem Panel: E-Mail eines Nutzers (wird im Panel ohnehin angezeigt) + Protokoll
CREATE OR REPLACE FUNCTION public.admin_log_password_reset(p_user_id uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_email text; v_label text;
begin
  perform public._require_staff('supporter');
  select u.email, coalesce(p.username, u.email) into v_email, v_label from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;
  if v_email is null then raise exception 'user_not_found'; end if;
  perform public._audit('password_reset_sent', p_user_id, v_label, null);
  return v_email;
end;
$function$;

-- ------------------------------------------------------------
-- Lobbys
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_lobbies()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(x order by x."lastActivityAt" desc) from (
      select l.id, l.code, l.phase, l.locked, l.created_at as "createdAt", l.last_activity_at as "lastActivityAt",
             l.series_index as "roundIndex", l.series_total as "roundsTotal", l.topic_selected as playlist,
             (select name from public.players h where h.lobby_id = l.id and h.player_id = l.host_player_id) as host,
             (select count(*) from public.players p where p.lobby_id = l.id and p.status = 'active' and not coalesce(p.is_bot, false))::int as humans,
             (select count(*) from public.players p where p.lobby_id = l.id and p.status = 'active' and coalesce(p.is_bot, false))::int as bots,
             (select count(*) from public.players p where p.lobby_id = l.id and p.status = 'active' and p.user_id is not null)::int as accounts
      from public.lobbies l
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_close_lobby(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_code text;
begin
  perform public._require_staff('supporter');
  select code into v_code from public.lobbies where id = p_lobby_id;
  if v_code is null then raise exception 'lobby_not_found'; end if;
  perform public._audit('lobby_closed', null, v_code, jsonb_build_object('lobbyId', p_lobby_id));
  delete from public.lobbies where id = p_lobby_id;  -- Spieler etc. per CASCADE; Clients sehen "Lobby nicht gefunden"
end;
$function$;

-- ------------------------------------------------------------
-- Songs (nur Admin): archivieren statt löschen -> wird nie mehr gezogen, jederzeit zurückholbar
-- ------------------------------------------------------------
INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Archiv (deaktivierte Songs)', false, false
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)');

CREATE OR REPLACE FUNCTION public.admin_list_songs(p_playlist text DEFAULT NULL, p_search text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform public._require_staff('admin');
  return coalesce((
    select jsonb_agg(x order by x.playlist, x.rate nulls last, x.title) from (
      select sp.id, sp.title, sp.artist, tp.text as playlist, sp.archived_from as "archivedFrom", sp.plays, sp.hits,
             case when sp.plays > 0 then round(100.0 * sp.hits / sp.plays) end as rate
      from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id
      where (tp.is_song_category is true or sp.archived_from is not null)
        and (p_playlist is null or tp.text = p_playlist or sp.archived_from = p_playlist)
        and (v_q is null or sp.title ilike '%' || v_q || '%' or sp.artist ilike '%' || v_q || '%')
      limit 500
    ) x
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_song_archived(p_song_id uuid, p_archived boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare s record; v_archive uuid; v_target uuid;
begin
  perform public._require_staff('admin');
  select sp.title, sp.artist, sp.archived_from, tp.text as playlist into s
  from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id where sp.id = p_song_id;
  if not found then raise exception 'song_not_found'; end if;
  select id into v_archive from public.topic_pool where text = 'Archiv (deaktivierte Songs)';
  if p_archived then
    if s.archived_from is not null then return; end if;
    update public.song_pool set archived_from = s.playlist, topic_pool_id = v_archive where id = p_song_id;
  else
    if s.archived_from is null then return; end if;
    select id into v_target from public.topic_pool where text = s.archived_from;
    if v_target is null then raise exception 'playlist_missing'; end if;
    update public.song_pool set archived_from = null, topic_pool_id = v_target where id = p_song_id;
  end if;
  perform public._audit(case when p_archived then 'song_archived' else 'song_restored' end, null,
    s.title || ' – ' || s.artist, jsonb_build_object('playlist', coalesce(s.archived_from, s.playlist)));
end;
$function$;

-- ------------------------------------------------------------
-- Protokoll
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_audit(p_limit integer DEFAULT 100)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return coalesce((
    select jsonb_agg(a order by a."createdAt" desc) from (
      select id, created_at as "createdAt", actor_name as "actorName", action, target_id as "targetId", target_label as "targetLabel", details
      from public.admin_audit order by created_at desc limit greatest(1, least(coalesce(p_limit, 100), 500))
    ) a
  ), '[]'::jsonb);
end;
$function$;

-- Rechte: alle admin_* nur für eingeloggte (Prüfung der Rolle passiert in der Funktion)
DO $$
declare f text;
begin
  foreach f in array array[
    'admin_whoami()', 'admin_list_users(text, text, integer, integer)', 'admin_get_user(uuid)',
    'admin_set_user_status(uuid, text, text)', 'admin_delete_user(uuid)', 'admin_set_role(uuid, text)',
    'admin_update_user_profile(uuid, text, boolean, boolean)', 'admin_log_password_reset(uuid)',
    'admin_list_lobbies()', 'admin_close_lobby(uuid)', 'admin_list_songs(text, text)',
    'admin_set_song_archived(uuid, boolean)', 'admin_list_audit(integer)'
  ] loop
    execute format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    execute format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  end loop;
end $$;

-- ------------------------------------------------------------
-- profiles.username ist Pflicht (NOT NULL): bei vergebenem/ungültigem Wunschnamen
-- automatisch einen freien Namen vergeben (z. B. "spieler4821"), statt die Registrierung
-- scheitern zu lassen. Der Name lässt sich danach im Profil ändern.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._unique_username(p_base text)
 RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  b text := left(regexp_replace(public.normalize_username(coalesce(p_base, '')), '[^a-z0-9._-]', '', 'g'), 14);
  c text;
  i int := 0;
begin
  if not public._valid_username(b) or public._is_profane(b) then b := 'spieler'; end if;
  c := b;
  while exists (select 1 from public.profiles where lower(username) = c) loop
    i := i + 1;
    c := b || (1000 + floor(random() * 9000))::int::text;
    if i > 50 then c := 'spieler' || floor(random() * 100000000)::bigint::text; end if;
  end loop;
  return c;
end;
$function$;
REVOKE ALL ON FUNCTION public._unique_username(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_username text := nullif(public.normalize_username(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if v_username is null
     or not public._valid_username(v_username)
     or public._is_profane(v_username)
     or exists (select 1 from public.profiles p where lower(p.username) = v_username and p.id <> new.id) then
    v_username := public._unique_username(coalesce(v_username, split_part(new.email, '@', 1)));
  end if;

  insert into public.profiles (id, username, email, created_at)
  values (new.id, v_username, new.email, now())
  on conflict (id) do update set
    email = coalesce(excluded.email, public.profiles.email);

  return new;
end;
$function$;

COMMIT;
