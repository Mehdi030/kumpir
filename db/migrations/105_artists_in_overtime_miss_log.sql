-- ============================================================
-- 105: Künstler zählen auch in der Nachspielzeit, falsche Antworten werden protokolliert (Wunsch Mehdi, 2026-10-12)
-- ============================================================
-- * rpc_attempt_pass: 'overtime_title_only' (094) entfällt – "Farid Bang" o. ä. zählt immer (½ Punkt).
-- * public.answer_misses: jede falsche Antwort eines Menschen (Lobby, Song, Spieler, Text), nur für Admins/
--   Skripte lesbar (keine Grants). Auswertung: node db/scripts/query.mjs "select ... from answer_misses".
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.answer_misses (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  lobby_id uuid,
  song_id uuid,
  player_id uuid,
  answer text NOT NULL
);
ALTER TABLE public.answer_misses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.answer_misses FROM anon, authenticated;
CREATE INDEX IF NOT EXISTS answer_misses_created_idx ON public.answer_misses (created_at DESC);

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
  v_song_feat text[];
  v_plays int; v_hits int;
  v_points numeric;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
  v_diff numeric := 1;
  v_combo int := 0;
  v_combo_bonus numeric := 0;
  v_is_bot boolean;
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
    select last_wrong_guess_at, combo, coalesce(is_bot, false) into v_last_wrong, v_combo, v_is_bot
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist, feat_artists, plays, hits into v_song_title, v_song_artist, v_song_feat, v_plays, v_hits
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := public._score_song_answer(v_song_title, v_song_artist, v_song_feat, v_clean);

    -- (105) Nachspielzeit: Künstler zählen wieder immer (Wunsch Mehdi 2026-10-12)

    if v_points = 0 then
      update public.players set last_wrong_guess_at = now(), combo = 0
      where lobby_id = v_lobby.id and player_id = p_player_id;
      -- Falsche Antwort merken (zum Nachsehen, wenn etwas "nicht erkannt" wurde)
      if not coalesce(v_is_bot, false) then
        insert into public.answer_misses (lobby_id, song_id, player_id, answer)
        values (v_lobby.id, v_lobby.current_song_id, p_player_id, left(v_clean, 60));
      end if;
      return null;
    end if;

    -- Bonuszeit-Faktor wie bisher (Titel 1 / Interpret 0.5), Titel + Künstler zählt wie Titel
    v_quality := least(v_points, 1);
    v_diff := case public._song_difficulty(v_plays, v_hits) when 1 then 0.8 when 3 then 1.3 else 1.0 end;

    if v_points >= 1 then
      v_combo := coalesce(v_combo, 0) + 1;
      v_combo_bonus := case when v_combo >= 2 then least(2, 0.5 * (v_combo - 1)) else 0 end;
      if not coalesce(v_is_bot, false) then
        update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
      end if;
    else
      v_combo := 0;
    end if;

    update public.players
    set song_points = song_points + v_points, combo = v_combo
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality,
      last_pass_diff = v_diff, last_pass_combo_bonus = v_combo_bonus
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

COMMIT;
