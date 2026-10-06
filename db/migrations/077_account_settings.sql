-- ============================================================
-- Migration 077: Konto-Einstellungen + Login-Robustheit + Sicherheitsfix
-- ============================================================
-- 1) SICHERHEIT: anon/authenticated hatten UPDATE/INSERT auf ALLE Spalten von
--    profiles (inkl. is_platform_admin) und die Policy "profiles_update_own" –
--    jeder Eingeloggte konnte sich per API selbst zum Admin machen oder Username/
--    E-Mail ohne Prüfung ändern. Ab jetzt: nur noch Lesen; Änderungen nur über
--    geprüfte RPCs unten.
-- 2) Neue Profilfelder: Spielername, Avatar (Emoji + Farbe), Vorlieben (jsonb).
-- 3) RPCs: get_my_settings, set_my_username, update_my_profile,
--    set_my_preferences, delete_my_account.
-- 4) Login: Konten ohne Profilzeile (z. B. vor dem Profil-Trigger angelegt)
--    werden nachgetragen; handle_new_user bricht eine Registrierung nicht mehr
--    ab, wenn der Wunsch-Username inzwischen vergeben/ungültig ist.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Rechte auf profiles: nur noch lesen
-- ------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.profiles FROM anon, authenticated;
DROP POLICY IF EXISTS profiles_update_own ON public.profiles;

-- ------------------------------------------------------------
-- 2) Neue Spalten
-- ------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS display_name text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_emoji text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_color text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS preferences jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS username_changed_at timestamptz;

-- Öffentlich sichtbar (Bestenliste/Freunde): Name + Avatar. Vorlieben/E-Mail nur über RPC.
GRANT SELECT (display_name, avatar_emoji, avatar_color) ON public.profiles TO anon, authenticated;

-- ------------------------------------------------------------
-- Prüf-Hilfen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._valid_username(p text)
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$
  select p is not null and p ~ '^[a-z0-9._-]{3,20}$';
$function$;

-- Spielername wie beim Beitreten: nur Buchstaben (inkl. Umlaute), 2–12 Zeichen
CREATE OR REPLACE FUNCTION public._valid_display_name(p text)
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$
  select p is not null and p ~ '^[A-Za-zÄÖÜäöüß]{2,12}$';
$function$;

-- Grobe Schimpfwort-Sperre (gleiche Liste wie lib/profanity.ts, Kurzfassung)
CREATE OR REPLACE FUNCTION public._is_profane(p text)
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$
  select lower(coalesce(p, '')) ~ '(arschloch|fotze|hurensohn|missgeburt|nazi|neger|schlampe|schwuchtel|wichser|bitch|cunt|faggot|kike|nigger|nigga|retard|whore)';
$function$;

