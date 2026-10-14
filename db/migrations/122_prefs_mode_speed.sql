-- ============================================================
-- 122: Lobby hosten / Gegen Bots merken sich jetzt auch Modus und Tempo (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- Die Spiel-Einstellungen im Profil sind weg; stattdessen merkt sich "Lobby hosten" (und "Gegen Bots") beim Erstellen
-- automatisch, was zuletzt gewählt war. Neu in profiles.preferences: host.mode, solo.mode, solo.speed.
-- (set_my_preferences übernimmt nur bekannte Schlüssel – deshalb hier erweitert.)
-- ============================================================
BEGIN;

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

  if p ->> 'lang' in ('de', 'en', 'fr') then out := out || jsonb_build_object('lang', p ->> 'lang'); end if;
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
  if h ->> 'mode' in ('original', 'buzzer', 'year') then host_out := host_out || jsonb_build_object('mode', h ->> 'mode'); end if;
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
  if s ->> 'mode' in ('original', 'buzzer', 'year') then solo_out := solo_out || jsonb_build_object('mode', s ->> 'mode'); end if;
  if s ->> 'speed' in ('fast', 'normal', 'calm') then solo_out := solo_out || jsonb_build_object('speed', s ->> 'speed'); end if;
  if solo_out <> '{}'::jsonb then out := out || jsonb_build_object('solo', solo_out); end if;

  update public.profiles set preferences = out where id = v_uid;
  return out;
end;
$function$;

COMMIT;
