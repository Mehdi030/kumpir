-- ============================================================
-- Migration 066: faires Themen-Voting (2 Themen + Zufalls-Karte)
-- ============================================================
-- Karte 1 + 2 sind benannte Themen, Karte 3 ist immer "Zufall".
-- Gewinnt/steht die Zufalls-Karte, wird ein Thema aus ALLEN übrigen
-- Playlists (ohne die beiden angezeigten) gewichtet gezogen.
--
-- Balancing:
--   * Themen, die in diesem Match noch NICHT dran waren, haben dreifaches
--     Gewicht (Auswahl der Karten + Zufalls-Karte).
--   * Gleichstand beim Voting: Optionen mit frischem (noch nicht gespieltes)
--     Thema gewinnen vor bereits gespielten; bleibt ein Gleichstand, entscheidet
--     das Los.
--   * Das Thema des vorherigen Durchgangs wird bei den Karten gemieden.
--   * Startspieler der Runde: wer in diesem Match schon öfter starten
--     musste, wird seltener gezogen.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_topics text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS series_starters uuid[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    NEW.series_topics := '{}';
    NEW.series_starters := '{}';
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  return NEW;
end;
$function$;

-- Alle wählbaren Themen der Lobby (Musik-Filter beachtet)
CREATE OR REPLACE FUNCTION public._vote_topic_pool(p_filter text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(t.text), '{}')
  from public.topic_pool t
  where t.active is true and (p_filter is null or t.text = any(p_filter));
$function$;

-- Gewichtete Ziehung: noch nicht gespielte Themen zählen dreifach.
CREATE OR REPLACE FUNCTION public._weighted_topic(p_cands text[], p_played text[])
 RETURNS text
 LANGUAGE sql
 VOLATILE
 SET search_path TO 'public'
AS $function$
  select c
  from unnest(coalesce(p_cands, '{}')) as c
  order by -ln(greatest(random(), 1e-12)) / (case when c = any(coalesce(p_played, '{}')) then 1.0 else 3.0 end)
  limit 1;
$function$;

-- Zwei Karten-Themen ziehen (A, B). topic_c bleibt NULL = Zufalls-Karte.
CREATE OR REPLACE FUNCTION public._pick_vote_topics(p_lobby_id uuid, OUT o_a text, OUT o_b text)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_filter text[]; v_played text[]; v_prev text; v_all text[];
begin
  select topic_filter, series_topics, topic_selected into v_filter, v_played, v_prev
  from public.lobbies where id = p_lobby_id;

  v_all := public._vote_topic_pool(v_filter);
  if coalesce(array_length(v_all, 1), 0) = 0 then raise exception 'Nicht genug Themen im topic_pool'; end if;

  -- A: gewichtet, möglichst nicht das Thema der letzten Runde
  o_a := public._weighted_topic(array(select x from unnest(v_all) x where x is distinct from v_prev), v_played);
  if o_a is null then o_a := public._weighted_topic(v_all, v_played); end if;

  o_b := public._weighted_topic(array(select x from unnest(v_all) x where x <> o_a), v_played);
  if o_b is null then o_b := o_a; end if;
end;
$function$;

-- ------------------------------------------------------------
-- Voting starten (Host)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text;
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id into v_host from public.lobbies where id = p_lobby_id for update;
  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(p_lobby_id);

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;

-- ------------------------------------------------------------
-- Rematch: neues Voting
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_active_count int; v_a text; v_b text;
begin
  select id into v_lobby_id from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';
  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(v_lobby_id);

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id and phase = 'rematch_wait';
end;
$function$;

-- ------------------------------------------------------------
-- Nächste Runde des Matches: neues Voting
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_start_next_set(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_phase text; v_ends timestamptz; v_a text; v_b text;
begin
  select id, phase, countdown_ends_at into v_lobby_id, v_phase, v_ends
  from public.lobbies where code = upper(trim(p_code)) for update;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'set_summary' then return; end if;
  if v_ends is not null and v_ends > now() + interval '1 second' then return; end if;

  select o_a, o_b into v_a, v_b from public._pick_vote_topics(v_lobby_id);

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, slowest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null, eliminated_at_round = null,
      song_points = 0
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      series_index = series_index + 1,
      round_number = 1, pass_direction = 1,
      topic_a = v_a, topic_b = v_b, topic_c = null, topic_selected = null,
      topic_vote_started_at = now(), topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_loser_player_id = null, current_attempt_id = null, used_answers = '{}',
      last_activity_at = now()
  where id = v_lobby_id and phase = 'set_summary';
end;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_start_next_set(text) TO anon, authenticated;

-- ------------------------------------------------------------
-- Voting auswerten
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a text; v_b text; v_filter text[]; v_played text[]; v_starters uuid[];
  v_cnt int[] := array[0, 0, 0];
  v_best int; v_tied int[] := '{}'; v_fresh int[] := '{}';
  v_pick int; v_selected text; v_choices int[]; v_starter uuid;
  v_rest text[]; i int; v_n int;
begin
  select topic_a, topic_b, topic_filter, series_topics, series_starters
    into v_a, v_b, v_filter, v_played, v_starters
  from public.lobbies where id = p_lobby_id and phase = 'topic_vote' for update;
  if not found then return; end if;

  if v_a is null then v_a := 'Thema A'; end if;
  if v_b is null then v_b := 'Thema B'; end if;

  for i in 1..3 loop
    select count(*) into v_n from public.topic_votes where lobby_id = p_lobby_id and choice = i;
    v_cnt[i] := v_n;
  end loop;

  v_best := greatest(v_cnt[1], v_cnt[2], v_cnt[3]);
  for i in 1..3 loop
    if v_cnt[i] = v_best then v_tied := array_append(v_tied, i); end if;
  end loop;

  -- Zufalls-Karte: Themen außerhalb der beiden Karten (gibt es keine, bleibt A/B)
  v_rest := array(select x from unnest(public._vote_topic_pool(v_filter)) x where x <> v_a and x <> v_b);

  if array_length(v_tied, 1) = 1 then
    v_pick := v_tied[1];
    v_choices := null;
  else
    -- Gleichstand: bevorzugt Optionen mit noch nicht gespieltem Thema
    foreach i in array v_tied loop
      if (i = 1 and not (v_a = any(v_played)))
         or (i = 2 and not (v_b = any(v_played)))
         or (i = 3 and (array_length(v_rest, 1) is null or exists (select 1 from unnest(v_rest) r where not (r = any(v_played)))))
      then v_fresh := array_append(v_fresh, i); end if;
    end loop;
    if array_length(v_fresh, 1) is null then v_fresh := v_tied; end if;
    v_pick := v_fresh[1 + floor(random() * array_length(v_fresh, 1))::int];
    v_choices := v_tied;
  end if;

  if v_pick = 1 then v_selected := v_a;
  elsif v_pick = 2 then v_selected := v_b;
  else
    v_selected := public._weighted_topic(v_rest, v_played);
    if v_selected is null then
      v_selected := public._weighted_topic(array[v_a, v_b], v_played);
    end if;
  end if;

  -- Startspieler: wer in diesem Match schon öfter gestartet hat, wird seltener gezogen
  select p.player_id into v_starter
  from public.players p
  where p.lobby_id = p_lobby_id and p.status = 'active' and p.is_alive = true
  order by -ln(greatest(random(), 1e-12)) * (1 + (select count(*) from unnest(v_starters) s where s = p.player_id))
  limit 1;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      series_topics = array_append(series_topics, v_selected),
      series_starters = case when v_starter is null then series_starters else array_append(series_starters, v_starter) end,
      countdown_starter_player_id = v_starter,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

COMMIT;
