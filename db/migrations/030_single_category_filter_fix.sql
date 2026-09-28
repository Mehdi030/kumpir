-- ============================================================
-- Migration 030: Themen-Filter mit nur EINER Kategorie startet nicht
-- ============================================================
-- Live beim gemeinsamen Testen gefunden: setzt der Host den
-- Musik-Genre-Filter auf genau EINE Kategorie (z.B. nur
-- "Deutschrap-Songs"), wirft rpc_begin_topic_vote und
-- rpc_start_rematch_if_ready "Not enough topics in topic_pool" --
-- beide ziehen Thema A und Thema B als zwei UNTERSCHIEDLICHE
-- Kategorien aus dem gefilterten Pool, aber wenn der Filter nur eine
-- Kategorie zulaesst, gibt es kein zweites, verschiedenes Thema.
-- Das Spiel liess sich dann ueberhaupt nicht starten.
--
-- Fix: gibt es kein zweites, verschiedenes Thema im gefilterten Pool,
-- wird Thema B einfach gleich Thema A gesetzt (beide Wahlmoeglichkeiten
-- zeigen dieselbe einzige Kategorie -- die Abstimmung ist dann trivial,
-- aber das Spiel startet).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_begin_topic_vote(p_lobby_id uuid, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_a text; v_b text; v_filter text[];
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

  select t.text into v_b from public.topic_pool t
  where t.active is true and t.text <> v_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_a is null then raise exception 'Not enough topics in topic_pool'; end if;
  if v_b is null then v_b := v_a; end if;

  delete from public.topic_votes where lobby_id = p_lobby_id;

  update public.lobbies l
  set last_topic = coalesce(l.topic, l.last_topic),
      phase = 'topic_vote',
      locked = true,
      topic_a = v_a, topic_b = v_b, topic_selected = null, topic = null,
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
  v_topic_a text; v_topic_b text;
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

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true and t.text <> v_topic_a and (v_filter is null or t.text = any(v_filter))
  order by random() limit 1;

  if v_topic_a is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;
  if v_topic_b is null then v_topic_b := v_topic_a; end if;

  delete from public.topic_votes where lobby_id = v_lobby_id;
  update public.players set ready = coalesce(is_bot, false)
  where lobby_id = v_lobby_id and status = 'active';

  update public.lobbies
  set phase = 'topic_vote',
      topic_a = v_topic_a, topic_b = v_topic_b, topic_selected = null,
      topic_vote_started_at = now(),
      topic_vote_ends_at = now() + interval '10 seconds',
      countdown_started_at = null, countdown_ends_at = null,
      topic_tie_choices = null, topic_tie_pick = null,
      holder_player_id = null, explode_at = null, run_started_at = null,
      last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;
