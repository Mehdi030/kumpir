-- ============================================================
-- 090: Spiel-Logs nach Discord (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Die Datenbank schickt wichtige Ereignisse selbst an Discord-Webhooks (pg_net, asynchron nach dem
-- Speichern – das Spiel wartet nie auf Discord, Fehler werden verschluckt):
--   spiele   : Spiel gestartet / Match beendet mit Rangliste
--   konten   : neues Konto, Konto gelöscht
--   admin    : Aktionen aus dem Protokoll (Rollen, Sperren, Kicks, Songs, Playlists, ...)
--   bericht  : Tagesbericht um 23:00 (deutsche Zeit) – Matches, Spieler, neue Konten
-- Die Webhook-Adressen liegen in private.discord_hooks (nicht über die API erreichbar) und werden von
-- db/scripts/discord-setup.mjs eingetragen. Ohne Eintrag passiert einfach nichts.
-- ============================================================
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.discord_hooks (
  channel    text PRIMARY KEY,           -- spiele | konten | admin | bericht
  url        text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON private.discord_hooks FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ Senden
CREATE OR REPLACE FUNCTION private.discord_send(p_channel text, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE v_url text;
BEGIN
  SELECT url INTO v_url FROM private.discord_hooks WHERE channel = p_channel;
  IF v_url IS NULL THEN RETURN; END IF;
  PERFORM net.http_post(
    url := v_url,
    body := p_payload || jsonb_build_object('username', 'Kumpir'),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000
  );
EXCEPTION WHEN OTHERS THEN
  NULL;  -- Discord darf das Spiel nie stören
END;
$$;
REVOKE ALL ON FUNCTION private.discord_send(text, jsonb) FROM PUBLIC, anon, authenticated;

-- Discord-Text entschärfen (keine @everyone-Erwähnungen, kein Markdown aus Spielernamen)
CREATE OR REPLACE FUNCTION private.dc_safe(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT regexp_replace(replace(coalesce(p, ''), '@', '@' || chr(8203)), '([*_`~|>\\])', '\\\1', 'g');
$$;

-- ------------------------------------------------------------ Spiele
CREATE OR REPLACE FUNCTION private._trg_discord_lobby()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_players text;
  v_humans int;
  v_bots int;
  v_rank text;
  v_winner text;
  v_minutes int;
BEGIN
  IF NEW.phase IS NOT DISTINCT FROM OLD.phase THEN RETURN NEW; END IF;

  -- Spiel gestartet (erster Durchgang eines Matches)
  IF NEW.phase = 'running' AND OLD.phase = 'countdown' AND coalesce(NEW.series_index, 1) = 1 THEN
    SELECT string_agg(CASE WHEN p.is_bot THEN '🤖 ' ELSE '👤 ' END || private.dc_safe(p.name), '  ·  ' ORDER BY p.is_bot, p.joined_at),
           count(*) FILTER (WHERE NOT p.is_bot), count(*) FILTER (WHERE p.is_bot)
      INTO v_players, v_humans, v_bots
      FROM public.players p WHERE p.lobby_id = NEW.id AND p.status = 'active';
    PERFORM private.discord_send('spiele', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
      'title', CASE WHEN v_humans <= 1 AND v_bots > 0 THEN '🤖 Solo-Spiel gestartet' ELSE '🎮 Spiel gestartet' END,
      'description', coalesce(v_players, '–'),
      'color', 3447003,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Lobby', 'value', '`' || NEW.code || '`', 'inline', true),
        jsonb_build_object('name', 'Playlist', 'value', coalesce(private.dc_safe(NEW.topic_selected), '–'), 'inline', true),
        jsonb_build_object('name', 'Runden', 'value', coalesce(NEW.series_total, 1)::text, 'inline', true),
        jsonb_build_object('name', 'Spieler', 'value', v_humans || ' Menschen, ' || v_bots || ' Bots', 'inline', true)
      ),
      'timestamp', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ))));
  END IF;

  -- Match beendet: Rangliste über alle Durchgänge
  IF NEW.phase = 'finished' THEN
    WITH t AS (
      SELECT sr.player_id, max(sr.name) AS name, bool_or(sr.is_bot) AS is_bot,
             sum(sr.arena_points) AS pts, sum(sr.song_points) AS hits
        FROM public.series_results sr WHERE sr.lobby_id = NEW.id
       GROUP BY sr.player_id
    ), r AS (
      SELECT *, row_number() OVER (ORDER BY pts DESC, hits DESC) AS rn FROM t
    )
    SELECT string_agg(
             CASE rn WHEN 1 THEN '🥇' WHEN 2 THEN '🥈' WHEN 3 THEN '🥉' ELSE rn || '.' END || ' '
             || CASE WHEN is_bot THEN '🤖 ' ELSE '' END || '**' || private.dc_safe(name) || '** – ' || pts || ' Pkt'
             || CASE WHEN hits > 0 THEN ' · ♪ ' || rtrim(rtrim(to_char(hits, 'FM999990.0'), '0'), '.') ELSE '' END,
             E'\n' ORDER BY rn),
           max(CASE WHEN rn = 1 THEN private.dc_safe(name) END)
      INTO v_rank, v_winner
      FROM r WHERE rn <= 8;
    v_minutes := greatest(1, round(extract(epoch FROM (now() - coalesce(NEW.run_started_at, NEW.created_at))) / 60.0)::int);
    IF v_rank IS NOT NULL THEN
      PERFORM private.discord_send('spiele', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
        'title', '🏆 ' || coalesce(v_winner, '?') || ' gewinnt!',
        'description', v_rank,
        'color', 16766720,
        'fields', jsonb_build_array(
          jsonb_build_object('name', 'Lobby', 'value', '`' || NEW.code || '`', 'inline', true),
          jsonb_build_object('name', 'Dauer', 'value', '~' || v_minutes || ' Min', 'inline', true),
          jsonb_build_object('name', 'Playlist', 'value', coalesce(private.dc_safe(NEW.topic_selected), '–'), 'inline', true)
        ),
        'timestamp', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      ))));
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;  -- Logs dürfen nie ein Spiel blockieren
END;
$$;

