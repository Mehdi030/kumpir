-- ============================================================
-- Migration 053: Server-Zeit-Sync + fester Startspieler beim Countdown
-- ============================================================
-- 1) rpc_server_time(): gibt now() zurück. Das Frontend ruft das einmal
--    beim Betreten der Runde auf und berechnet daraus einen Client<->
--    Server-Zeitversatz -- behebt den gemeldeten Bug, dass der "START IN"-
--    Countdown auf einem Gerät bei "10" feststand, während er auf einem
--    anderen normal von "5" runterlief: countdown_ends_at ist bei BEIDEN
--    Geräten identisch (immer +5s ab Finalisierung), ein spürbar
--    falsch gehender Geräte-Takt (Date.now()) reicht aber, um die daraus
--    berechnete Restzeit deutlich zu verfälschen.
-- 2) countdown_starter_player_id: wird SOFORT bei Countdown-Beginn
--    zufällig gezogen (statt erst am Countdown-Ende) und von
--    rpc_advance_from_countdown wiederverwendet -- damit während des
--    Countdowns stabil angezeigt werden kann, WER gleich anfängt, ohne
--    dass sich das am Ende nochmal ändert.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_server_time()
 RETURNS timestamptz
 LANGUAGE sql
 STABLE
AS $function$
  SELECT now();
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_server_time() TO anon, authenticated;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS countdown_starter_player_id uuid;
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text; v_topic_c text;
  v_a_count int := 0; v_b_count int := 0; v_c_count int := 0;
  v_selected text; v_pick int; v_choices int[]; v_best int;
  v_starter uuid;
begin
  select topic_a, topic_b, topic_c into v_topic_a, v_topic_b, v_topic_c
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  select count(*) into v_c_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;

  if v_topic_c is not null then
    -- Echtes drittes Thema: symmetrische 3-Wege-Wertung, Gleichstand
    -- lost zufällig unter den bestplatzierten Themen aus.
    v_best := greatest(v_a_count, v_b_count, v_c_count);
    v_choices := array[]::int[];
    if v_a_count = v_best then v_choices := array_append(v_choices, 1); end if;
    if v_b_count = v_best then v_choices := array_append(v_choices, 2); end if;
    if v_c_count = v_best then v_choices := array_append(v_choices, 3); end if;

    if array_length(v_choices, 1) = 1 then
      v_pick := v_choices[1];
      v_choices := null;
    else
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
    end if;

    v_selected := case v_pick when 1 then v_topic_a when 2 then v_topic_b else v_topic_c end;
  else
    -- Kein echtes drittes Thema -- Choice 3 ist "Zufällig" (wie vor
    -- Migration 042): gewinnt/steht im Gleichstand Choice 3, wird
    -- zwischen A und B ausgelost statt selbst ein Ziel zu sein.
    if v_a_count > v_b_count and v_a_count > v_c_count then
      v_selected := v_topic_a; v_pick := 1; v_choices := null;
    elsif v_b_count > v_a_count and v_b_count > v_c_count then
      v_selected := v_topic_b; v_pick := 2; v_choices := null;
    elsif v_c_count > v_a_count and v_c_count > v_b_count then
      v_pick := (array[1,2])[1 + floor(random() * 2)::int];
      v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      v_choices := array[3];
    else
      v_choices := array[]::int[];
      if v_a_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 1); end if;
      if v_b_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 2); end if;
      if v_c_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 3); end if;
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
      if v_pick = 1 then v_selected := v_topic_a;
      elsif v_pick = 2 then v_selected := v_topic_b;
      else
        v_pick := (array[1,2])[1 + floor(random() * 2)::int];
        v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      end if;
    end if;
  end if;

  select player_id into v_starter
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_starter_player_id = v_starter,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
begin
  select round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  -- Der beim Countdown-Beginn gezogene Starter gilt weiter -- nur falls er
  -- inzwischen ungültig wurde (z.B. gekickt), wird neu gezogen.
  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  v_explode_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    greatest(1, v_alive_count),
    greatest(1, v_round_number)
  );

  update public.lobbies
  set phase = 'running',
      holder_player_id = v_holder,
      run_started_at = now(),
      explode_at = now() + (v_explode_seconds * interval '1 second'),
      countdown_started_at = null,
      countdown_ends_at = null,
      countdown_starter_player_id = null,
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      round_bonus_used = 0,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

COMMIT;
