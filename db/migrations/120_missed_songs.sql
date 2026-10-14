-- ============================================================
-- 120: Nicht erratene Songs (Wunsch Mehdi, 2026-10-14)
-- ============================================================
-- Im Spiel stehen links in Rot die Songs, die NICHT erraten wurden (Kumpir ist explodiert, Spieler ausgeschieden
-- oder Song getauscht), rechts die erratenen (lobbies.used_answers, wie bisher).
-- Neu: lobbies.missed_songs ("Titel – Künstler", neuester zuletzt). Befüllt wird sie zentral in _pick_next_song:
-- Wird ein neuer Song gewählt und der bisherige steht NICHT in used_answers, dann wurde er nicht erraten.
-- Leeren bei jedem Phasenwechsel (Countdown/Runde/Lobby). Der alte Song vom Ende der letzten Runde zählt nicht
-- (er wurde vor dem Start der aktuellen Runde gewählt: current_song_started_at < run_started_at).
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS missed_songs text[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION public._reset_missed_on_phase()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.phase IS DISTINCT FROM OLD.phase THEN
    NEW.missed_songs := '{}';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS lobbies_reset_missed ON public.lobbies;
CREATE TRIGGER lobbies_reset_missed BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._reset_missed_on_phase();

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
  v_plays int; v_hits int; v_holder uuid; v_holder_is_bot boolean;
  v_cur_started timestamptz; v_run_started timestamptz; v_answers text[]; v_missed text[]; v_shown text;
begin
  select topic_selected, used_song_ids, current_song_id, holder_player_id,
         current_song_started_at, run_started_at, used_answers, missed_songs
    into v_topic, v_used, v_current, v_holder, v_cur_started, v_run_started, v_answers, v_missed
  from public.lobbies where id = p_lobby_id;

  -- 120: der bisherige Song wurde nicht erraten (explodiert / ausgeschieden / getauscht)?
  if v_current is not null and v_cur_started is not null and v_run_started is not null and v_cur_started >= v_run_started then
    select sp.title || ' – ' || sp.artist into v_shown from public.song_pool sp where sp.id = v_current;
    if v_shown is not null
       and not (v_shown = any (coalesce(v_answers, '{}')))
       and not (v_shown = any (coalesce(v_missed, '{}'))) then
      update public.lobbies set missed_songs = array_append(coalesce(missed_songs, '{}'), v_shown) where id = p_lobby_id;
    end if;
  end if;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null, current_song_started_at = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  if v_song_id is not null then
    -- Nur Songs, die ein MENSCH vor sich hat, zählen für die Schwierigkeits-Statistik.
    select coalesce(is_bot, false) into v_holder_is_bot
    from public.players where lobby_id = p_lobby_id and player_id = v_holder;
    if coalesce(v_holder_is_bot, false) then
      select plays, hits into v_plays, v_hits from public.song_pool where id = v_song_id;
    else
      update public.song_pool set plays = plays + 1 where id = v_song_id
      returning plays, hits into v_plays, v_hits;
    end if;
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      current_song_started_at = case when v_song_id is null then null else now() end,
      current_song_difficulty = public._song_difficulty(v_plays, v_hits),
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

COMMIT;
