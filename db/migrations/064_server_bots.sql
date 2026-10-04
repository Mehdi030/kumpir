-- ============================================================
-- Migration 064: Bots laufen auf dem Server -- unabhängig vom Host-Browser
-- ============================================================
-- Bisher steuerte useBotEngine die Bots NUR im Browser des Hosts: Tab im
-- Hintergrund / Host weg => alle Bots standen still. Jetzt übernimmt ein
-- pg_cron-Job (jede Sekunde) die Bots direkt an die Runde gebunden:
--   - Themen-Voting: jeder Bot stimmt nach 1.0-3.5s ab (deterministisch
--     pro Bot+Voting aus einem Hash, damit es nicht jede Sekunde neu
--     gewürfelt wird).
--   - Laufende Runde: ist ein Bot Halter, antwortet er nach 1.2-3.8s mit
--     dem ECHTEN Songtitel -- aber nur mit der Erfolgswahrscheinlichkeit
--     der Runde (Runde 1: 90 %, 2: 60 %, 3: 40 %, 4: 20 %, danach min.
--     10 %). Bei "Misserfolg" tut der Bot nichts, die Schnur entscheidet.
-- Alles deterministisch aus holder_since => keine Doppel-Würfe pro Tick.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._bot_survival(p_round int)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when coalesce(p_round, 1) <= 1 then 0.9
    when p_round = 2 then 0.6
    when p_round = 3 then 0.4
    when p_round = 4 then 0.2
    else greatest(0.1, 0.2 - (p_round - 4) * 0.05)
  end;
$function$;

CREATE OR REPLACE FUNCTION public._bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_delay numeric;
  v_roll numeric;
  v_answer text;
  v_seed text;
begin
  -- ---------- Themen-Voting ----------
  for r in
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % 3))
      on conflict (lobby_id, player_id) do nothing;
    end if;
  end loop;

  -- ---------- Laufende Runde: Bot ist Halter ----------
  for r in
    select l.id, l.code, l.holder_player_id, l.holder_since, l.round_number, l.current_song_id,
           l.topic_selected, l.used_answers, l.explode_at
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := 1.2 + (abs(hashtext(v_seed)) % 2600) / 1000.0;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number) then continue; end if;

    v_answer := null;
    if r.current_song_id is not null then
      select title into v_answer from public.song_pool where id = r.current_song_id;
    else
      select ta.answer into v_answer
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(coalesce(r.topic_selected, ''))
        and not (ta.lower_answer = any (select lower(u) from unnest(r.used_answers) u))
      order by random() limit 1;
      v_answer := coalesce(v_answer, 'Keine Ahnung');
    end if;

    if v_answer is not null then
      begin
        perform public.rpc_attempt_pass(r.code, r.holder_player_id, v_answer);
      exception when others then
        null;
      end;
    end if;
  end loop;
end;
$function$;

REVOKE ALL ON FUNCTION public._bot_tick() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kumpir-bot-tick';
SELECT cron.schedule('kumpir-bot-tick', '1 seconds', 'select public._bot_tick()');

COMMIT;
