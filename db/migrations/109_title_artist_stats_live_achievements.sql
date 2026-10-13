-- ============================================================
-- 109: Statistik "Titel + Künstler" getrennt von "nur Titel", Erfolge mitten in der Runde,
--      Antwort-Statistik für den Endstand (Wunsch Mehdi 2026-10-13)
-- ============================================================
-- game_events.kind: neu 'both' (Titel + Künstler, 1,5 Punkte). 'title' = nur Titel, 'artist' = nur Künstler.
-- account_rounds/account_matches.title_hits zählen weiter ALLE Titel-Treffer (inkl. 'both'), both_hits ist
-- der Anteil davon mit Künstler. Ältere Einträge lassen sich nicht mehr aufteilen (both_hits = 0).
-- Quiz-Runden (108) werden nicht als Titel/Künstler protokolliert.
BEGIN;

ALTER TABLE public.account_rounds ADD COLUMN IF NOT EXISTS both_hits int NOT NULL DEFAULT 0;
ALTER TABLE public.account_matches ADD COLUMN IF NOT EXISTS both_hits int NOT NULL DEFAULT 0;
ALTER TABLE public.game_events DROP CONSTRAINT IF EXISTS game_events_kind_check;
ALTER TABLE public.game_events ADD CONSTRAINT game_events_kind_check
  CHECK (kind = ANY (ARRAY['title', 'both', 'artist', 'wrong', 'exploded', 'left']));

-- Song-Erfolge mitten in der Runde (Titel-Zahl inkl. laufender Runde, schnelles Ohr, Serie)
CREATE OR REPLACE FUNCTION public._award_live_song_achievements(p_user_id uuid, p_lobby_id uuid, p_match_id uuid, p_ms int, p_combo int)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_titles int;
begin
  if public._lobby_human_count(p_lobby_id) < 2 then return; end if;  -- nur gewertete Spiele (075)
  select coalesce(sum(title_hits), 0) into v_titles from public.account_rounds where user_id = p_user_id and ranked;
  -- Titel der laufenden (noch nicht gespeicherten) Runde dazu
  v_titles := v_titles + (
    select count(*) from public.game_events ge
    where ge.lobby_id = p_lobby_id and ge.match_id is not distinct from p_match_id and ge.user_id = p_user_id
      and ge.kind in ('title', 'both')
      and not exists (select 1 from public.account_rounds ar where ar.user_id = p_user_id and ar.match_id = ge.match_id and ar.round_index = ge.series_index)
  );
  insert into public.player_achievements (user_id, achievement_code, lobby_id)
  select p_user_id, a.code, p_lobby_id
  from public.achievements a
  where (a.code = 'music_first_title' and v_titles >= 1)
     or (a.code = 'music_titles_50'   and v_titles >= 50)
     or (a.code = 'music_titles_250'  and v_titles >= 250)
     or (a.code = 'music_combo_5'     and p_combo >= 5)
     or (a.code = 'music_quick_ear'   and p_ms < 3000)
  on conflict (user_id, achievement_code) do nothing;
end;
$function$;
REVOKE EXECUTE ON FUNCTION public._award_live_song_achievements(uuid, uuid, uuid, int, int) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._trg_log_game_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l record;
  v_kind text;
  v_ms integer;
  v_delta numeric;
