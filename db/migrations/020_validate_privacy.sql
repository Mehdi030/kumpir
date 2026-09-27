-- ============================================================
-- Migration 020: p_privacy in rpc_create_lobby validiert
-- ============================================================
-- Beim Vollständigkeits-Audit gefunden: anders als p_round_speed
-- (bereits per Allow-List auf 'fast'/'normal'/'calm' geprüft) landete
-- p_privacy ungeprüft in lobbies.privacy -- kein CHECK-Constraint,
-- jeder beliebige String wäre durchgegangen. Aktuell nicht ausnutzbar
-- (die "Public"-Option ist im Frontend noch deaktiviert, "Kommt
-- später"), aber dieselbe Inkonsistenz wie beim runden_speed-Fund
-- (Migration 011) -- jetzt einheitlich behandelt.
-- ============================================================

BEGIN;

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
begin
  if v_round_speed not in ('fast', 'normal', 'calm') then
    v_round_speed := 'normal';
  end if;
  if v_privacy not in ('private', 'public') then
    v_privacy := 'private';
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

  insert into public.players (id, lobby_id, player_id, name, ready, joined_at, last_seen_at, user_id)
  values (gen_random_uuid(), v_lobby_id, v_host_player_id, left(trim(p_host_name), 24), false, now(), now(), p_user_id);

  return query select upper(v_code), v_host_player_id;
end;
$function$;

COMMIT;
