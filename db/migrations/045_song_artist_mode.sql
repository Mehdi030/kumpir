-- ============================================================
-- Migration 045: Zweiter Musik-Modus -- Interpret statt Songtitel
-- ============================================================
-- Bisher musste man im Song-Modus immer den TITEL des versteckten,
-- gerade laufenden Songs nennen. Neue Einstellung
-- lobbies.song_answer_mode ('title' | 'artist', Default 'title'):
-- bei 'artist' muss man stattdessen den/die Interpret(en) DIESES
-- konkreten Songs nennen -- es läuft weiterhin ein einzelner
-- versteckter Song (gleiche Fairness/Strenge wie bisher), nur die
-- erwartete Antwort ist eine andere.
--
-- song_pool.artist ist oft eine Liste ("Amo, Celo & Abdi", "50 Cent,
-- Justin Timberlake, Timbaland") -- die Prüfung splittet auf Komma/
-- "&" und akzeptiert jeden einzelnen genannten Namen für sich.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS song_answer_mode text NOT NULL DEFAULT 'title';

CREATE OR REPLACE FUNCTION public.set_lobby_song_answer_mode(p_lobby_id uuid, p_me_player_id uuid, p_song_answer_mode text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_mode text;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id;
  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  v_mode := btrim(coalesce(p_song_answer_mode, ''));
  if v_mode not in ('title', 'artist') then raise exception 'invalid_song_answer_mode'; end if;

  update public.lobbies
  set song_answer_mode = v_mode,
      settings_version = coalesce(settings_version, 0) + 1
  where id = p_lobby_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
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

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  if v_lobby.current_song_id is not null then
    if coalesce(v_lobby.song_answer_mode, 'title') = 'artist' then
      -- Interpret-Modus: jeder einzeln genannte Interpret des aktuellen
      -- Songs zählt (Feld ist oft eine Liste wie "Amo, Celo & Abdi").
      select exists (
        select 1
        from public.song_pool sp
        cross join lateral unnest(regexp_split_to_array(coalesce(sp.artist, ''), '\s*,\s*|\s*&\s*')) as a(name)
        where sp.id = v_lobby.current_song_id
          and lower(trim(a.name)) = lower(v_clean)
      ) into v_known;
    else
      -- Titel-Modus (Standard): gegen genau den einen aktuellen Song
      -- prüfen (Klammer-Zusätze wie "(feat. ...)" werden toleriert,
      -- exakte Interpreten-Schreibweise wird nicht verlangt).
      select exists (
        select 1 from public.song_pool sp
        where sp.id = v_lobby.current_song_id
          and (
            sp.lower_title = lower(v_clean)
            or regexp_replace(sp.lower_title, '\s*\(.*?\)\s*', '', 'g') = lower(v_clean)
          )
      ) into v_known;
    end if;
  else
    -- Antwort-Datenbank: bekannte, korrekte Antwort -> sofort annehmen,
    -- kein Voting nötig. _finalize_attempt_accept setzt current_attempt_id
    -- selbst wieder auf null und stößt rpc_pass_potato an.
    select exists (
      select 1
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(v_topic)
        and ta.lower_answer = lower(v_clean)
    ) into v_known;
  end if;

  if v_known then
    perform public._finalize_attempt_accept(v_attempt);
  end if;

  return v_attempt;
end;
$function$;

COMMIT;
