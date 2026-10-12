-- ============================================================
-- 103: Mehr Avatar-Optionen, Ziegenbart nur für Achi, Online-Status sofort, Künstler ohne Zahl
--      (Wunsch Mehdi, 2026-10-12)
-- ============================================================
-- Avatar (profiles.avatar_config, Migration 102) – neue Schlüssel:
--   gender (m/f, filtert im Profil die Frisuren), eyeColor, hatColor, facialHairColor, accessoriesColor,
--   logo (Sport-Haken / drei Streifen / Krone / Blitz auf dem Shirt), mehr Mützen (winterHat03/04).
--   facialHair "goatee" (Ziegenbart) ist reserviert für das Konto "achi" – er bekommt ihn direkt gesetzt,
--   kann ihn ab- und wieder anlegen, sonst niemand.
-- Online-Status: touch_presence schickt beim Online-Kommen (vorher > 150 s weg) sofort ein Signal an alle
--   Freunde (Broadcast "presence" auf Kanal friends:<freund_id>), die Freundesliste lädt dann neu.
-- Antworten: Künstlernamen zählen auch ohne Zahl ("Apache" für "Apache 207", "Ufo" für "Ufo361").
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._avatar_allowed()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '{
    "gender": ["m","f"],
    "top": ["bob","bun","curly","curvy","dreads","frida","fro","froBand","longButNotTooLong","miaWallace","shavedSides","straight02","straight01","straightAndStrand","dreads01","dreads02","frizzle","shaggy","shaggyMullet","shortCurly","shortFlat","shortRound","shortWaved","sides","theCaesar","theCaesarAndSidePart","bigHair","hat","hijab","turban","winterHat1","winterHat02","winterHat03","winterHat04","none"],
    "hairColor": ["2c1b18","4a312c","724133","a55728","b58143","d6b370","c93305","e8e1e1"],
    "hatColor": ["262e33","3c4f5c","929598","e6e6e6","ffffff","25557c","5199e4","65c9ff","b1e2ff","a7ffc4","ffffb1","ffdeb5","ffafb9","ff5c5c","ff488e"],
    "skinColor": ["614335","ae5d29","d08b5b","edb98a","ffdbb4"],
    "eyeColor": ["4a2c17","7a4a22","2f6fb5","5aa0d8","3f8a4a","6b7a88","1a1a1a"],
    "clothing": ["blazerAndShirt","blazerAndSweater","collarAndSweater","graphicShirt","hoodie","overall","shirtCrewNeck","shirtScoopNeck","shirtVNeck"],
    "clothesColor": ["262e33","3c4f5c","25557c","5199e4","65c9ff","b1e2ff","a7ffc4","ffffb1","ffafb9","ff5c5c","ff488e","929598","e6e6e6","ffffff"],
    "logo": ["none","swoosh","stripes","crown","bolt"],
    "accessories": ["none","prescription01","prescription02","round","sunglasses","wayfarers"],
    "accessoriesColor": ["262e33","3c4f5c","929598","e6e6e6","25557c","5199e4","65c9ff","a7ffc4","ffffb1","ffafb9","ff5c5c","ff488e"],
    "facialHair": ["none","beardLight","beardMedium","beardMajestic","moustacheFancy","moustacheMagnum","goatee"],
    "facialHairColor": ["2c1b18","4a312c","724133","a55728","b58143","d6b370","c93305","e8e1e1"]
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
    -- Ziegenbart: nur Achi (Wunsch Mehdi)
    if v_clean ->> 'facialHair' = 'goatee'
       and coalesce((select lower(username) from public.profiles where id = v_uid), '') <> 'achi' then
      raise exception 'avatar_reserved';
    end if;
  end if;
  update public.profiles set avatar_config = case when v_clean = '{}'::jsonb then null else v_clean end where id = v_uid;
  update public.players set avatar_config = case when v_clean = '{}'::jsonb then null else v_clean end
   where user_id = v_uid and status = 'active';
end;
$function$;

-- Achi bekommt den Ziegenbart direkt (bestehende Wahl bleibt erhalten)
UPDATE public.profiles
   SET avatar_config = coalesce(avatar_config, '{}'::jsonb) || '{"facialHair":"goatee","gender":"m"}'::jsonb
 WHERE lower(username) = 'achi';
UPDATE public.players p
   SET avatar_config = pr.avatar_config
  FROM public.profiles pr
 WHERE pr.id = p.user_id AND lower(pr.username) = 'achi' AND p.status = 'active';

-- Online-Status: beim Online-Kommen sofort alle Freunde benachrichtigen
CREATE OR REPLACE FUNCTION public.touch_presence()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_prev timestamptz;
  f record;
begin
  if v_uid is null then return; end if;
  select last_seen_at into v_prev from public.user_presence where user_id = v_uid;
  insert into public.user_presence (user_id, last_seen_at) values (v_uid, now())
  on conflict (user_id) do update set last_seen_at = now()
  where public.user_presence.last_seen_at < now() - interval '20 seconds';
  if v_prev is null or v_prev < now() - interval '150 seconds' then
    for f in select friend_user_id from public.friendships where user_id = v_uid and status = 'accepted' loop
      begin
        perform realtime.send(jsonb_build_object('at', now()), 'presence', 'friends:' || f.friend_user_id::text, false);
      exception when others then null;
      end;
    end loop;
  end if;
end;
$function$;

-- Künstlernamen auch ohne Zahl ("Apache 207" -> "apache", "Ufo361" -> "ufo")
CREATE OR REPLACE FUNCTION public._song_artist_names(p_artist text, p_feat text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(array_agg(DISTINCT n) FILTER (WHERE n <> ''), '{}')
  FROM (
    SELECT v AS n FROM (
      SELECT public._ans_norm(x) AS base
      FROM unnest(regexp_split_to_array(coalesce(p_artist, ''), '\s*,\s*|\s*&\s*|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+und\s+', 'i')) AS x
      UNION ALL
      SELECT public._ans_norm(f) FROM unnest(coalesce(p_feat, '{}')) AS f
    ) b,
    LATERAL (SELECT trim(regexp_replace(regexp_replace(b.base, '[0-9]+', ' ', 'g'), '\s+', ' ', 'g')) AS stripped) s,
    LATERAL (VALUES (b.base), (CASE WHEN length(replace(s.stripped, ' ', '')) >= 3 THEN s.stripped ELSE '' END)) AS t(v)
  ) t;
$$;

COMMIT;
