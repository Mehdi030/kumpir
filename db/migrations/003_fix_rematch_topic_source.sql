-- ============================================================
-- Migration 003: Bug-Fix — rpc_start_rematch_if_ready nutzt topics statt topic_pool
-- ============================================================
-- Aktueller Zustand: zwei Funktionen ziehen Topics aus VERSCHIEDENEN Tabellen:
--   - rpc_begin_topic_vote → topic_pool (text-Spalte)
--   - rpc_start_rematch_if_ready → topics (name-Spalte)
--
-- Wenn topics leer ist (was bei dir vermutlich der Fall ist, weil dein
-- Frontend nur topic_pool nutzt), schmeißt der Rematch eine Exception:
--   "Nicht genug aktive Themen vorhanden"
--
-- Diese Migration richtet rpc_start_rematch_if_ready darauf aus, ebenfalls
-- topic_pool zu nutzen — damit ist nur eine Quelle der Wahrheit.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_start_rematch_if_ready(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid;
  v_ready_count int;
  v_active_count int;
  v_topic_a text;
  v_topic_b text;
begin
  select id into v_lobby_id
  from public.lobbies
  where code = upper(trim(p_code))
  limit 1;

  if v_lobby_id is null then
    raise exception 'Lobby nicht gefunden';
  end if;

  select count(*) into v_active_count
  from public.players
  where lobby_id = v_lobby_id
    and status = 'active';

  select count(*) into v_ready_count
  from public.players
  where lobby_id = v_lobby_id
    and status = 'active'
    and coalesce(ready, false) = true;

  if v_active_count < 2 then
    raise exception 'Mindestens 2 aktive Spieler nötig';
  end if;

  if v_ready_count <> v_active_count then
    return;
  end if;

  -- ✅ FIX: nutze topic_pool (gleiche Quelle wie rpc_begin_topic_vote)
  select t.text into v_topic_a
  from public.topic_pool t
  where t.active is true
  order by random()
  limit 1;

  select t.text into v_topic_b
  from public.topic_pool t
  where t.active is true
    and t.text <> v_topic_a
  order by random()
  limit 1;

  if v_topic_a is null or v_topic_b is null then
    raise exception 'Nicht genug Themen im topic_pool';
  end if;

  delete from public.topic_votes
  where lobby_id = v_lobby_id;

  update public.players
  set ready = false
  where lobby_id = v_lobby_id
    and status = 'active';

  update public.lobbies
  set
    phase = 'topic_vote',
    topic_a = v_topic_a,
    topic_b = v_topic_b,
    topic_selected = null,
    topic_vote_started_at = now(),
    topic_vote_ends_at = now() + interval '10 seconds',
    countdown_started_at = null,
    countdown_ends_at = null,
    topic_tie_choices = null,
    topic_tie_pick = null,
    holder_player_id = null,
    explode_at = null,
    run_started_at = null,
    last_activity_at = now()
  where id = v_lobby_id;
end;
$function$;

COMMIT;


-- ============================================================
-- Optional: alte `topics`-Tabelle löschen, wenn sie nicht mehr genutzt wird.
-- Bitte ERST prüfen, dass keine andere Funktion topics referenziert:
--
--   SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND pg_get_functiondef(p.oid) LIKE '%public.topics%';
--
-- Wenn nur rpc_start_rematch_if_ready in der Liste war (und du diese Migration
-- angewendet hast), kannst du gefahrlos:
--
--   DROP TABLE IF EXISTS public.topics;
-- ============================================================
