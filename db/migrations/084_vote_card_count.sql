-- ============================================================
-- 084: Playlist-Abstimmung passt sich der Zahl der gewählten Playlists an
-- ============================================================
--   3 oder mehr Playlists: wie bisher (Playlist A, Playlist B, Zufall-Karte)
--   genau 2 Playlists:     nur die beiden Karten A und B (keine Zufall-Karte)
--   genau 1 Playlist:      keine Abstimmung – es geht sofort in den Countdown
--
-- Umsetzung: lobbies.topic_vote_cards (1, 2 oder 3) wird gesetzt, sobald die Lobby in die Phase
-- 'topic_vote' wechselt (egal ob Start, nächste Runde oder Revanche). Bei einer Karte endet die
-- Abstimmung sofort; der Server-Takt bzw. jeder Client wertet aus. Spielregeln sonst unverändert.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS topic_vote_cards smallint NOT NULL DEFAULT 3;

CREATE OR REPLACE FUNCTION public._trg_vote_cards()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare n int;
begin
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from 'topic_vote' then
    n := coalesce(cardinality(public._vote_topic_pool(NEW.topic_filter)), 0);
    NEW.topic_vote_cards := least(3, greatest(n, 1));
    if n <= 1 then
      NEW.topic_vote_ends_at := now();   -- nur eine Playlist: nichts abzustimmen
      NEW.topic_b := NEW.topic_a;
    end if;
  end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS lobbies_vote_cards ON public.lobbies;
CREATE TRIGGER lobbies_vote_cards BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_vote_cards();

-- Stimme nur für vorhandene Karten
CREATE OR REPLACE FUNCTION public.rpc_vote_topic(p_lobby_id uuid, p_player_id uuid, p_choice integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cards int;
begin
  if p_choice not in (1,2,3) then raise exception 'Invalid choice %', p_choice; end if;

  if not public._verify_session(p_lobby_id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  select topic_vote_cards into v_cards from public.lobbies where id = p_lobby_id;
  if p_choice > coalesce(v_cards, 3) then raise exception 'Invalid choice %', p_choice; end if;

  insert into public.topic_votes (lobby_id, player_id, choice)
  values (p_lobby_id, p_player_id, p_choice)
  on conflict (lobby_id, player_id)
  do update set choice = excluded.choice;
end;
$function$;

-- Auswertung: nur die vorhandenen Karten zählen
CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a text; v_b text; v_filter text[]; v_played text[]; v_starters uuid[]; v_cards int;
  v_cnt int[] := array[0, 0, 0];
  v_best int; v_tied int[] := '{}'; v_fresh int[] := '{}';
  v_pick int; v_selected text; v_choices int[]; v_starter uuid;
  v_rest text[]; i int; v_n int;
begin
  select topic_a, topic_b, topic_filter, series_topics, series_starters, topic_vote_cards
    into v_a, v_b, v_filter, v_played, v_starters, v_cards
  from public.lobbies where id = p_lobby_id and phase = 'topic_vote' for update;
  if not found then return; end if;
  if coalesce(current_setting('request.headers', true), '') <> '' and exists (select 1 from public.lobbies where id = p_lobby_id and topic_vote_ends_at > now() + interval '1 second') then return; end if;

  v_cards := least(3, greatest(coalesce(v_cards, 3), 1));
  if v_a is null then v_a := 'Thema A'; end if;
  if v_b is null then v_b := 'Thema B'; end if;

  for i in 1..v_cards loop
    select count(*) into v_n from public.topic_votes where lobby_id = p_lobby_id and choice = i;
    v_cnt[i] := v_n;
  end loop;

  v_best := greatest(v_cnt[1], v_cnt[2], case when v_cards >= 3 then v_cnt[3] else 0 end);
  for i in 1..v_cards loop
    if v_cnt[i] = v_best then v_tied := array_append(v_tied, i); end if;
  end loop;

  -- Zufalls-Karte: Themen außerhalb der beiden Karten (gibt es keine, bleibt A/B)
  v_rest := array(select x from unnest(public._vote_topic_pool(v_filter)) x where x <> v_a and x <> v_b);

  if v_cards = 1 then
    v_pick := 1;
    v_choices := null;
  elsif array_length(v_tied, 1) = 1 then
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

-- Bots stimmen nur für vorhandene Karten
DO $do$
declare d text;
begin
  select pg_get_functiondef('public._bot_tick()'::regprocedure) into d;
  if position('select l.id as lobby_id, p.player_id, l.topic_vote_started_at' in d) = 0
     or position('1 + (abs(hashtext(''c'' || v_seed)) % 3)' in d) = 0 then
    raise exception '_bot_tick hat sich geändert – Patch prüfen';
  end if;
  d := replace(d, 'select l.id as lobby_id, p.player_id, l.topic_vote_started_at', 'select l.id as lobby_id, p.player_id, l.topic_vote_started_at, l.topic_vote_cards');
  d := replace(d, '1 + (abs(hashtext(''c'' || v_seed)) % 3)', '1 + (abs(hashtext(''c'' || v_seed)) % greatest(1, least(3, r.topic_vote_cards)))');
  execute d;
end
$do$;

COMMIT;
