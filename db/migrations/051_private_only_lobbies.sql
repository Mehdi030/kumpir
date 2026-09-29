-- ============================================================
-- Migration 051: Nur noch private Lobbys -- Public komplett raus
-- ============================================================
-- Host-UI hatte "Public" schon länger deaktiviert (Migration 020), jetzt
-- wird die Möglichkeit auch serverseitig entfernt statt nur versteckt:
--   - rpc_create_lobby (6-Parameter-Version, die aktuell einzige vom
--     Frontend genutzte Überladung) erzwingt jetzt IMMER 'private',
--     unabhängig vom übergebenen p_privacy-Wert -- Parameter bleibt in
--     der Signatur (Kompatibilität), wird aber ignoriert.
--   - set_lobby_privacy (nachträgliches Umschalten auf öffentlich) und
--     public_lobbies_view (Grundlage für die /browse-Seite) werden
--     komplett entfernt.
-- Die beiden älteren rpc_create_lobby-Überladungen (4/5 Parameter) sind
-- vom aktuellen Frontend ungenutzt und bleiben unangetastet -- sie
-- defaulten bei ungültigem privacy-Wert ohnehin schon auf 'private'.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_create_lobby(p_host_name text, p_privacy text, p_max_players integer, p_round_seconds integer, p_user_id uuid DEFAULT NULL::uuid, p_round_speed text DEFAULT 'normal'::text)
 RETURNS TABLE(code text, host_player_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid := gen_random_uuid();
  v_code text;
  v_host_player_id uuid := gen_random_uuid();
  v_round_speed text := btrim(coalesce(p_round_speed, 'normal'));
  v_privacy text := 'private';
  v_headers text;
  v_token uuid;
begin
  if v_round_speed not in ('fast', 'normal', 'calm') then
    v_round_speed := 'normal';
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

DROP FUNCTION IF EXISTS public.set_lobby_privacy(uuid, uuid, text);
DROP VIEW IF EXISTS public.public_lobbies_view;

COMMIT;
