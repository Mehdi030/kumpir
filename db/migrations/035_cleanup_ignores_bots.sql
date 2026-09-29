-- ============================================================
-- Migration 035: cleanup_lobby kickte Bots als "inaktiv" raus
-- ============================================================
-- Live gefunden: Bots in der Warte-Lobby werden nach 45s (der
-- staleSeconds-Schwelle aus useHeartbeat) automatisch auf status='left'
-- gesetzt, weil cleanup_lobby jeden Spieler mit altem last_seen_at
-- als inaktiv behandelt -- Bots haben aber gar keinen eigenen Tab, der
-- last_seen_at je auffrischen könnte. last_seen_at bleibt für einen Bot
-- für immer auf dem Wert vom Beitritt stehen.
--
-- Effekt beim Testen: die zuerst hinzugefügten Bots einer 8er-Lobby
-- verschwanden von selbst, während man noch die restlichen hinzufügte
-- oder alle auf "Bereit" stellte -- rein weil das Zusammenstellen
-- länger als 45s dauerte. Für echte Mitspieler mit eigenem Browser-Tab
-- ist genau diese Prüfung richtig (verwaiste Tabs sollen rausfliegen),
-- für Bots ist sie einfach nur ein Timer bis zum Rauswurf.
--
-- Fix: cleanup_lobby schließt is_bot=true jetzt explizit aus.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_lobby(p_lobby_id uuid, p_stale_seconds integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid;
  v_new_host uuid;
  v_phase text;
begin
  select host_player_id, phase
    into v_host, v_phase
  from public.lobbies
  where id = p_lobby_id;

  -- Only mark players as 'left' BEFORE the game is running.
  if v_phase is null or v_phase in ('lobby', 'topic_vote', 'countdown') then
    update public.players
    set status = 'left',
        left_at = coalesce(left_at, now())
    where lobby_id = p_lobby_id
      and status = 'active'
      and coalesce(is_bot, false) = false
      and (
        last_seen_at is null
        or last_seen_at < (now() - make_interval(secs => p_stale_seconds))
      );
  end if;

  if v_host is not null then
    if not exists (
      select 1 from public.players
      where lobby_id = p_lobby_id
        and player_id = v_host
        and status = 'active'
    ) then
      select player_id into v_new_host
      from public.players
      where lobby_id = p_lobby_id
        and status = 'active'
      order by joined_at asc nulls last, player_id asc
      limit 1;

      update public.lobbies
      set host_player_id = v_new_host
      where id = p_lobby_id;
    end if;
  end if;
end;
$function$;

COMMIT;
