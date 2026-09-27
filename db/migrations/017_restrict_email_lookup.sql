-- ============================================================
-- Migration 017: get_email_for_username nicht mehr öffentlich aufrufbar
-- ============================================================
-- Beim Sicherheits-Audit gefunden (nicht vom Advisor gemeldet, aber
-- schwerwiegender als die beiden View-Funde): get_email_for_username(
-- p_username text) RETURNS text war als normale RPC für anon/
-- authenticated aufrufbar UND gab die Klartext-Email direkt zurück.
--
-- apps/web/src/app/login/page.tsx rief sie bisher direkt vom Browser
-- aus auf, um Username-Login zu ermöglichen ("kein @ im Feld -> Email
-- per RPC holen, dann signInWithPassword"). Das Problem: der Anon-Key
-- liegt öffentlich im Frontend-Bundle -- JEDER kann die RPC direkt per
-- REST aufrufen (unabhängig vom eigentlichen Frontend-Code) und damit
-- für JEDEN bekannten Username (Usernames sind über leaderboard_view/
-- friends_view ohnehin öffentlich sichtbar) die zugehörige Email
-- abgreifen. Das ist ein klassisches Username->Email-Harvesting für
-- Phishing/Spam/Credential-Stuffing-Listen -- schwerwiegender als die
-- beiden Advisor-Funde, weil hier tatsächlich PII (Email) mit einem
-- einzigen, für jeden möglichen Aufruf abfließt.
--
-- Fix: EXECUTE-Recht für anon/authenticated entzogen. Die Funktion
-- bleibt für den Owner (postgres) bzw. den service_role (umgeht
-- Grants ohnehin) nutzbar. Der Login-Flow wird im selben Zug auf
-- einen Server Action umgestellt (siehe apps/web/src/actions/login.ts),
-- der die Email serverseitig mit dem Service-Role-Key auflöst und NIE
-- an den Browser zurückgibt.
--
-- WICHTIG: Ohne SUPABASE_SERVICE_ROLE_KEY in der Server-Umgebung
-- funktioniert Username-Login danach nicht mehr (Email-Login bleibt
-- unberührt) -- siehe apps/web/.env.example.
-- ============================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.get_email_for_username(text) FROM PUBLIC, anon, authenticated;

COMMIT;
