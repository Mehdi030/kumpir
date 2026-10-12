-- ============================================================
-- 102: Eigener Avatar im Profil + "zuletzt da" bei Freunden (Wunsch Mehdi, 2026-10-12)
-- ============================================================
-- * profiles.avatar_config (jsonb): Aussehen der eigenen Spielfigur (Avataaars/DiceBear):
--     {"top","hairColor","skinColor","clothing","clothesColor","accessories","facialHair"} – nur Werte
--     aus einer festen Liste (update_my_avatar prüft). null = Figur aus dem Namen (wie bisher).
-- * players.avatar_config: beim Beitreten aus dem Profil übernommen (Trigger), damit Tisch, Lobby und
--   Ergebnisse die Figur ohne Zugriff auf fremde Profile zeigen können. Spalte ist lesbar (GRANT).
-- * get_friends_status: "lastSeen" fällt jetzt auf das letzte Match bzw. die letzte Anmeldung zurück
--   (vorher "Noch nie gesehen", wenn der Freund seit Einführung der Online-Anzeige nicht da war).
--   Neu "avatarConfig" für die Freundesliste.
-- * get_my_settings liefert "avatarConfig".
-- ============================================================
BEGIN;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_config jsonb;
ALTER TABLE public.players  ADD COLUMN IF NOT EXISTS avatar_config jsonb;
GRANT SELECT (avatar_config) ON public.players TO anon, authenticated;

-- Erlaubte Werte (müssen zu components/game/PlayerAvatar.tsx passen)
CREATE OR REPLACE FUNCTION public._avatar_allowed()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '{
    "top": ["bob","bun","curly","curvy","dreads","frida","fro","froBand","longButNotTooLong","miaWallace","shavedSides","straight02","straight01","straightAndStrand","dreads01","dreads02","frizzle","shaggy","shaggyMullet","shortCurly","shortFlat","shortRound","shortWaved","sides","theCaesar","theCaesarAndSidePart","bigHair","hat","hijab","turban","winterHat1","winterHat02","winterHat03","winterHat04","none"],
    "hairColor": ["2c1b18","4a312c","724133","a55728","b58143","d6b370","c93305","e8e1e1"],
    "skinColor": ["614335","ae5d29","d08b5b","edb98a","ffdbb4"],
    "clothing": ["blazerAndShirt","blazerAndSweater","collarAndSweater","graphicShirt","hoodie","overall","shirtCrewNeck","shirtScoopNeck","shirtVNeck"],
    "clothesColor": ["262e33","3c4f5c","25557c","5199e4","65c9ff","b1e2ff","a7ffc4","ffffb1","ffafb9","ff5c5c","ff488e","929598"],
    "accessories": ["none","prescription01","prescription02","round","sunglasses","wayfarers"],
    "facialHair": ["none","beardLight","beardMedium","beardMajestic","moustacheFancy","moustacheMagnum"]
  }'::jsonb;
$$;

CREATE OR REPLACE FUNCTION public.update_my_avatar(p_config jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_allowed jsonb := public._avatar_allowed();
  v_clean jsonb := '{}'::jsonb;
  k text;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  if p_config is not null then
    if jsonb_typeof(p_config) <> 'object' then raise exception 'avatar_invalid'; end if;
    for k in select jsonb_object_keys(v_allowed) loop
      if p_config ? k then
        if jsonb_typeof(p_config -> k) <> 'string' or not (v_allowed -> k) ? (p_config ->> k) then
          raise exception 'avatar_invalid';
        end if;
        v_clean := v_clean || jsonb_build_object(k, p_config ->> k);
      end if;
    end loop;
  end if;
  update public.profiles set avatar_config = case when v_clean = '{}'::jsonb then null else v_clean end where id = v_uid;
  -- Laufende/offene Lobbys sofort mit der neuen Figur
  update public.players set avatar_config = case when v_clean = '{}'::jsonb then null else v_clean end
   where user_id = v_uid and status = 'active';
end;
$function$;
REVOKE ALL ON FUNCTION public.update_my_avatar(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_my_avatar(jsonb) TO authenticated;

-- Beim Beitreten (und wenn ein Konto nachträglich zugeordnet wird) die Figur aus dem Profil übernehmen
CREATE OR REPLACE FUNCTION public._trg_player_avatar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.user_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN
    SELECT avatar_config INTO NEW.avatar_config FROM public.profiles WHERE id = NEW.user_id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._trg_player_avatar() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS players_avatar ON public.players;
CREATE TRIGGER players_avatar BEFORE INSERT OR UPDATE OF user_id ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_player_avatar();

CREATE OR REPLACE FUNCTION public.get_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  select username, display_name, avatar_emoji, avatar_color, avatar_config, preferences, email, username_changed_at, role, status
    into r from public.profiles where id = v_uid;
  if not found then
    insert into public.profiles (id, username, email, created_at)
    select id, public._unique_username(split_part(email, '@', 1)), email, now() from auth.users where id = v_uid
    on conflict (id) do nothing;
    return jsonb_build_object('username', (select username from public.profiles where id = v_uid), 'displayName', null, 'avatarEmoji', null,
                              'avatarColor', null, 'avatarConfig', null, 'preferences', '{}'::jsonb, 'role', 'user', 'status', 'active');
  end if;
  return jsonb_build_object(
    'username', r.username,
    'displayName', r.display_name,
    'avatarEmoji', r.avatar_emoji,
    'avatarColor', r.avatar_color,
    'avatarConfig', r.avatar_config,
    'preferences', coalesce(r.preferences, '{}'::jsonb),
    'usernameChangedAt', r.username_changed_at,
    'role', r.role,
    'status', r.status
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_friends_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid := auth.uid();
begin
  if v_me is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by (x."online") desc, lower(x.username))
    from (
      select pr.id as "userId", pr.username, pr.display_name as "displayName",
             pr.avatar_emoji as "avatarEmoji", pr.avatar_color as "avatarColor", pr.avatar_config as "avatarConfig",
             coalesce(up.last_seen_at > now() - interval '150 seconds', false) or lob.code is not null as "online",
             -- zuletzt da: Online-Anzeige, sonst letztes Match, sonst letzte Anmeldung (102)
             greatest(up.last_seen_at, lob.seen,
                      (select max(am.finished_at) from public.account_matches am where am.user_id = pr.id),
                      (select au.last_sign_in_at from auth.users au where au.id = pr.id)) as "lastSeen",
             lob.code as "lobbyCode", lob.phase as "lobbyPhase",
             coalesce(lob.phase = 'waiting' and not coalesce(lob.locked, false) and coalesce(lob.active_players, 0) < coalesce(lob.max_players, 0), false) as "joinable"
      from public.friendships f
      join public.profiles pr on pr.id = f.friend_user_id
      left join public.user_presence up on up.user_id = pr.id
      left join lateral (
        select l.code, l.phase, l.locked, l.max_players, p.last_seen_at as seen,
               (select count(*) from public.players q where q.lobby_id = l.id and q.status = 'active') as active_players
        from public.players p join public.lobbies l on l.id = p.lobby_id
        where p.user_id = pr.id and p.status = 'active' and p.last_seen_at > now() - interval '90 seconds'
        order by p.last_seen_at desc limit 1
      ) lob on true
      where f.user_id = v_me and f.status = 'accepted' and pr.status = 'active'
    ) x
  ), '[]'::jsonb);
end;
$function$;

COMMIT;
