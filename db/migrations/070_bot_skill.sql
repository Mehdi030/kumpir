-- ============================================================
-- Migration 070: Bots mit unterschiedlicher Stärke
-- ============================================================
-- players.bot_skill: 1 = Anfänger, 2 = Mittel, 3 = Profi (NULL bei Menschen).
-- Unterschiede (serverseitig in _bot_tick):
--   * Reaktionszeit:      Anfänger 2.4-5.4 s | Mittel 1.2-3.8 s | Profi 0.8-2.0 s
--   * Trefferquote/Runde: Anfänger = 70 % der Basis | Mittel = Basis | Profi bleibt hoch
--   * Interpret statt Titel (halbe Punkte, weniger Bonuszeit):
--                         Anfänger 45 % | Mittel 15 % | Profi 0 %
-- rpc_add_bot nimmt optional die Stärke; ohne Angabe wird gemischt gelost
-- (30 % Anfänger, 45 % Mittel, 25 % Profi).
-- ============================================================

BEGIN;

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS bot_skill smallint;
ALTER TABLE public.players DROP CONSTRAINT IF EXISTS players_bot_skill_check;
ALTER TABLE public.players ADD CONSTRAINT players_bot_skill_check CHECK (bot_skill IS NULL OR bot_skill BETWEEN 1 AND 3);
-- Spalten-Allowlist (nie Tabellen-GRANT -- session_token!)
GRANT SELECT (bot_skill) ON public.players TO anon, authenticated;

-- Bots, die schon existieren: mittel
UPDATE public.players SET bot_skill = 2 WHERE is_bot = true AND bot_skill IS NULL;

-- Trefferwahrscheinlichkeit pro Runde je Stärke
CREATE OR REPLACE FUNCTION public._bot_survival(p_round integer, p_skill integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case coalesce(p_skill, 2)
    when 1 then greatest(0.08, public._bot_survival(p_round) * 0.7)
    when 3 then greatest(0.5, 0.97 - (greatest(coalesce(p_round, 1), 1) - 1) * 0.11)
    else public._bot_survival(p_round)
  end;
$function$;

-- rpc_add_bot mit optionaler Stärke
DROP FUNCTION IF EXISTS public.rpc_add_bot(uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.rpc_add_bot(p_lobby_id uuid, p_me_player_id uuid, p_bot_name text, p_skill smallint DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_host uuid; v_max_players int; v_active_count int; v_next_seat int;
  v_bot_id uuid := gen_random_uuid();
  v_skill smallint := p_skill;
  v_roll numeric;
begin
  if not public._verify_session(p_lobby_id, p_me_player_id) then
    raise exception 'invalid_session';
  end if;

  select host_player_id, max_players into v_host, v_max_players
  from public.lobbies where id = p_lobby_id;

  if v_host is null then raise exception 'lobby_not_found'; end if;
  if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

  if v_skill is not null and v_skill not between 1 and 3 then raise exception 'invalid_skill'; end if;
  if v_skill is null then
    v_roll := random();
    v_skill := case when v_roll < 0.30 then 1 when v_roll < 0.75 then 2 else 3 end;
  end if;

  select count(*) into v_active_count from public.players where lobby_id = p_lobby_id and status = 'active';
  if v_active_count >= v_max_players then raise exception 'lobby_full'; end if;

  select coalesce(min(s.i), 0) into v_next_seat
  from generate_series(0, v_max_players - 1) as s(i)
  left join public.players p on p.lobby_id = p_lobby_id and p.seat_index = s.i and p.status = 'active'
  where p.id is null;

  insert into public.players (lobby_id, player_id, name, status, seat_index, joined_at, last_seen_at, is_bot, ready, bot_skill)
  values (p_lobby_id, v_bot_id, left(trim(p_bot_name), 24), 'active', v_next_seat, now(), now(), true, true, v_skill);

  update public.lobbies set last_activity_at = now() where id = p_lobby_id;
  return v_bot_id;
end;
$function$;
GRANT EXECUTE ON FUNCTION public.rpc_add_bot(uuid, uuid, text, smallint) TO anon, authenticated;

-- Bot-Ticker: Halter-Teil mit Stärke
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
  v_artist_chance numeric;
  v_base numeric; v_span numeric;
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
           l.topic_selected, l.used_answers, l.explode_at, coalesce(p.bot_skill, 2) as skill
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.player_id = l.holder_player_id
    where l.phase = 'running' and p.is_bot = true and p.is_alive = true
      and l.current_attempt_id is null and l.holder_since is not null
      and (l.explode_at is null or l.explode_at > now() + interval '300 milliseconds')
  loop
    -- Reaktionszeit je Stärke
    if r.skill = 1 then v_base := 2.4; v_span := 3.0;
    elsif r.skill = 3 then v_base := 0.8; v_span := 1.2;
    else v_base := 1.2; v_span := 2.6; end if;

    v_seed := r.holder_player_id::text || r.holder_since::text;
    v_delay := v_base + (abs(hashtext(v_seed)) % 1000) / 1000.0 * v_span;
    if now() - r.holder_since < v_delay * interval '1 second' then continue; end if;

    v_roll := (abs(hashtext('r' || v_seed)) % 1000) / 1000.0;
    if v_roll >= public._bot_survival(r.round_number, r.skill) then continue; end if;

    v_artist_chance := case r.skill when 1 then 0.45 when 3 then 0 else 0.15 end;

    v_answer := null;
    if r.current_song_id is not null then
      if (abs(hashtext('a' || v_seed)) % 1000) / 1000.0 < v_artist_chance then
        select trim(split_part(artist, ',', 1)) into v_answer from public.song_pool where id = r.current_song_id;
      end if;
      if v_answer is null or length(v_answer) = 0 then
        select title into v_answer from public.song_pool where id = r.current_song_id;
      end if;
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

COMMIT;
