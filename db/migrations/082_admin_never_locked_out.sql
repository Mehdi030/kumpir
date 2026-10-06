-- ============================================================
-- Migration 082: Admins werden nie ausgebremst
-- ============================================================
-- Eingeloggte, aktive Admins sind von allen Rate-Limits ausgenommen (z. B. viele Testlobbys hintereinander).
-- Zusammen mit 080 (letzter Admin nicht sperr-/herabstufbar, Admins nie per Login-Sperre blockierbar)
-- und dem Notfall-Skript db/scripts/restore-admin.mjs (direkter DB-Zugang vom eigenen Rechner)
-- kann sich der Besitzer nicht aussperren.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._rate_limit(p_key text, p_max integer, p_seconds integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_w timestamptz := date_bin(make_interval(secs => p_seconds), now(), '2000-01-01'::timestamptz);
  v_n integer;
begin
  if coalesce(current_setting('request.headers', true), '') = '' then return; end if;  -- intern (pg_cron)
  if auth.uid() is not null and exists (
    select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'active'
  ) then
    return;  -- Admins nie ausbremsen
  end if;
  insert into public.rate_limits (key, window_start, n) values (p_key, v_w, 1)
  on conflict (key, window_start) do update set n = public.rate_limits.n + 1
  returning n into v_n;
  if v_n > p_max then raise exception 'rate_limited'; end if;
end;
$function$;
REVOKE ALL ON FUNCTION public._rate_limit(text, integer, integer) FROM PUBLIC, anon, authenticated;

COMMIT;
