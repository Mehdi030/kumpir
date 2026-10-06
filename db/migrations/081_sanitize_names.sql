-- ============================================================
-- Migration 081: Spielernamen und Lobby-Themen säubern (Schutz in der Tiefe)
-- ============================================================
-- React zeigt Namen bereits sicher an (kein HTML-Rendering). Damit aber auch künftige
-- Ausgabewege (Bilder, Mails, Admin-Exporte …) nie HTML/Steuerzeichen aus Nutzereingaben
-- bekommen, werden < > " ` \ und Steuerzeichen schon beim Speichern entfernt.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._clean_text(p text, p_max integer)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public'
AS $function$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[<>"`\\]', '', 'g'), '[[:cntrl:]]', '', 'g')), p_max);
$function$;
REVOKE ALL ON FUNCTION public._clean_text(text, integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._trg_clean_player_name()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
begin
  NEW.name := public._clean_text(NEW.name, 24);
  if NEW.name = '' then NEW.name := 'Spieler'; end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS players_clean_name ON public.players;
CREATE TRIGGER players_clean_name BEFORE INSERT OR UPDATE OF name ON public.players
  FOR EACH ROW EXECUTE FUNCTION public._trg_clean_player_name();

CREATE OR REPLACE FUNCTION public._trg_clean_lobby_topic()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
begin
  if NEW.topic is not null then NEW.topic := nullif(public._clean_text(NEW.topic, 60), ''); end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS lobbies_clean_topic ON public.lobbies;
CREATE TRIGGER lobbies_clean_topic BEFORE INSERT OR UPDATE OF topic ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_clean_lobby_topic();

-- Bestehende Namen einmalig säubern
UPDATE public.players SET name = name WHERE name ~ '[<>"`\\[:cntrl:]]';

COMMIT;
