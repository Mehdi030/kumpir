-- ============================================================
-- 138: Fehler-Meldekanal vom Browser (Wunsch Mehdi, 2026-11-02)
-- ============================================================
-- Unbehandelte Browser-Fehler (window.onerror, abgelehnte Promises, Absturz-Seite) werden anonym als Ereignis "client_error"
-- gespeichert (kurze Meldung + Seitenpfad, max. 400 Byte, wie alle Ereignisse nach 90 Tagen gelöscht).
-- admin_client_errors(): die häufigsten Meldungen der letzten Tage für /admin/stats (nur Platform-Admins).
-- Außerdem in die Whitelist: lang_fr (fehlte), challenge_created / challenge_played (Herausforderungen, Migration 139).
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.log_event(p_event text, p_anon text, p_props jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_event not in (
    'home_view', 'solo_start', 'solo_game_started', 'host_created', 'join_success', 'spectate',
    'game_finished', 'invite_share', 'invite_copy', 'invite_qr', 'result_share',
    'install_click', 'lang_en', 'lang_fr', 'register_success', 'client_error', 'challenge_created', 'challenge_played'
  ) then return; end if;
  if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;
  begin perform public._rate_limit('log:' || public._client_ip(), 300, 60); exception when others then return; end;
  -- einfache Bremse gegen Spam: max. 120 Ereignisse pro Gerät und Stunde
  if (select count(*) from public.funnel_events
      where anon_id = p_anon and created_at > now() - interval '1 hour') >= 120 then
    return;
  end if;
  insert into public.funnel_events (event, anon_id, props)
  values (p_event, p_anon, case when p_props is null or pg_column_size(p_props) > 400 then null else p_props end);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_client_errors(p_days integer DEFAULT 7) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM public._require_platform_admin();
  RETURN coalesce((
    SELECT jsonb_agg(f ORDER BY (f->>'n')::int DESC) FROM (
      SELECT jsonb_build_object('msg', props ->> 'm', 'path', props ->> 'p', 'n', count(*)::int, 'devices', count(DISTINCT anon_id)::int, 'last', max(created_at)) AS f
        FROM public.funnel_events
       WHERE event = 'client_error' AND created_at > now() - make_interval(days => greatest(1, p_days))
         AND coalesce(props ->> 'dev', 'false') <> 'true'
       GROUP BY props ->> 'm', props ->> 'p'
       ORDER BY count(*) DESC LIMIT 30
    ) t
  ), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_client_errors(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_client_errors(integer) TO authenticated;

COMMIT;