DROP TRIGGER IF EXISTS lobbies_discord_log ON public.lobbies;
CREATE TRIGGER lobbies_discord_log AFTER UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION private._trg_discord_lobby();

-- ------------------------------------------------------------ Konten + Admin-Protokoll
CREATE OR REPLACE FUNCTION private._trg_discord_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_label text;
  v_who text := coalesce(private.dc_safe(NEW.actor_name), 'System');
  v_target text := coalesce(private.dc_safe(NEW.target_label), '–');
BEGIN
  IF NEW.action = 'account_created' THEN
    PERFORM private.discord_send('konten', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
      'title', '👋 Neues Konto', 'description', '**' || v_target || '** ist dabei!', 'color', 5763719,
      'timestamp', to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
    RETURN NEW;
  END IF;
  IF NEW.action IN ('account_deleted', 'deleted', 'deletion_requested') THEN
    PERFORM private.discord_send('konten', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
      'title', CASE WHEN NEW.action = 'deletion_requested' THEN '🗑️ Löschung beantragt' ELSE '❌ Konto gelöscht' END,
      'description', '**' || v_target || '**', 'color', 15548997,
      'timestamp', to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  END IF;

  -- Kleinkram, den Spieler selbst ändern, nicht melden
  IF NEW.action IN ('preferences_changed', 'avatar_changed', 'display_name_changed', 'lobbies_expired', 'account_created') THEN
    RETURN NEW;
  END IF;

  v_label := CASE NEW.action
    WHEN 'suspended' THEN '⛔ gesperrt' WHEN 'unsuspended' THEN '✅ entsperrt'
    WHEN 'deletion_requested' THEN '🗑️ Löschung beantragt' WHEN 'deletion_rejected' THEN '↩️ Löschantrag abgelehnt'
    WHEN 'deleted' THEN '❌ endgültig gelöscht' WHEN 'account_deleted' THEN '❌ Konto gelöscht'
    WHEN 'role_changed' THEN '🛡️ Rolle geändert' WHEN 'profile_moderated' THEN '✏️ Profil bearbeitet'
    WHEN 'password_reset_sent' THEN '🔑 Passwort-Reset gesendet' WHEN 'password_changed' THEN '🔐 Passwort geändert'
    WHEN 'lobby_closed' THEN '🚪 Lobby geschlossen' WHEN 'player_kicked' THEN '👢 Spieler gekickt'
    WHEN 'song_archived' THEN '📦 Song archiviert' WHEN 'song_restored' THEN '♻️ Song zurückgeholt'
    WHEN 'username_changed' THEN '✏️ Benutzername geändert' WHEN 'email_changed' THEN '📧 E-Mail geändert'
    WHEN 'status_changed' THEN '🚦 Status geändert' WHEN 'platform_admin_changed' THEN '🛡️ Plattform-Admin geändert'
    WHEN 'songs_added' THEN '➕ Songs hinzugefügt' WHEN 'songs_removed' THEN '➖ Songs entfernt'
    WHEN 'songs_changed' THEN '🎵 Songs geändert' WHEN 'playlist_changed' THEN '📀 Playlist geändert'
    ELSE '📝 ' || NEW.action END;

  PERFORM private.discord_send('admin', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
    'title', v_label,
    'description', 'Betrifft: **' || v_target || '**' || E'\n' || 'Von: ' || v_who,
    'color', 10181046,
    'timestamp', to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS admin_audit_discord_log ON public.admin_audit;
CREATE TRIGGER admin_audit_discord_log AFTER INSERT ON public.admin_audit
  FOR EACH ROW EXECUTE FUNCTION private._trg_discord_audit();

-- ------------------------------------------------------------ Tagesbericht
CREATE OR REPLACE FUNCTION private.discord_daily_report()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_matches int; v_solo int; v_humans int; v_accounts int; v_top text;
BEGIN
  SELECT count(DISTINCT lobby_id) INTO v_matches FROM public.series_results WHERE created_at > now() - interval '24 hours';
  SELECT count(*) INTO v_solo FROM (
    SELECT lobby_id FROM public.series_results WHERE created_at > now() - interval '24 hours'
    GROUP BY lobby_id HAVING count(*) FILTER (WHERE NOT is_bot) <= 1) s;
  -- Namen statt Spieler-Zeilen: Lobbys (und ihre Spieler) werden nach dem Spiel aufgeräumt
  SELECT count(DISTINCT lower(name)) INTO v_humans
    FROM public.series_results WHERE created_at > now() - interval '24 hours' AND NOT is_bot;
  SELECT count(*) INTO v_accounts FROM public.admin_audit WHERE action = 'account_created' AND created_at > now() - interval '24 hours';
  SELECT string_agg('**' || private.dc_safe(name) || '** – ' || wins || ' Sieg' || CASE WHEN wins = 1 THEN '' ELSE 'e' END, E'\n')
    INTO v_top FROM (
      SELECT name, count(*) AS wins FROM public.series_results
       WHERE created_at > now() - interval '24 hours' AND place = 1 AND NOT is_bot
       GROUP BY name ORDER BY count(*) DESC LIMIT 3) w;

  PERFORM private.discord_send('bericht', jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
    'title', '📊 Tagesbericht',
    'color', 16750615,
    'fields', jsonb_build_array(
      jsonb_build_object('name', 'Matches', 'value', v_matches || ' (davon ' || v_solo || ' Solo)', 'inline', true),
      jsonb_build_object('name', 'Spieler', 'value', v_humans::text, 'inline', true),
      jsonb_build_object('name', 'Neue Konten', 'value', v_accounts::text, 'inline', true),
      jsonb_build_object('name', 'Meiste Siege (Menschen)', 'value', coalesce(v_top, '–'), 'inline', false)
    ),
    'timestamp', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ))));
END;
$$;
REVOKE ALL ON FUNCTION private.discord_daily_report() FROM PUBLIC, anon, authenticated;

-- 21:00 UTC = 23:00 Sommerzeit / 22:00 Winterzeit
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kumpir-discord-daily';
SELECT cron.schedule('kumpir-discord-daily', '0 21 * * *', 'select private.discord_daily_report()');

COMMIT;
