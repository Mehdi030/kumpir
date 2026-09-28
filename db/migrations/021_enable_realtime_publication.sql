-- ============================================================
-- Migration 021: Tabellen der supabase_realtime-Publication hinzugefügt
-- ============================================================
-- Live-Test gefunden: Ready-Toggle "zögert" / reagiert verzögert.
-- Ursache: KEINE einzige Migration hat jemals eine der Tabellen, auf
-- die useLobbyRealtime.ts (lobbies, players, topic_votes) und
-- usePassAttempt.ts (pass_attempts, pass_attempt_votes) per
-- `postgres_changes` hören, der supabase_realtime-Publication
-- hinzugefügt. Der WebSocket verbindet zwar erfolgreich (der Client
-- zeigt "🟢 Live"), aber Postgres schickt für diese Tabellen NIE ein
-- Change-Event -- die App lief die ganze Zeit ausschließlich über den
-- Polling-Fallback (alle 650ms-4s, je nach Seite), nie über echtes
-- Realtime. Das erklärt die spürbare Verzögerung bei Ready-Toggle,
-- Topic-Voting, Pass-Validierung etc., die im Live-Test auffiel.
--
-- Fix: alle fünf Tabellen der Publication hinzufügen. Idempotent via
-- Check gegen pg_publication_tables (ALTER PUBLICATION ... ADD TABLE
-- kennt kein natives IF NOT EXISTS).
-- ============================================================

BEGIN;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lobbies', 'players', 'topic_votes', 'pass_attempts', 'pass_attempt_votes']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END;
$$;

COMMIT;
