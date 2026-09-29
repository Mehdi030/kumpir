-- ============================================================
-- Migration 042: Themen-Voting zeigt bei 3 verfügbaren Themen alle
-- 3 echten Themen statt Thema A / Thema B / "Zufällig"
-- ============================================================
-- Bisher: rpc_begin_topic_vote/rpc_start_rematch_if_ready zogen nur
-- ZWEI Themen (topic_a, topic_b); die dritte Voting-Karte war ein
-- generischer "Zufällig"-Button, der serverseitig einfach zufällig
-- zwischen A und B auslost (rpc_finalize_topic_vote, choice=3-Zweig).
-- Seit die Musik-Kategorien auf genau 3 (Deutschrap-Songs, 2000er Old
-- School, Shisha Club) eingedampft wurden, fiel auf: bei genau 3
-- verfügbaren Themen sollten alle 3 echt zur Wahl stehen, nicht 2 +
-- ein Zufalls-Feld.
--
-- Neue Spalte lobbies.topic_c: dritter echter Themen-Pick, NULL wenn
-- der (ggf. gefilterte) Pool keine 3 unterschiedlichen Themen hergibt
-- (dann bleibt es bei 2 echten Wahlmöglichkeiten -- kein Fake-Dritter
-- mehr). Bei nur 1 verfügbarem Thema bleiben a=b=c (wie schon vorher
-- a=b in diesem Fall, siehe Migration 030).
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS topic_c text;

CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text; v_c text; v_filter text[];
begin
  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, topic_filter into v_host, v_filter
  from public.lobbies where id = p_lobby_id for update;

  if not found then raise exception 'Lobby not found'; end if;
  if v_host is null or v_host <> p_player_id then raise exception 'Only host can start'; end if;

  select t.text into v_a from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_a is null then raise exception 'Not enough topics in topic_pool'; end if;

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_b is null then
    v_b := v_a;
    v_c := v_a;
  else
    select t.text into v_c from public.topic_pool t
    where t.active is true and t.text <> v_a and t.text <> v_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_c = v_c, topic_selected = null, topic = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '15 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      run_started_at = null, holder_player_id = null, explode_at = null,
      topic_tie_choices = null, topic_tie_pick = null
  where l.id = p_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_ready_count int; v_active_count int; v_filter text[];
  v_topic_a text; v_topic_b text; v_topic_c text;
begin
  select id, topic_filter into v_lobby_id, v_filter
  from public.lobbies where code = upper(trim(p_code)) limit 1;
  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;

  select count(*) into v_active_count from public.players
  where lobby_id = v_lobby_id and status = 'active';

  select count(*) into v_ready_count from public.players
  where lobby_id = v_lobby_id and status = 'active' and coalesce(ready, false) = true;

  if v_active_count < 2 then raise exception 'Mindestens 2 aktive Spieler nötig'; end if;
  if v_ready_count <> v_active_count then return; end if;

  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_a is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_b is null then
    v_topic_b := v_topic_a;
    v_topic_c := v_topic_a;
  else
    select t.text into v_topic_c
    from public.topic_pool t
    where t.active is true and t.text <> v_topic_a and t.text <> v_topic_b and (v_filter is null or t.text = any(v_filter))
    order by random() limit 1;
  end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_c = v_topic_c, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text; v_topic_c text;
  v_a_count int := 0; v_b_count int := 0; v_c_count int := 0;
  v_selected text; v_pick int; v_choices int[]; v_best int;
begin
  select topic_a, topic_b, topic_c into v_topic_a, v_topic_b, v_topic_c
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  -- Choice 3 zählt nur, wenn es dafür überhaupt ein echtes drittes Thema
  -- gibt -- sonst hat die UI die Karte gar nicht erst angeboten, ein
  -- Bot könnte aber trotzdem (aus alten Client-Ständen o.ä.) 3 schicken.
  if v_topic_c is not null then
    select count(*) into v_c_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;
  end if;

  v_best := greatest(v_a_count, v_b_count, v_c_count);
  v_choices := array[]::int[];
  if v_a_count = v_best then v_choices := array_append(v_choices, 1); end if;
  if v_b_count = v_best then v_choices := array_append(v_choices, 2); end if;
  if v_topic_c is not null and v_c_count = v_best then v_choices := array_append(v_choices, 3); end if;

  if array_length(v_choices, 1) = 1 then
    v_pick := v_choices[1];
    v_choices := null;
  else
    v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
  end if;

  v_selected := case v_pick when 1 then v_topic_a when 2 then v_topic_b else v_topic_c end;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

-- topic_c mit nullen, wo bisher schon topic_a/topic_b genullt wurden
-- (reine Hygiene -- wird vor der nächsten Wahl ohnehin überschrieben).
CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
begin
  select id into v_lobby_id from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then return; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_reset_lobby(text) FROM PUBLIC, anon, authenticated;


CREATE OR REPLACE FUNCTION public.rpc_reset_lobby(p_code TEXT, p_player_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not public._verify_session(v_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'waiting', locked = false,
      holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_started_at = null, topic_vote_ends_at = null,
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 0, pass_direction = 1,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.rpc_rematch(p_code TEXT, p_player_id UUID)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_lobby_id uuid; v_phase text;
begin
  select id, phase into v_lobby_id, v_phase from public.lobbies
  where code = upper(trim(p_code)) limit 1;

  if v_lobby_id is null then raise exception 'Lobby nicht gefunden'; end if;
  if v_phase is distinct from 'finished' then raise exception 'lobby_not_finished'; end if;

  if not public._verify_session(v_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if not exists (
    select 1 from public.players
    where lobby_id = v_lobby_id and player_id = p_player_id and status = 'active'
  ) then raise exception 'not_a_member'; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;

  update public.players
  set ready = coalesce(is_bot, false), is_alive = true,
      pass_count = 0, clutch_pass_count = 0,
      fastest_pass_ms = null, total_hold_ms = 0,
      survival_streak = 0, last_pass_at = null
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'rematch_wait', holder_player_id = null, explode_at = null,
      run_started_at = null, last_loser_player_id = null,
      topic_a = null, topic_b = null, topic_c = null, topic_selected = null,
      topic_vote_ends_at = null, countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      current_attempt_id = null, used_answers = '{}',
      round_number = 1, last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;
