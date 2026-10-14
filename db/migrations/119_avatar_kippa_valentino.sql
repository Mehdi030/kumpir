-- ============================================================
-- 119: Kippa und Schläfenlocken (Peies) – nur für das Konto "valentino" (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- Zwei neue Werte für avatar_config.top: "kippa" (Kippa auf dem Kopf) und "kippaPayot" (Kippa + geflochtene
-- Schläfenlocken). Wie der Ziegenbart bei "achi" (Migration 103) sind sie reserviert: update_my_avatar wirft
-- 'avatar_reserved', wenn ein anderes Konto sie setzen will. Valentino wählt sie selbst im Profil
-- (Reiter "Kopf" -> Frisur / Kopfbedeckung); es wird nichts automatisch gesetzt.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._avatar_allowed()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '{
    "gender": ["m","f"],
    "top": ["bob","bun","curly","curvy","dreads","frida","fro","froBand","longButNotTooLong","miaWallace","shavedSides","straight02","straight01","straightAndStrand","dreads01","dreads02","frizzle","shaggy","shaggyMullet","shortCurly","shortFlat","shortRound","shortWaved","sides","theCaesar","theCaesarAndSidePart","bigHair","hat","hijab","turban","winterHat1","winterHat02","winterHat03","winterHat04","kippa","kippaPayot","none"],
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
  v_user text;
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
    v_user := coalesce((select lower(username) from public.profiles where id = v_uid), '');
    -- Ziegenbart: nur Achi (Wunsch Mehdi)
    if v_clean ->> 'facialHair' = 'goatee' and v_user <> 'achi' then
      raise exception 'avatar_reserved';
    end if;
    -- Kippa / Schläfenlocken: nur Valentino (Wunsch Mehdi)
    if v_clean ->> 'top' in ('kippa', 'kippaPayot') and v_user <> 'valentino' then
      raise exception 'avatar_reserved';
    end if;
  end if;
  update public.profiles set avatar_config = case when v_clean = '{}'::jsonb then null else v_clean end where id = v_uid;
  update public.players set avatar_config = case when v_clean = '{}'::jsonb then null else v_clean end
   where user_id = v_uid and status = 'active';
end;
$function$;

COMMIT;
