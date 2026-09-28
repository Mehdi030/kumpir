-- ============================================================
-- Migration 022: kick_player repariert + rpc_leave_lobby ergänzt
-- ============================================================
-- Zwei Regressionen, beide durch frühere Migrationen dieser Reihe
-- verursacht und erst durch die Cheat-Probe
-- (apps/web/scripts/probe-cheats.mjs) sichtbar geworden:
--
-- 1) kick_player ist komplett kaputt:
--    Fehler "function public.rpc_reset_lobby(text) does not exist".
--    In der LIVE-Datenbank existiert ein nie ins Repo gedumpter
--    Legacy-Trigger auf public.players, der beim Statuswechsel
--    (left/kicked) rpc_reset_lobby(p_code) mit der ALTEN einarmigen
--    Signatur aufruft. Migration 019 hat genau diese Signatur
--    gedroppt -> jeder Kick schlägt seitdem fehl.
--    Fix: einarmige Variante wiederherstellen, aber für anon/
--    authenticated gesperrt. Der Legacy-Trigger läuft im
--    SECURITY-DEFINER-Kontext (Owner) und darf sie weiterhin
--    aufrufen; von außen ist sie nicht mehr erreichbar, die
--    Absicherung aus Migration 019 bleibt also wirksam.
--
-- 2) "Lobby verlassen" funktioniert seit Migration 012 nicht mehr:
--    lobby/[code]/page.tsx schreibt per
--    supabase.from("players").update({status:'left'}) direkt in die
--    Tabelle. Migration 012 hat RLS aktiviert und bewusst KEINE
--    UPDATE-Policy vergeben -> der Schreibzugriff wird mit 42501
--    abgelehnt, der Fehler im Client verschluckt (leerer catch).
--    Der Spieler bleibt als Geist "active" in der Lobby zurück.
--    Fix: rpc_leave_lobby als regulärer, geprüfter Schreibpfad.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Legacy-Kompatibilität für den Trigger: rpc_reset_lobby(text)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then return; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

-- Nur für interne Aufrufer (Legacy-Trigger laufen als Owner).
REVOKE EXECUTE ON FUNCTION public.rpc_reset_lobby(text) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- 2) Sauberer Austritts-Pfad statt direktem Tabellen-UPDATE
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_leave_lobby(p_lobby_id UUID, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_phase text;
  v_new_host uuid;
begin
  select host_player_id, phase into v_host, v_phase
  from public.lobbies where id = p_lobby_id;

  if v_host is null then raise exception 'lobby_not_found'; end if;

  update public.players
  set status = 'left', left_at = now(), ready = false
  where lobby_id = p_lobby_id and player_id = p_player_id and status = 'active';

  if not found then return; end if;

  -- Host verlässt die Lobby -> Rolle an den nächsten aktiven Spieler
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
