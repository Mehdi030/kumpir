-- ============================================================
-- Migration 055: Song-Antworten wieder geprüft (fuzzy), Punkte-System
-- ============================================================
-- Migration 046 hat JEDE Antwort ausnahmslos akzeptiert. Für den
-- Song-Modus (der jetzt durch Migration "Musik läuft immer" in praktisch
-- jeder Runde aktiv ist) soll das differenzierter sein:
--   - Songtitel korrekt (tippfehlertolerant, Groß-/Kleinschreibung egal)
--     -> akzeptiert, 1 Punkt.
--   - Interpret korrekt (einfachere Alternative, falls man den Titel
--     nicht weiß) -> akzeptiert, 0.5 Punkte.
--   - Sonst -> abgelehnt (raise 'answer_incorrect'), der Halter darf es
--     sofort nochmal versuchen (kein Attempt wird angelegt, used_answers
--     bleibt unberührt).
-- Tippfehlertoleranz über levenshtein() (fuzzystrmatch): Schwelle skaliert
-- mit der Titellänge (1 Fehler pro 5 Zeichen, mind. 1), deckt z.B.
-- "Liebe" vs "Liebe+" oder einen vertauschten Buchstaben ab, ohne bei
-- komplett falschen Antworten durchzuwinken.
--
-- Themen OHNE Song (current_song_id null) bleiben unverändert beim
-- Migration-046-Verhalten: jede Antwort wird sofort akzeptiert.
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS song_points numeric NOT NULL DEFAULT 0;
GRANT SELECT ON public.players TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._fuzzy_song_match(p_candidate text, p_answer text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_a text := lower(trim(p_candidate));
  v_b text := lower(trim(p_answer));
  v_a_clean text;
  v_threshold int;
begin
  if v_a = '' or v_b = '' then return false; end if;
  if v_a = v_b then return true; end if;

  -- Klammer-Zusätze wie "(feat. ...)" tolerieren, exakt wie bisher.
  v_a_clean := regexp_replace(v_a, '\s*\(.*?\)\s*', '', 'g');
  if v_a_clean = v_b then return true; end if;

  v_threshold := greatest(1, floor(length(v_a_clean) / 5.0)::int);
  return levenshtein(v_a_clean, v_b) <= v_threshold;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_points numeric;
  v_known boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  -- Song-Modus: Titel (1 Punkt) oder Interpret (0.5 Punkte) müssen
  -- tatsächlich passen -- tippfehlertolerant, aber keine Blanko-Annahme
  -- mehr. Falsche Antworten werden abgelehnt, OHNE einen Attempt/Used-
  -- Answers-Eintrag anzulegen, damit sofort ein neuer Versuch möglich ist.
  if v_lobby.current_song_id is not null then
    select title, artist into v_song_title, v_song_artist
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    else
      if exists (
        select 1
        from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
        where public._fuzzy_song_match(a.name, v_clean)
      ) then
        v_points := 0.5;
        v_known := true;
      end if;
    end if;

    if not v_known then
      raise exception 'answer_incorrect';
    end if;

    update public.players
    set song_points = song_points + v_points
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  -- Themen ohne Song: weiterhin jede Antwort sofort annehmen (Migration
  -- 046) -- Spieler entscheiden sozial/per Host-Kick, wer rausfliegt.
  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

COMMIT;
