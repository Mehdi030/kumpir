-- ============================================================
-- 083: Protokoll ohne Ausnahmen
-- ============================================================
-- Bisher stand im Protokoll (admin_audit) nur, was über Admin-Panel-Funktionen lief.
-- Jetzt hängt die Protokollierung an den Tabellen selbst – egal ob Admin-Panel, Einstellungen
-- eines Spielers, Skript oder SQL: Konto angelegt/gelöscht, Benutzername, Anzeigename, Avatar,
-- Einstellungen, E-Mail, Passwort, Rolle, Sperre, Songs, Playlists, abgelaufene Lobbys.
--
-- Doppelte Einträge werden vermieden: Aktionen, die schon eine Admin-Funktion mit Namen
-- festhält (auth.uid() gesetzt und ≠ betroffenes Konto), protokolliert der Trigger nicht noch einmal.
-- Das Protokoll selbst ist manipulationssicher (kein UPDATE/DELETE/TRUNCATE, außer mit Wartungs-Schalter).
-- Spielzüge einzelner Runden gehören nicht hierher (die stehen im Spielprotokoll game_events).
-- ============================================================

BEGIN;

ALTER TABLE public.admin_audit ADD COLUMN IF NOT EXISTS txid bigint;
CREATE INDEX IF NOT EXISTS admin_audit_tx_idx ON public.admin_audit (txid, action) WHERE txid IS NOT NULL;

