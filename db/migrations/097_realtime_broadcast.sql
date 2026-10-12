-- ============================================================
-- 097: Schnellere Live-Updates per Broadcast (2026-10-12)
-- ============================================================
-- Messung (db/scripts/test-latency.mjs): Über "postgres_changes" kam eine Weitergabe beim Client erst nach
-- Ø 0,44 s an (90 %: 0,67 s, Ausreißer 2,3 s) – Realtime prüft dabei für jeden Zuhörer die Leserechte.
-- Broadcast aus der Datenbank (realtime.send) geht direkt raus.
--
--   Kanal  kumpir:<lobby_id>   (öffentlich – die Lobby-Zeile ist ohnehin für alle lesbar)
--   Event  lobby    -> komplette Lobby-Zeile (der Client übernimmt sie sofort, ohne Nachladen)
--   Event  players  -> nur ein Signal (Spieler-Zeilen enthalten das Session-Token, das bleibt im Server);
--                     der Client lädt die Spielerliste nach
--
-- Fehler beim Senden stören das Spiel nie. postgres_changes + Polling bleiben als Rückfallebene.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._trg_broadcast_lobby()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  BEGIN
    PERFORM realtime.send(to_jsonb(NEW), 'lobby', 'kumpir:' || NEW.id::text, false);
  EXCEPTION WHEN others THEN
    NULL;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS lobbies_broadcast ON public.lobbies;
CREATE TRIGGER lobbies_broadcast AFTER INSERT OR UPDATE ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_broadcast_lobby();

CREATE OR REPLACE FUNCTION public._trg_broadcast_players()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_lobby uuid := coalesce(NEW.lobby_id, OLD.lobby_id);
BEGIN
  BEGIN
    PERFORM realtime.send(jsonb_build_object('at', now()), 'players', 'kumpir:' || v_lobby::text, false);
  EXCEPTION WHEN others THEN
    NULL;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS players_broadcast ON public.players;
CREATE TRIGGER players_broadcast AFTER INSERT OR UPDATE OR DELETE ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_broadcast_players();

-- Trigger-Funktionen nicht direkt aufrufbar machen (Whitelist-Modell, Migration 080)
REVOKE ALL ON FUNCTION public._trg_broadcast_lobby() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_broadcast_players() FROM PUBLIC, anon, authenticated;

COMMIT;
