-- ============================================================
-- 089: Konto ohne E-Mail (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Registrieren nur noch mit Benutzername + Passwort. Das Konto legt der Server (Next.js, service_role)
-- direkt bestätigt an, mit einer internen Platzhalter-Adresse <zufall>@konto.kumpir.invalid, die nie
-- angezeigt wird und keine Mails bekommt. Diese Funktion bremst Massen-Registrierungen:
-- höchstens 5 neue Konten pro IP und Stunde. Nur der Server darf sie aufrufen.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.register_guard(p_ip text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public._rate_limit('register:' || coalesce(nullif(trim(p_ip), ''), 'unbekannt'), 5, 3600);
END;
$$;

REVOKE ALL ON FUNCTION public.register_guard(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_guard(text) TO service_role;

COMMIT;