begin
  begin
    select match_id, series_index, round_number, topic_selected, current_song_id,
           current_song_started_at, holder_since, holder_player_id, phase
      into l
    from public.lobbies where id = NEW.lobby_id;

    -- Quiz-Modi (108) vergeben andere Punkte – nicht als Titel/Künstler mitzählen
    if l.phase = 'quiz' then return NEW; end if;

    if NEW.song_points > OLD.song_points then
      -- 109: Titel + Künstler (1,5) / nur Titel (1) / nur Künstler (0,5) getrennt
      v_delta := NEW.song_points - OLD.song_points;
      v_kind := case when v_delta >= 1.5 then 'both' when v_delta >= 1 then 'title' else 'artist' end;
      v_ms := (extract(epoch from (now() - coalesce(l.current_song_started_at, l.holder_since, now()))) * 1000)::int;
    elsif NEW.last_wrong_guess_at is not null and NEW.last_wrong_guess_at is distinct from OLD.last_wrong_guess_at then
      v_kind := 'wrong';
      v_ms := (extract(epoch from (now() - coalesce(l.current_song_started_at, l.holder_since, now()))) * 1000)::int;
    elsif OLD.is_alive and not NEW.is_alive then
      v_kind := case when coalesce(NEW.status, 'active') = 'active' then 'exploded' else 'left' end;
      v_ms := case when l.holder_player_id = NEW.player_id
                   then (extract(epoch from (now() - coalesce(l.holder_since, now()))) * 1000)::int end;
    else
      return NEW;
    end if;

    insert into public.game_events
      (lobby_id, match_id, series_index, round_number, player_id, user_id, is_bot, bot_skill,
       kind, song_id, playlist, ms, combo, alive_count, players_count)
    values
      (NEW.lobby_id, l.match_id, l.series_index, l.round_number, NEW.player_id, NEW.user_id,
       coalesce(NEW.is_bot, false), NEW.bot_skill, v_kind, l.current_song_id, l.topic_selected,
       greatest(v_ms, 0), NEW.combo,
       (select count(*) from public.players p where p.lobby_id = NEW.lobby_id and p.status = 'active' and p.is_alive),
       (select count(*) from public.players p where p.lobby_id = NEW.lobby_id and p.status = 'active'));

    -- 109: Song-Erfolge sofort freischalten (nicht erst am Rundenende), nur in gewerteten Spielen
    if v_kind in ('title', 'both') and NEW.user_id is not null and not coalesce(NEW.is_bot, false) then
      perform public._award_live_song_achievements(NEW.user_id, NEW.lobby_id, l.match_id, greatest(v_ms, 0), coalesce(NEW.combo, 0));
    end if;
  exception when others then
    -- Protokoll darf das Spiel niemals stören.
    raise warning 'game_events: %', sqlerrm;
  end;
  return NEW;
end;
$function$;