-- ------------------------------------------------------------
-- 4a) Registrierung robust: vergebener/ungültiger Wunsch-Username -> NULL statt Fehler
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_username text := nullif(public.normalize_username(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if v_username is not null and (
       not public._valid_username(v_username)
       or public._is_profane(v_username)
       or exists (select 1 from public.profiles p where lower(p.username) = v_username and p.id <> new.id)
     ) then
    v_username := null;  -- Konto trotzdem anlegen; Username wählt man dann im Profil
  end if;

  insert into public.profiles (id, username, email, created_at)
  values (new.id, v_username, new.email, now())
  on conflict (id) do update set
    username = coalesce(public.profiles.username, excluded.username),
    email = coalesce(excluded.email, public.profiles.email);

  return new;
end;
$function$;

-- 4b) Fehlende Profile nachtragen (z. B. Konto "medo" von Feb. 2026 ohne Profilzeile)
INSERT INTO public.profiles (id, username, email, email_verified_at, created_at)
SELECT u.id,
       case
         when public._valid_username(public.normalize_username(u.raw_user_meta_data->>'username'))
              and not exists (select 1 from public.profiles p
                              where lower(p.username) = public.normalize_username(u.raw_user_meta_data->>'username'))
         then public.normalize_username(u.raw_user_meta_data->>'username')
       end,
       u.email, u.email_confirmed_at, coalesce(u.created_at, now())
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id)
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------
-- 3) Einstellungen
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  select username, display_name, avatar_emoji, avatar_color, preferences, email, username_changed_at
    into r from public.profiles where id = v_uid;
  if not found then
    -- Sicherheitsnetz: Profil fehlt -> jetzt anlegen (ohne Username)
    insert into public.profiles (id, email, created_at)
    select id, email, now() from auth.users where id = v_uid
    on conflict (id) do nothing;
    return jsonb_build_object('username', null, 'displayName', null, 'avatarEmoji', null,
                              'avatarColor', null, 'preferences', '{}'::jsonb);
  end if;
  return jsonb_build_object(
    'username', r.username,
    'displayName', r.display_name,
    'avatarEmoji', r.avatar_emoji,
    'avatarColor', r.avatar_color,
    'preferences', coalesce(r.preferences, '{}'::jsonb),
    'usernameChangedAt', r.username_changed_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_username(p_username text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v text := public.normalize_username(p_username);
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if not public._valid_username(v) then raise exception 'username_invalid'; end if;
  if public._is_profane(v) then raise exception 'username_profane'; end if;
  if exists (select 1 from public.profiles where lower(username) = v and id <> v_uid) then
    raise exception 'username_taken';
  end if;
  update public.profiles
     set username = v,
         username_changed_at = case when username is distinct from v then now() else username_changed_at end
   where id = v_uid;
  return v;
exception when unique_violation then
  raise exception 'username_taken';
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_my_profile(p_display_name text, p_avatar_emoji text, p_avatar_color text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_name text := nullif(trim(coalesce(p_display_name, '')), '');
  v_emoji text := nullif(trim(coalesce(p_avatar_emoji, '')), '');
  v_color text := nullif(trim(coalesce(p_avatar_color, '')), '');
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if v_name is not null and (not public._valid_display_name(v_name) or public._is_profane(v_name)) then
    raise exception 'display_name_invalid';
  end if;
  -- Emoji: ein einzelnes Zeichen bzw. eine kurze Emoji-Sequenz, keine Buchstaben/Ziffern
  if v_emoji is not null and (char_length(v_emoji) > 8 or v_emoji ~ '[A-Za-z0-9<>"''&]') then
    raise exception 'avatar_invalid';
  end if;
  if v_color is not null and v_color !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'avatar_invalid';
  end if;
  update public.profiles
     set display_name = v_name, avatar_emoji = v_emoji, avatar_color = lower(v_color)
   where id = v_uid;
end;
$function$;

-- Vorlieben: nur bekannte Schlüssel mit gültigen Werten werden übernommen.
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

-- Konto löschen: entfernt den Auth-Nutzer; Profil, Verlauf, Achievements, Freunde
-- fallen per Fremdschlüssel (ON DELETE CASCADE) weg, Spieler-Zeilen verlieren die Verknüpfung.
CREATE OR REPLACE FUNCTION public.delete_my_account()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from public.profiles where id = v_uid and coalesce(is_platform_admin, false)) then
    raise exception 'admin_cannot_delete';  -- Admin-Konto nicht versehentlich verlieren
  end if;
  delete from auth.users where id = v_uid;
end;
$function$;

REVOKE ALL ON FUNCTION public.get_my_settings() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_my_username(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_my_profile(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_my_preferences(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_username(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_my_profile(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_preferences(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

-- Username-Verfügbarkeit auch für die Profil-Seite (eigener Name zählt als frei)
CREATE OR REPLACE FUNCTION public.is_username_available(p_username text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._valid_username(public.normalize_username(p_username))
     and not public._is_profane(p_username)
     and not exists (
       select 1 from public.profiles
       where lower(username) = public.normalize_username(p_username)
         and id is distinct from auth.uid()
     );
$function$;

-- Saison-Bestenliste mit Avatar (Spalten nur hinten anhängen)
CREATE OR REPLACE VIEW public.season_leaderboard_view
  WITH (security_invoker = true) AS
SELECT sp.season, sp.user_id, pr.username, sp.arena_points, sp.sets_played, sp.set_wins,
       rank() OVER (PARTITION BY sp.season ORDER BY sp.arena_points DESC, sp.set_wins DESC) AS rank,
       pr.avatar_emoji, pr.avatar_color
FROM public.season_points sp
JOIN public.profiles pr ON pr.id = sp.user_id
WHERE pr.username IS NOT NULL;

COMMIT;