-- ---------- Schreiben (nie das Hauptgeschehen stören) ----------
CREATE OR REPLACE FUNCTION public._audit_write(p_action text, p_target uuid, p_label text, p_details jsonb DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  insert into public.admin_audit (actor_id, actor_name, action, target_id, target_label, details, txid)
  values (v_uid, (select coalesce(username, email) from public.profiles where id = v_uid),
          p_action, p_target, p_label, p_details, txid_current());
exception when others then
  raise warning 'audit: %', sqlerrm;
end;
$function$;

-- Sammel-Eintrag: viele gleichartige Änderungen in EINER Transaktion (z. B. 240 neue Songs) = ein Eintrag mit Anzahl
CREATE OR REPLACE FUNCTION public._audit_bump(p_action text, p_playlist text, p_sample text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  r record;
  d jsonb;
  pl jsonb;
  smp jsonb;
begin
  select id, details into r from public.admin_audit
  where txid = txid_current() and action = p_action and coalesce(actor_id, '00000000-0000-0000-0000-000000000000') = coalesce(v_uid, '00000000-0000-0000-0000-000000000000')
  order by id desc limit 1;
  if found then
    d := coalesce(r.details, '{}'::jsonb);
    pl := coalesce(d -> 'playlists', '{}'::jsonb);
    pl := jsonb_set(pl, array[coalesce(p_playlist, '?')], to_jsonb(coalesce((pl ->> coalesce(p_playlist, '?'))::int, 0) + 1));
    smp := coalesce(d -> 'sample', '[]'::jsonb);
    if jsonb_array_length(smp) < 5 and p_sample is not null then smp := smp || to_jsonb(p_sample); end if;
    d := jsonb_build_object('count', coalesce((d ->> 'count')::int, 0) + 1, 'playlists', pl, 'sample', smp);
    perform set_config('kumpir.audit_maint', '1', true);
    update public.admin_audit set details = d where id = r.id;
    perform set_config('kumpir.audit_maint', '', true);
  else
    perform public._audit_write(p_action, null, null,
      jsonb_build_object('count', 1, 'playlists', jsonb_build_object(coalesce(p_playlist, '?'), 1),
                         'sample', case when p_sample is null then '[]'::jsonb else jsonb_build_array(p_sample) end));
  end if;
exception when others then
  perform set_config('kumpir.audit_maint', '', true);
  raise warning 'audit_bump: %', sqlerrm;
end;
$function$;

-- ---------- Manipulationsschutz ----------
CREATE OR REPLACE FUNCTION public._audit_immutable()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if coalesce(current_setting('kumpir.audit_maint', true), '') = '1' then
    return coalesce(NEW, OLD);
  end if;
  raise exception 'audit_immutable';
end;
$function$;
DROP TRIGGER IF EXISTS admin_audit_immutable ON public.admin_audit;
CREATE TRIGGER admin_audit_immutable BEFORE UPDATE OR DELETE ON public.admin_audit
  FOR EACH ROW EXECUTE FUNCTION public._audit_immutable();
DROP TRIGGER IF EXISTS admin_audit_no_truncate ON public.admin_audit;
CREATE TRIGGER admin_audit_no_truncate BEFORE TRUNCATE ON public.admin_audit
  FOR EACH STATEMENT EXECUTE FUNCTION public._audit_immutable();

-- ---------- Konten (profiles) ----------
CREATE OR REPLACE FUNCTION public._trg_audit_profile()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_other boolean;   -- jemand anderes (Admin-Funktion) ändert das Konto: die Funktion protokolliert selbst
  k text;
  keys text[] := '{}';
begin
  begin
    if TG_OP = 'INSERT' then
      perform public._audit_write('account_created', NEW.id, NEW.username,
        jsonb_build_object('email', NEW.email, 'role', NEW.role));
      return NEW;
    end if;

    if TG_OP = 'DELETE' then
      if v_uid is null then  -- über Admin-Funktion gelöscht = dort schon protokolliert
        perform public._audit_write('account_deleted', OLD.id, OLD.username,
          jsonb_build_object('email', OLD.email, 'role', OLD.role, 'status', OLD.status));
      end if;
      return OLD;
    end if;

    v_other := v_uid is not null and v_uid <> NEW.id;

    if not v_other then
      if NEW.username is distinct from OLD.username then
        perform public._audit_write('username_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.username, 'to', NEW.username));
      end if;
      if NEW.display_name is distinct from OLD.display_name then
        perform public._audit_write('display_name_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.display_name, 'to', NEW.display_name));
      end if;
      if NEW.avatar_emoji is distinct from OLD.avatar_emoji or NEW.avatar_color is distinct from OLD.avatar_color then
        perform public._audit_write('avatar_changed', NEW.id, NEW.username,
          jsonb_build_object('from', concat_ws(' ', OLD.avatar_emoji, OLD.avatar_color), 'to', concat_ws(' ', NEW.avatar_emoji, NEW.avatar_color)));
      end if;
      if NEW.preferences is distinct from OLD.preferences then
        for k in select distinct key from (
          select key from jsonb_each(coalesce(OLD.preferences, '{}'::jsonb)) o
            where coalesce(NEW.preferences, '{}'::jsonb) -> o.key is distinct from o.value
          union
          select key from jsonb_each(coalesce(NEW.preferences, '{}'::jsonb)) n
            where coalesce(OLD.preferences, '{}'::jsonb) -> n.key is distinct from n.value
        ) x loop keys := keys || k; end loop;
        perform public._audit_write('preferences_changed', NEW.id, NEW.username, jsonb_build_object('bereiche', to_jsonb(keys)));
      end if;
    end if;

    if NEW.email is distinct from OLD.email then
      perform public._audit_write('email_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.email, 'to', NEW.email));
    end if;
    if NEW.is_platform_admin is distinct from OLD.is_platform_admin then
      perform public._audit_write('platform_admin_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.is_platform_admin, 'to', NEW.is_platform_admin));
    end if;
    -- Rolle/Status: über Admin-Funktion/Löschantrag (auth.uid() gesetzt) steht es dort schon mit Namen im Protokoll;
    -- hier die Änderungen per Skript/SQL (z. B. restore-admin.mjs)
    if v_uid is null then
      if NEW.role is distinct from OLD.role then
        perform public._audit_write('role_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.role, 'to', NEW.role, 'via', 'Datenbank/Skript'));
      end if;
      if NEW.status is distinct from OLD.status then
        perform public._audit_write('status_changed', NEW.id, NEW.username, jsonb_build_object('from', OLD.status, 'to', NEW.status, 'via', 'Datenbank/Skript'));
      end if;
    end if;
  exception when others then
    raise warning 'audit profile: %', sqlerrm;
  end;
  return coalesce(NEW, OLD);
end;
$function$;

DROP TRIGGER IF EXISTS profiles_audit_ins ON public.profiles;
CREATE TRIGGER profiles_audit_ins AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public._trg_audit_profile();
DROP TRIGGER IF EXISTS profiles_audit_upd ON public.profiles;
CREATE TRIGGER profiles_audit_upd AFTER UPDATE ON public.profiles FOR EACH ROW
  WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION public._trg_audit_profile();
DROP TRIGGER IF EXISTS profiles_audit_del ON public.profiles;
CREATE TRIGGER profiles_audit_del AFTER DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public._trg_audit_profile();

-- ---------- Passwort (auth.users) ----------
CREATE OR REPLACE FUNCTION public._trg_audit_password()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  begin
    if NEW.encrypted_password is distinct from OLD.encrypted_password then
      perform public._audit_write('password_changed', NEW.id, (select username from public.profiles where id = NEW.id), null);
    end if;
  exception when others then
    raise warning 'audit password: %', sqlerrm;
  end;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS auth_users_audit_password ON auth.users;
CREATE TRIGGER auth_users_audit_password AFTER UPDATE OF encrypted_password ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public._trg_audit_password();

-- ---------- Songs ----------
CREATE OR REPLACE FUNCTION public._trg_audit_song()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_pl text;
  v_row record;
begin
  begin
    v_row := case when TG_OP = 'DELETE' then OLD else NEW end;
    select text into v_pl from public.topic_pool where id = v_row.topic_pool_id;
    if TG_OP = 'INSERT' then
      perform public._audit_bump('songs_added', v_pl, NEW.artist || ' – ' || NEW.title);
    elsif TG_OP = 'DELETE' then
      perform public._audit_bump('songs_removed', v_pl, OLD.artist || ' – ' || OLD.title);
    elsif auth.uid() is null then
      -- Archivieren/Zurückholen über das Admin-Panel steht dort schon mit Namen im Protokoll
      perform public._audit_bump('songs_changed', v_pl, NEW.artist || ' – ' || NEW.title);
    end if;
  exception when others then
    raise warning 'audit song: %', sqlerrm;
  end;
  return coalesce(NEW, OLD);
end;
$function$;
DROP TRIGGER IF EXISTS song_pool_audit_ins ON public.song_pool;
CREATE TRIGGER song_pool_audit_ins AFTER INSERT ON public.song_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_song();
DROP TRIGGER IF EXISTS song_pool_audit_del ON public.song_pool;
CREATE TRIGGER song_pool_audit_del AFTER DELETE ON public.song_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_song();
-- Nur echte Inhaltsänderungen (nicht die Zähler plays/hits, die bei jedem Spiel hochlaufen)
DROP TRIGGER IF EXISTS song_pool_audit_upd ON public.song_pool;
CREATE TRIGGER song_pool_audit_upd AFTER UPDATE OF topic_pool_id, title, artist, preview_url ON public.song_pool FOR EACH ROW
  WHEN (OLD.topic_pool_id IS DISTINCT FROM NEW.topic_pool_id OR OLD.title IS DISTINCT FROM NEW.title
        OR OLD.artist IS DISTINCT FROM NEW.artist OR OLD.preview_url IS DISTINCT FROM NEW.preview_url)
  EXECUTE FUNCTION public._trg_audit_song();

-- ---------- Playlists / Themen ----------
CREATE OR REPLACE FUNCTION public._trg_audit_playlist()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  begin
    if TG_OP = 'INSERT' then
      perform public._audit_write('playlist_changed', null, NEW.text, jsonb_build_object('aktion', 'angelegt', 'aktiv', NEW.active));
    elsif TG_OP = 'DELETE' then
      perform public._audit_write('playlist_changed', null, OLD.text, jsonb_build_object('aktion', 'gelöscht'));
    else
      perform public._audit_write('playlist_changed', null, NEW.text,
        jsonb_build_object('aktion', 'geändert', 'from', jsonb_build_object('name', OLD.text, 'aktiv', OLD.active),
                           'to', jsonb_build_object('name', NEW.text, 'aktiv', NEW.active)));
    end if;
  exception when others then
    raise warning 'audit playlist: %', sqlerrm;
  end;
  return coalesce(NEW, OLD);
end;
$function$;
DROP TRIGGER IF EXISTS topic_pool_audit_ins ON public.topic_pool;
CREATE TRIGGER topic_pool_audit_ins AFTER INSERT ON public.topic_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_playlist();
DROP TRIGGER IF EXISTS topic_pool_audit_del ON public.topic_pool;
CREATE TRIGGER topic_pool_audit_del AFTER DELETE ON public.topic_pool FOR EACH ROW EXECUTE FUNCTION public._trg_audit_playlist();
DROP TRIGGER IF EXISTS topic_pool_audit_upd ON public.topic_pool;
CREATE TRIGGER topic_pool_audit_upd AFTER UPDATE OF text, active ON public.topic_pool FOR EACH ROW
  WHEN (OLD.text IS DISTINCT FROM NEW.text OR OLD.active IS DISTINCT FROM NEW.active)
  EXECUTE FUNCTION public._trg_audit_playlist();

-- ---------- Abgelaufene Lobbys (Aufräum-Aufgabe alle 10 Minuten) ----------
CREATE OR REPLACE FUNCTION public.cleanup_expired_lobbies()
 RETURNS void LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare n int;
begin
  delete from public.lobbies where last_activity_at < now() - interval '60 minutes';
  get diagnostics n = row_count;
  if n > 0 then
    perform public._audit_write('lobbies_expired', null, n || ' Lobby(s) nach 60 Min. ohne Aktivität', jsonb_build_object('count', n));
  end if;
end;
$function$;

-- ---------- Protokoll lesen: bis zu 2000 Einträge, mit Zeitstempel ----------
CREATE OR REPLACE FUNCTION public.admin_list_audit(p_limit integer DEFAULT 100)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  perform public._require_staff('supporter');
  return jsonb_build_object(
    'total', (select count(*) from public.admin_audit),
    'rows', coalesce((
      select jsonb_agg(a order by a."createdAt" desc, a.id desc) from (
        select id, created_at as "createdAt", actor_name as "actorName", action, target_id as "targetId", target_label as "targetLabel", details
        from public.admin_audit order by created_at desc, id desc limit greatest(1, least(coalesce(p_limit, 100), 2000))
      ) a
    ), '[]'::jsonb)
  );
end;
$function$;

-- Hilfsfunktionen sind intern
REVOKE ALL ON FUNCTION public._audit_write(text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._audit_bump(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._audit_immutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_profile() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_password() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_song() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_audit_playlist() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cleanup_expired_lobbies() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_list_audit(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_audit(integer) TO authenticated;

COMMIT;