CREATE OR REPLACE FUNCTION public._record_round_history(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l record;
  v_match uuid;
  v_idx int; v_total int;
  v_humans int; v_bots int; v_n int;
  v_ranked boolean;
  u record;
begin
  select id, code, series_index, series_total, topic_selected, match_id into l
  from public.lobbies where id = p_lobby_id;
  if not found then return; end if;

  v_idx := coalesce(l.series_index, 1);
  v_total := coalesce(l.series_total, 1);
  v_match := l.match_id;
  if v_match is null then
    -- Lobby lief schon vor Migration 076: ID nachträglich vergeben.
    v_match := gen_random_uuid();
    update public.lobbies set match_id = v_match where id = p_lobby_id;
  end if;

  v_humans := public._lobby_human_count(p_lobby_id);
  select count(*) filter (where coalesce(is_bot, false)), count(*)
    into v_bots, v_n
  from public.players where lobby_id = p_lobby_id and status = 'active';
  v_ranked := v_humans >= 2;

  insert into public.account_rounds
    (user_id, match_id, lobby_code, round_index, rounds_total, playlist, place, players_count,
     humans_count, bots_count, arena_points, song_points, title_hits, both_hits, artist_hits, wrong_guesses,
     answer_ms_sum, answer_count, fastest_title_ms, best_combo, ranked)
  select p.user_id, v_match, l.code, v_idx, v_total, l.topic_selected, sr.place, v_n,
         v_humans, v_bots, sr.arena_points, sr.song_points,
         coalesce(e.titles, 0), coalesce(e.both, 0), coalesce(e.artists, 0), coalesce(e.wrongs, 0),
         coalesce(e.ms_sum, 0), coalesce(e.ms_n, 0), e.fastest, coalesce(e.combo, 0), v_ranked
  from public.players p
  join public.profiles pr on pr.id = p.user_id
  join public.series_results sr
    on sr.lobby_id = p.lobby_id and sr.player_id = p.player_id and sr.set_index = v_idx
  left join lateral (
    select count(*) filter (where ge.kind in ('title', 'both')) as titles,
           count(*) filter (where ge.kind = 'both') as both,
           count(*) filter (where ge.kind = 'artist') as artists,
           count(*) filter (where ge.kind = 'wrong')  as wrongs,
           sum(ge.ms) filter (where ge.kind in ('title', 'both', 'artist')) as ms_sum,
           count(ge.ms) filter (where ge.kind in ('title', 'both', 'artist')) as ms_n,
           min(ge.ms) filter (where ge.kind in ('title', 'both')) as fastest,
           max(ge.combo) filter (where ge.kind in ('title', 'both')) as combo
    from public.game_events ge
    where ge.lobby_id = p_lobby_id and ge.match_id = v_match
      and ge.series_index = v_idx and ge.player_id = p.player_id
  ) e on true
  where p.lobby_id = p_lobby_id and p.user_id is not null and not coalesce(p.is_bot, false)
  on conflict (user_id, match_id, round_index) do nothing;

  -- Letzte Runde des Matches: Match-Platz über alle Runden (wie die Anzeige im Spiel:
  -- Punkte, dann Rundensiege, dann besserer Ø-Platz).
  if v_idx >= v_total then
    insert into public.account_matches
      (user_id, match_id, lobby_code, rounds_total, place, players_count, humans_count, bots_count,
       total_points, round_wins, playlists, title_hits, both_hits, artist_hits, wrong_guesses, ranked)
    select p.user_id, v_match, l.code, v_total, rk.mplace, rk.n, v_humans, v_bots,
           rk.total, rk.wins,
           (select array_agg(ar.playlist order by ar.round_index) from public.account_rounds ar
             where ar.user_id = p.user_id and ar.match_id = v_match),
           coalesce((select sum(ar.title_hits) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           coalesce((select sum(ar.both_hits) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           coalesce((select sum(ar.artist_hits) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           coalesce((select sum(ar.wrong_guesses) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
           v_ranked
    from (
      select t.player_id, t.total, t.wins,
             row_number() over (order by t.total desc, t.wins desc, t.avgp asc)::int as mplace,
             count(*) over ()::int as n
      from (
        select sr.player_id, sum(sr.arena_points)::int as total,
               count(*) filter (where sr.place = 1)::int as wins, avg(sr.place) as avgp
        from public.series_results sr
        where sr.lobby_id = p_lobby_id and sr.set_index <= v_total
        group by sr.player_id
      ) t
    ) rk
    join public.players p on p.lobby_id = p_lobby_id and p.player_id = rk.player_id
    join public.profiles pr on pr.id = p.user_id
    where p.user_id is not null and not coalesce(p.is_bot, false)
    on conflict (user_id, match_id) do nothing;
  end if;

  if v_ranked then
    for u in
      select distinct p.user_id from public.players p
      where p.lobby_id = p_lobby_id and p.user_id is not null and not coalesce(p.is_bot, false)
    loop
      perform public._award_history_achievements(u.user_id, p_lobby_id);
    end loop;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_profile_stats(p_season text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_season text := coalesce(p_season, to_char(now(), 'YYYY-MM'));
  v_from timestamptz;
  v_to timestamptz;
begin
  if v_uid is null then raise exception 'not_logged_in'; end if;
  v_from := to_date(v_season || '-01', 'YYYY-MM-DD')::timestamptz;
  v_to := v_from + interval '1 month';

  return jsonb_build_object(
    -- F: Matches und Runden getrennt (nur gewertete Spiele)
    'totals', (
      select jsonb_build_object(
        'matches', (select count(*) from account_matches where user_id = v_uid and ranked),
        'matchWins', (select count(*) from account_matches where user_id = v_uid and ranked and place = 1),
        'rounds', (select count(*) from account_rounds where user_id = v_uid and ranked),
        'roundWins', (select count(*) from account_rounds where user_id = v_uid and ranked and place = 1),
        'practiceMatches', (select count(*) from account_matches where user_id = v_uid and not ranked)
      )
    ),
    -- B: Musik (alle Runden inkl. Übung – es geht ums eigene Song-Wissen)
    'music', (
      select jsonb_build_object(
        'titles', coalesce(sum(title_hits), 0),
        'both', coalesce(sum(both_hits), 0),
        'artists', coalesce(sum(artist_hits), 0),
        'wrong', coalesce(sum(wrong_guesses), 0),
        'avgAnswerMs', case when sum(answer_count) > 0 then round(sum(answer_ms_sum)::numeric / sum(answer_count)) end,
        'fastestTitleMs', min(fastest_title_ms),
        'bestCombo', coalesce(max(best_combo), 0)
      ) from account_rounds where user_id = v_uid
    ),
    'playlists', coalesce((
      select jsonb_agg(x order by x.rounds desc) from (
        select playlist, count(*)::int as rounds,
               sum(title_hits)::int as titles, sum(both_hits)::int as both, sum(artist_hits)::int as artists, sum(wrong_guesses)::int as wrong,
               count(*) filter (where place = 1)::int as wins
        from account_rounds where user_id = v_uid and playlist is not null
        group by playlist
      ) x
    ), '[]'::jsonb),
    -- A: letzte 20 Matches
    'recent', coalesce((
      select jsonb_agg(m order by m.finished_at desc) from (
        select finished_at, rounds_total, place, players_count, humans_count, bots_count,
               total_points, round_wins, playlists, title_hits, both_hits, artist_hits, wrong_guesses, ranked
        from account_matches where user_id = v_uid
        order by finished_at desc limit 20
      ) m
    ), '[]'::jsonb),
    -- C: häufigste Gegner (nur Konten)
    'opponents', coalesce((
      select jsonb_agg(o order by o.matches desc, o.username) from (
        select pr.username, count(*)::int as matches,
               count(*) filter (where me.place < op.place)::int as wins,
               count(*) filter (where me.place > op.place)::int as losses
        from account_matches me
        join account_matches op on op.match_id = me.match_id and op.user_id <> me.user_id
        join profiles pr on pr.id = op.user_id
        where me.user_id = v_uid and pr.username is not null
        group by pr.username
        order by count(*) desc, pr.username
        limit 5
      ) o
    ), '[]'::jsonb),
    -- E: Monats-Rückblick
    'recap', jsonb_build_object(
      'season', v_season,
      'rank', (select rank from season_leaderboard_view where season = v_season and user_id = v_uid),
      'seasonPoints', (select arena_points from season_points where season = v_season and user_id = v_uid),
      'matches', (select count(*) from account_matches where user_id = v_uid and finished_at >= v_from and finished_at < v_to),
      'matchWins', (select count(*) from account_matches where user_id = v_uid and ranked and place = 1 and finished_at >= v_from and finished_at < v_to),
      'rounds', (select count(*) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'titles', (select coalesce(sum(title_hits), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'both', (select coalesce(sum(both_hits), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'artists', (select coalesce(sum(artist_hits), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'wrong', (select coalesce(sum(wrong_guesses), 0) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'bestRoundPoints', (select max(arena_points) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'fastestTitleMs', (select min(fastest_title_ms) from account_rounds where user_id = v_uid and played_at >= v_from and played_at < v_to),
      'favoritePlaylist', (
        select playlist from account_rounds
        where user_id = v_uid and played_at >= v_from and played_at < v_to and playlist is not null
        group by playlist order by count(*) desc, playlist limit 1
      ),
      'bestPlaylist', (
        select playlist from account_rounds
        where user_id = v_uid and played_at >= v_from and played_at < v_to and playlist is not null
        group by playlist
        having sum(title_hits + artist_hits + wrong_guesses) >= 5
        order by sum(title_hits)::numeric / nullif(sum(title_hits + artist_hits + wrong_guesses), 0) desc, playlist
        limit 1
      )
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_song_stats(p_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public._require_platform_admin();
  return coalesce((
    select jsonb_agg(s order by s.rate nulls first, s.plays desc) from (
      select tp.text as playlist, sp.title, sp.artist, sp.plays, sp.hits,
             case when sp.plays > 0 then round(100.0 * sp.hits / sp.plays) end as rate,
             coalesce(e.artists, 0) as artists, coalesce(e.wrong, 0) as wrong, e.avg_ms
      from public.song_pool sp
      join public.topic_pool tp on tp.id = sp.topic_pool_id
      left join (
        select song_id,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong,
               round(avg(ms) filter (where kind in ('title', 'both')))::int as avg_ms
        from public.game_events
        where not is_bot and created_at > now() - make_interval(days => greatest(1, p_days))
        group by song_id
      ) e on e.song_id = sp.id
      where sp.plays > 0
    ) s
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_balance_stats(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from timestamptz := now() - make_interval(days => greatest(1, p_days));
begin
  perform public._require_platform_admin();
  return jsonb_build_object(
    'days', greatest(1, p_days),
    'groups', coalesce((
      select jsonb_agg(g order by g.who) from (
        select case when is_bot then 'Bot Stärke ' || coalesce(bot_skill, 0) else 'Menschen' end as who,
               count(*) filter (where kind in ('title', 'both'))::int as titles,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong,
               count(*) filter (where kind = 'exploded')::int as exploded,
               round(avg(ms) filter (where kind in ('title', 'both', 'artist')))::int as avg_answer_ms,
               round(avg(ms) filter (where kind = 'exploded'))::int as avg_hold_before_boom_ms
        from public.game_events where created_at > v_from
        group by 1
      ) g
    ), '[]'::jsonb),
    'byAlive', coalesce((
      select jsonb_agg(a order by a.bucket) from (
        select case when alive_count <= 2 then '1 Duell (2 übrig)'
                    when alive_count <= 4 then '2 · 3–4 übrig'
                    else '3 · 5+ übrig' end as bucket,
               count(*) filter (where kind in ('title', 'both', 'artist'))::int as answers,
               round(avg(ms) filter (where kind in ('title', 'both', 'artist')))::int as avg_answer_ms,
               count(*) filter (where kind = 'exploded')::int as exploded,
               round(avg(ms) filter (where kind = 'exploded'))::int as avg_hold_before_boom_ms
        from public.game_events where created_at > v_from and not is_bot
        group by 1
      ) a
    ), '[]'::jsonb),
    -- Durchprobieren: wie viele Fehlversuche vor einem Treffer (pro Mensch, Zug, Song)
    'wrongBeforeHit', coalesce((
      select jsonb_agg(w order by w.wrong_tries) from (
        select least(t.wrongs, 5) as wrong_tries, count(*)::int as turns
        from (
          select lobby_id, player_id, round_number, song_id,
                 count(*) filter (where kind = 'wrong') as wrongs
          from public.game_events
          where created_at > v_from and not is_bot
          group by lobby_id, match_id, series_index, round_number, player_id, song_id
          having count(*) filter (where kind in ('title', 'both', 'artist')) > 0
        ) t
        group by 1
      ) w
    ), '[]'::jsonb),
    'playlists', coalesce((
      select jsonb_agg(p order by p.playlist) from (
        select playlist,
               count(*) filter (where kind in ('title', 'both'))::int as titles,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong
        from public.game_events where created_at > v_from and not is_bot and playlist is not null
        group by playlist
      ) p
    ), '[]'::jsonb)
  );
end;
$function$;

-- Antwort-Statistik eines Matches für den Endstand (pro Spieler, alle Runden des Matches)
CREATE OR REPLACE FUNCTION public.get_match_answer_stats(p_code text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'playerId', x.player_id, 'both', x.both, 'titles', x.titles, 'artists', x.artists, 'wrong', x.wrong,
           'fastestMs', x.fastest, 'avgMs', x.avg_ms, 'bestCombo', x.combo, 'exploded', x.exploded)), '[]'::jsonb)
  FROM (
    SELECT ge.player_id,
           count(*) FILTER (WHERE ge.kind = 'both')::int AS both,
           count(*) FILTER (WHERE ge.kind = 'title')::int AS titles,
           count(*) FILTER (WHERE ge.kind = 'artist')::int AS artists,
           count(*) FILTER (WHERE ge.kind = 'wrong')::int AS wrong,
           count(*) FILTER (WHERE ge.kind = 'exploded')::int AS exploded,
           min(ge.ms) FILTER (WHERE ge.kind IN ('title', 'both')) AS fastest,
           round(avg(ge.ms) FILTER (WHERE ge.kind IN ('title', 'both', 'artist')))::int AS avg_ms,
           coalesce(max(ge.combo) FILTER (WHERE ge.kind IN ('title', 'both')), 0) AS combo
    FROM public.lobbies l
    JOIN public.game_events ge ON ge.lobby_id = l.id AND ge.match_id IS NOT DISTINCT FROM l.match_id
    WHERE l.code = upper(trim(p_code))
    GROUP BY ge.player_id
  ) x;
$function$;
GRANT EXECUTE ON FUNCTION public.get_match_answer_stats(text) TO anon, authenticated;

COMMIT;
