-- ============================================================
-- Migration 012: RLS auf Kern-Tabellen fehlte komplett
-- ============================================================
-- Der Supabase Anon-Key liegt öffentlich im Frontend-Bundle. Ohne RLS
-- kann JEDER über die PostgREST-API direkt lesen/schreiben/löschen --
-- unabhängig davon, was der offizielle Frontend-Code tatsächlich tut.
--
-- Teil A (aus dem Audit-Auftrag, "mindestens sicherstellen"):
--   lobbies, players, topic_pool, topic_votes, game_runs bekommen
--   RLS + eine SELECT-für-alle-Policy (wird für Realtime-Subscriptions
--   und den Polling-Fallback gebraucht), aber KEINE INSERT/UPDATE/
--   DELETE-Policy -- alle Schreiboperationen laufen ausschließlich
--   über die SECURITY DEFINER RPCs (rpc_create_lobby, rpc_join_lobby,
--   rpc_pass_potato, ...), die RLS als Tabellenbesitzer umgehen.
--
-- Teil B (zusätzlich beim Audit gefunden, nicht in der ursprünglichen
-- Bug-Liste, aber derselbe Risiko-Klasse):
--   - game_run_players / game_run_eliminations / round_stats werden
--     von keiner Frontend-Route gelesen -> RLS an, KEINE Policy
--     (kompletter Lockout für anon/authenticated; nur die SECURITY
--     DEFINER Trigger/RPCs dürfen noch schreiben).
--   - lobby_admin_sessions / lobby_admin_logs / staff_roles: enthalten
--     Rollen-/Moderationsdaten, werden von keiner Frontend-Route
--     direkt gelesen -> RLS an, KEINE Policy (kompletter Lockout).
--   - kv_store_8e1b0e4b: unbenutzte Altlast (vermutlich Scaffolding-
--     Rest), wird nirgends referenziert -> RLS an, KEINE Policy.
--   - profiles: enthält email/phone (PII). Es gibt noch KEINE Policy
--     dafür, und apps/web/src/hooks/useFriends.ts liest per Anon-Key
--     direkt "profiles.username" für die Freundesliste. Statt RLS
--     (zeilenbasiert, kann keine Spalten filtern) nutzen wir
--     Column-Level-Privileges: anon/authenticated dürfen per REST nur
--     noch (id, username) sehen, nie email/phone/*verified_at. Alle
--     SECURITY DEFINER Funktionen (get_email_for_username, handle_new_user,
--     sync_profile_verification, ...) sind Owner der Tabelle und bleiben
--     davon unberührt.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Teil A: öffentlich lesbare Kern-Tabellen
-- ------------------------------------------------------------
ALTER TABLE public.lobbies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "lobbies_read_all" ON public.lobbies;
CREATE POLICY "lobbies_read_all" ON public.lobbies FOR SELECT USING (TRUE);

ALTER TABLE public.players ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "players_read_all" ON public.players;
CREATE POLICY "players_read_all" ON public.players FOR SELECT USING (TRUE);

ALTER TABLE public.topic_pool ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "topic_pool_read_all" ON public.topic_pool;
CREATE POLICY "topic_pool_read_all" ON public.topic_pool FOR SELECT USING (TRUE);

ALTER TABLE public.topic_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "topic_votes_read_all" ON public.topic_votes;
CREATE POLICY "topic_votes_read_all" ON public.topic_votes FOR SELECT USING (TRUE);

ALTER TABLE public.game_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "game_runs_read_all" ON public.game_runs;
CREATE POLICY "game_runs_read_all" ON public.game_runs FOR SELECT USING (TRUE);


-- ------------------------------------------------------------
-- Teil B: komplett sperren (kein Frontend-Zugriff nötig)
-- ------------------------------------------------------------
ALTER TABLE public.game_run_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_run_eliminations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.round_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lobby_admin_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lobby_admin_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kv_store_8e1b0e4b ENABLE ROW LEVEL SECURITY;
-- Bewusst keine Policies -> Default-Deny für anon/authenticated.


-- ------------------------------------------------------------
-- profiles: RLS an (Zeilen-Ebene) + Column-Level-Grants (Spalten-Ebene)
-- ------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profiles_read_all" ON public.profiles;
CREATE POLICY "profiles_read_all" ON public.profiles FOR SELECT USING (TRUE);

REVOKE SELECT ON public.profiles FROM anon, authenticated;
GRANT SELECT (id, username) ON public.profiles TO anon, authenticated;

COMMIT;
