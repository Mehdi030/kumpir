-- ============================================================
-- Migration 058: Lücken in der Antwort-Prüfung schließen
-- ============================================================
-- Gefunden beim Multi-Bot-Checkup:
--  1) Fuzzy-Schwelle war für kurze Titel zu großzügig: bei einem Titel wie
--     "Love" (4 Zeichen) galt "Live"/"Lose"/"Move" (je 1 Fehler) als
--     richtig. Jetzt: bis 4 Zeichen exakt, 5-8 -> 1 Fehler, 9-14 -> 2,
--     darüber 3.
--  2) Antworten NACH Ablauf des Timers (explode_at, +0.5s Toleranz für
--     Netzwerk-Latenz) wurden noch angenommen und verlängerten die Runde
--     über das Bonus-Zeit-Verfahren -- wer die Antwort knapp nach 0 absendet,
--     bevor der Tick feuert, konnte so der Explosion entkommen. Jetzt
--     'time_up'.
--  3) Song-Modus blockierte Antworten über used_answers quer über Songs
--     hinweg: derselbe Interpret ("Eminem") war nach dem ersten Treffer für
--     jeden weiteren Eminem-Song gesperrt (answer_already_used). Im Song-
--     Modus entfällt die Duplikat-Sperre, jeder Song wird einzeln geprüft.
--  4) Unbegrenztes Durchprobieren: nach einer falschen Song-Antwort ist
--     für denselben Spieler 1s Pause (Spalte last_wrong_guess_at, bewusst
--     OHNE SELECT-Grant -- nur die SECURITY-DEFINER-RPC liest sie).
-- ============================================================

BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS last_wrong_guess_at timestamptz;

CREATE OR REPLACE FUNCTION public._fuzzy_song_match(p_candidate text, p_answer text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_a text := lower(trim(p_candidate));
  v_b text := lower(trim(p_answer));
  v_a_clean text;
  v_len int;
  v_threshold int;
begin
  if v_a = '' or v_b = '' then return false; end if;
  if v_a = v_b then return true; end if;

  v_a_clean := regexp_replace(v_a, '\s*\(.*?\)\s*', '', 'g');
  if v_a_clean = '' then return false; end if;
  if v_a_clean = v_b then return true; end if;

  v_len := length(v_a_clean);
  v_threshold := case
    when v_len <= 4 then 0
    when v_len <= 8 then 1
    when v_len <= 14 then 2
    else 3
  end;
  if v_threshold = 0 then return false; end if;
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
  v_last_wrong timestamptz;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at into v_last_wrong
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist into v_song_title, v_song_artist
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := 0;
    v_known := false;

    if public._fuzzy_song_match(v_song_title, v_clean) then
      v_points := 1;
      v_known := true;
    elsif exists (
      select 1
      from unnest(regexp_split_to_array(coalesce(v_song_artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
      where public._fuzzy_song_match(a.name, v_clean)
    ) then
      v_points := 0.5;
      v_known := true;
    end if;

    if not v_known then
      update public.players set last_wrong_guess_at = now()
      where lobby_id = v_lobby.id and player_id = p_player_id;
      -- Fehlerzustand soll das UPDATE oben nicht zurückrollen: Postgres
      -- rollt bei RAISE die ganze Funktion zurück, daher wird die Sperre
      -- hier bewusst per Rückgabe-Sentinel statt Exception gesetzt.
      return null;
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

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

COMMIT;
