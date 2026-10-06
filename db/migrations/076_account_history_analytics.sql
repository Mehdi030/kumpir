-- ============================================================
-- Migration 076: Konto-Verlauf, Musik-Statistik, Analyse
-- ============================================================
-- Spielregeln bleiben unverändert. Alles hier SCHREIBT nur mit:
--   * lobbies.match_id      – eindeutige ID pro Match (BEFORE-Trigger beim Matchstart)
--   * game_events           – Protokoll pro Zug (Titel/Interpret/falsch/raus), per Trigger
--                             auf players; Fehler im Trigger brechen das Spiel NIE ab.
--                             Wird nach 90 Tagen gelöscht (pg_cron).
--   * account_rounds        – dauerhaft: eine Zeile pro Konto und Runde
--   * account_matches       – dauerhaft: eine Zeile pro Konto und Match (Match-Platz)
--   * _finish_round         – EIN zusätzlicher, abgesicherter Aufruf (_record_round_history)
--   * Achievements          – neue Musik-/Match-Achievements, unpassende Pass-Achievements raus,
--                             Texte "Partie" -> "Runde" (games_played zählt Runden)
--   * funnel_events         – anonyme Nutzungs-Ereignisse (Solo gestartet, Beitritt, ...), 90 Tage
--   * RPCs: get_my_profile_stats, admin_song_stats, admin_balance_stats, admin_funnel, log_event
--   * Sicherheitsfix: rpc_get_admin_stats prüft jetzt auth.uid() statt nur die mitgeschickte ID
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Match-ID
-- ------------------------------------------------------------
ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS match_id uuid;

CREATE OR REPLACE FUNCTION public._set_match_id_on_start()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  -- Neues Match = Wechsel in die Themenwahl aus einem Start-Zustand (nicht zwischen zwei Runden).
  if NEW.phase = 'topic_vote'
     and OLD.phase in ('waiting', 'lobby', 'rematch_wait', 'finished') then
    NEW.match_id := gen_random_uuid();
  end if;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_set_match_id ON public.lobbies;
CREATE TRIGGER lobbies_set_match_id
  BEFORE UPDATE OF phase ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._set_match_id_on_start();

-- ------------------------------------------------------------
-- 2) Spielprotokoll (H) – Rohdaten, 90 Tage
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.game_events (
  id            bigserial PRIMARY KEY,
  created_at    timestamptz NOT NULL DEFAULT now(),
  lobby_id      uuid NOT NULL,
  match_id      uuid,
  series_index  integer,
  round_number  integer,           -- "Zug"
  player_id     uuid NOT NULL,
  user_id       uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  is_bot        boolean NOT NULL DEFAULT false,
  bot_skill     smallint,
  kind          text NOT NULL CHECK (kind IN ('title', 'artist', 'wrong', 'exploded', 'left')),
  song_id       uuid,
  playlist      text,
  ms            integer,           -- Antwortzeit seit Songstart bzw. Haltezeit bis zur Explosion
  combo         integer,
  alive_count   integer,
  players_count integer
);

CREATE INDEX IF NOT EXISTS game_events_round_idx ON public.game_events (lobby_id, match_id, series_index, player_id);
CREATE INDEX IF NOT EXISTS game_events_created_idx ON public.game_events (created_at);
CREATE INDEX IF NOT EXISTS game_events_song_idx ON public.game_events (song_id);

ALTER TABLE public.game_events ENABLE ROW LEVEL SECURITY;  -- keine Policies: nur über SECURITY-DEFINER-Funktionen
REVOKE ALL ON public.game_events FROM anon, authenticated;

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
begin
  begin
    select match_id, series_index, round_number, topic_selected, current_song_id,
           current_song_started_at, holder_since, holder_player_id
      into l
    from public.lobbies where id = NEW.lobby_id;

    if NEW.song_points > OLD.song_points then
      v_kind := case when NEW.song_points - OLD.song_points >= 1 then 'title' else 'artist' end;
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
  exception when others then
    -- Protokoll darf das Spiel niemals stören.
    raise warning 'game_events: %', sqlerrm;
  end;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS players_log_game_event ON public.players;
CREATE TRIGGER players_log_game_event
  AFTER UPDATE OF song_points, last_wrong_guess_at, is_alive ON public.players
  FOR EACH ROW
  WHEN (NEW.song_points > OLD.song_points
        OR (NEW.last_wrong_guess_at IS NOT NULL AND NEW.last_wrong_guess_at IS DISTINCT FROM OLD.last_wrong_guess_at)
        OR (OLD.is_alive AND NOT NEW.is_alive))
  EXECUTE FUNCTION public._trg_log_game_event();

-- ------------------------------------------------------------
-- 3) Konto-Verlauf (A, B, C, F) – dauerhaft
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_rounds (
  id               bigserial PRIMARY KEY,
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  match_id         uuid NOT NULL,
  lobby_code       text,
  round_index      integer NOT NULL,
  rounds_total     integer NOT NULL,
  played_at        timestamptz NOT NULL DEFAULT now(),
  playlist         text,
  place            integer,
  players_count    integer,
  humans_count     integer,
  bots_count       integer,
  arena_points     integer,
  song_points      numeric,
  title_hits       integer NOT NULL DEFAULT 0,
  artist_hits      integer NOT NULL DEFAULT 0,
  wrong_guesses    integer NOT NULL DEFAULT 0,
  answer_ms_sum    bigint NOT NULL DEFAULT 0,
  answer_count     integer NOT NULL DEFAULT 0,
  fastest_title_ms integer,
  best_combo       integer NOT NULL DEFAULT 0,
  ranked           boolean NOT NULL,
  UNIQUE (user_id, match_id, round_index)
);
CREATE INDEX IF NOT EXISTS account_rounds_user_idx ON public.account_rounds (user_id, played_at DESC);

CREATE TABLE IF NOT EXISTS public.account_matches (
  user_id        uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  match_id       uuid NOT NULL,
  lobby_code     text,
  finished_at    timestamptz NOT NULL DEFAULT now(),
  rounds_total   integer NOT NULL,
  place          integer NOT NULL,
  players_count  integer NOT NULL,
  humans_count   integer NOT NULL,
  bots_count     integer NOT NULL,
  total_points   integer NOT NULL,
  round_wins     integer NOT NULL,
  playlists      text[],
  title_hits     integer NOT NULL DEFAULT 0,
  artist_hits    integer NOT NULL DEFAULT 0,
  wrong_guesses  integer NOT NULL DEFAULT 0,
  ranked         boolean NOT NULL,
  PRIMARY KEY (user_id, match_id)
);
CREATE INDEX IF NOT EXISTS account_matches_user_idx ON public.account_matches (user_id, finished_at DESC);
CREATE INDEX IF NOT EXISTS account_matches_match_idx ON public.account_matches (match_id);

ALTER TABLE public.account_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_matches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_rounds_own ON public.account_rounds;
CREATE POLICY account_rounds_own ON public.account_rounds FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS account_matches_own ON public.account_matches;
CREATE POLICY account_matches_own ON public.account_matches FOR SELECT USING (auth.uid() = user_id);
REVOKE ALL ON public.account_rounds, public.account_matches FROM anon, authenticated;
GRANT SELECT ON public.account_rounds, public.account_matches TO authenticated;

-- ------------------------------------------------------------
-- 4) Achievements (D, F)
-- ------------------------------------------------------------
-- Unpassend fürs Musik-Spiel (0x freigeschaltet): Pass in < 500 ms ist mit Titel-Eintippen
-- kaum möglich, Pass-Zähler/Haltezeit ersetzt durch Musik-Achievements.
DELETE FROM public.achievements WHERE code IN ('speed_demon', 'first_pass', 'passes_100', 'passes_500', 'iron_lung');

-- games_played/wins zählen seit den Runden-Matches einzelne RUNDEN.
UPDATE public.achievements SET description = 'Gewinne deine erste Runde.' WHERE code = 'first_win';
UPDATE public.achievements SET description = 'Gewinne 5 Runden.' WHERE code = 'wins_5';
UPDATE public.achievements SET description = 'Gewinne 25 Runden.' WHERE code = 'wins_25';
UPDATE public.achievements SET description = 'Gewinne 100 Runden.' WHERE code = 'wins_100';
UPDATE public.achievements SET description = 'Spiele 10 Runden zu Ende.' WHERE code = 'games_10';
UPDATE public.achievements SET description = 'Spiele 50 Runden zu Ende.' WHERE code = 'games_50';

INSERT INTO public.achievements (code, title, description, icon, tier) VALUES
  ('music_first_title', 'Ohrwurm',        'Erkenne deinen ersten Songtitel.',                           '🎵', 'bronze'),
  ('music_titles_50',   'Plattensammler', 'Erkenne insgesamt 50 Songtitel.',                            '💿', 'silver'),
  ('music_titles_250',  'Musiklexikon',   'Erkenne insgesamt 250 Songtitel.',                           '📚', 'gold'),
  ('music_combo_5',     'Lauf',           'Erkenne 5 Titel in Folge in einer Runde.',                   '🔥', 'silver'),
  ('music_quick_ear',   'Blitzohr',       'Erkenne einen Titel in unter 3 Sekunden.',                   '⚡', 'silver'),
  ('music_genre_50',    'Genre-Kenner',   'Erkenne 50 Titel aus derselben Playlist.',                   '🎧', 'silver'),
  ('music_all_lists',   'Allrounder',     'Gewinne in jeder der 6 Playlists mindestens eine Runde.',    '🌈', 'gold'),
  ('match_win_3',       'Matchwinner',    'Gewinne ein Match über 3 Runden.',                           '🏁', 'silver'),
  ('match_win_5',       'Serienmeister',  'Gewinne ein Match über 5 Runden.',                           '👑', 'gold')
ON CONFLICT (code) DO UPDATE
  SET title = EXCLUDED.title, description = EXCLUDED.description, icon = EXCLUDED.icon, tier = EXCLUDED.tier;

CREATE OR REPLACE FUNCTION public._award_history_achievements(p_user_id uuid, p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_titles int; v_combo int; v_fastest int; v_genre int; v_lists int; v_win3 int; v_win5 int;
begin
  -- Nur gewertete Spiele (mind. 2 Menschen, siehe 075).
  select coalesce(sum(title_hits), 0), coalesce(max(best_combo), 0), min(fastest_title_ms)
    into v_titles, v_combo, v_fastest
  from public.account_rounds where user_id = p_user_id and ranked;

  select coalesce(max(t), 0) into v_genre
  from (select sum(title_hits) t from public.account_rounds
        where user_id = p_user_id and ranked group by playlist) x;

  select count(distinct playlist) into v_lists
  from public.account_rounds where user_id = p_user_id and ranked and place = 1 and playlist is not null;

  select count(*) filter (where rounds_total >= 3), count(*) filter (where rounds_total >= 5)
    into v_win3, v_win5
  from public.account_matches where user_id = p_user_id and ranked and place = 1;

  insert into public.player_achievements (user_id, achievement_code, lobby_id)
  select p_user_id, a.code, p_lobby_id
  from public.achievements a
  where (a.code = 'music_first_title' and v_titles >= 1)
     or (a.code = 'music_titles_50'   and v_titles >= 50)
     or (a.code = 'music_titles_250'  and v_titles >= 250)
     or (a.code = 'music_combo_5'     and v_combo >= 5)
     or (a.code = 'music_quick_ear'   and v_fastest is not null and v_fastest < 3000)
     or (a.code = 'music_genre_50'    and v_genre >= 50)
     or (a.code = 'music_all_lists'   and v_lists >= 6)
     or (a.code = 'match_win_3'       and v_win3 >= 1)
     or (a.code = 'match_win_5'       and v_win5 >= 1)
  on conflict (user_id, achievement_code) do nothing;
end;
$function$;

-- ------------------------------------------------------------
-- 5) Verlauf beim Rundenende schreiben
-- ------------------------------------------------------------
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
     humans_count, bots_count, arena_points, song_points, title_hits, artist_hits, wrong_guesses,
     answer_ms_sum, answer_count, fastest_title_ms, best_combo, ranked)
  select p.user_id, v_match, l.code, v_idx, v_total, l.topic_selected, sr.place, v_n,
         v_humans, v_bots, sr.arena_points, sr.song_points,
         coalesce(e.titles, 0), coalesce(e.artists, 0), coalesce(e.wrongs, 0),
         coalesce(e.ms_sum, 0), coalesce(e.ms_n, 0), e.fastest, coalesce(e.combo, 0), v_ranked
  from public.players p
  join public.profiles pr on pr.id = p.user_id
  join public.series_results sr
    on sr.lobby_id = p.lobby_id and sr.player_id = p.player_id and sr.set_index = v_idx
  left join lateral (
    select count(*) filter (where ge.kind = 'title')  as titles,
           count(*) filter (where ge.kind = 'artist') as artists,
           count(*) filter (where ge.kind = 'wrong')  as wrongs,
           sum(ge.ms) filter (where ge.kind in ('title', 'artist')) as ms_sum,
           count(ge.ms) filter (where ge.kind in ('title', 'artist')) as ms_n,
           min(ge.ms) filter (where ge.kind = 'title') as fastest,
           max(ge.combo) filter (where ge.kind = 'title') as combo
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
       total_points, round_wins, playlists, title_hits, artist_hits, wrong_guesses, ranked)
    select p.user_id, v_match, l.code, v_total, rk.mplace, rk.n, v_humans, v_bots,
           rk.total, rk.wins,
           (select array_agg(ar.playlist order by ar.round_index) from public.account_rounds ar
             where ar.user_id = p.user_id and ar.match_id = v_match),
           coalesce((select sum(ar.title_hits) from public.account_rounds ar where ar.user_id = p.user_id and ar.match_id = v_match), 0),
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

-- _finish_round: identisch zu 075, nur EIN abgesicherter Aufruf mehr (vor dem Phasenwechsel).
CREATE OR REPLACE FUNCTION public._finish_round(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_idx int; v_total int; v_winner uuid; v_n int;
  v_season text := to_char(now(), 'YYYY-MM');
  v_ranked boolean := public._lobby_human_count(p_lobby_id) >= 2;
  r record;
begin
  select series_index, series_total into v_idx, v_total from public.lobbies where id = p_lobby_id;

  select player_id into v_winner
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  limit 1;

  select count(*) into v_n from public.players where lobby_id = p_lobby_id and status = 'active';

  delete from public.series_results where lobby_id = p_lobby_id and set_index = v_idx;

  insert into public.series_results
    (lobby_id, set_index, player_id, name, place, arena_points, song_points, rounds_survived, passes, clutch, is_bot)
  select p_lobby_id, v_idx, t.player_id, t.name, t.place,
         (case when v_n > 1 then round(100.0 * (v_n - t.place) / (v_n - 1)) else 100 end)::int
           + round(t.song_points * 15)::int + t.clutch * 10,
         t.song_points, t.rounds_survived, t.passes, t.clutch, t.is_bot
  from (
    select p.player_id, p.name,
           row_number() over (
             order by (case when p.is_alive then 1 else 0 end) desc,
                      p.eliminated_at_round desc nulls last,
                      p.song_points desc, p.pass_count desc, p.seat_index
           )::int as place,
           coalesce(p.song_points, 0) as song_points,
           coalesce(p.eliminated_at_round, (select round_number from public.lobbies where id = p_lobby_id), 0) as rounds_survived,
           coalesce(p.pass_count, 0) as passes,
           coalesce(p.clutch_pass_count, 0) as clutch,
           coalesce(p.is_bot, false) as is_bot
    from public.players p
    where p.lobby_id = p_lobby_id and p.status = 'active'
  ) t;

  -- Saison-Punkte nur für eingeloggte Spieler und nur, wenn mind. 2 Menschen mitspielen (075).
  if v_ranked then
    for r in
      select p.user_id, sr.arena_points, sr.place
      from public.series_results sr
      join public.players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
      where sr.lobby_id = p_lobby_id and sr.set_index = v_idx and p.user_id is not null
    loop
      insert into public.season_points (user_id, season, arena_points, sets_played, set_wins)
      values (r.user_id, v_season, r.arena_points, 1, case when r.place = 1 then 1 else 0 end)
      on conflict (user_id, season) do update
        set arena_points = public.season_points.arena_points + excluded.arena_points,
            sets_played = public.season_points.sets_played + 1,
            set_wins = public.season_points.set_wins + excluded.set_wins,
            updated_at = now();
    end loop;
  end if;

  -- Konto-Verlauf (076). Darf das Rundenende niemals blockieren.
  begin
    perform public._record_round_history(p_lobby_id);
  exception when others then
    raise warning 'record_round_history: %', sqlerrm;
  end;

  if v_idx < v_total then
    -- Lebenslange Stats pro Durchgang mitzählen, bevor die Spielerwerte
    -- für den nächsten Durchgang zurückgesetzt werden.
    if v_ranked then
      begin
        perform public.aggregate_player_stats(p_lobby_id);
      exception when others then
        null;
      end;
    end if;

    update public.lobbies
    set phase = 'set_summary', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        countdown_started_at = now(), countdown_ends_at = now() + interval '12 seconds',
        last_activity_at = now()
    where id = p_lobby_id;
  else
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        current_attempt_id = null,
        holder_player_id = v_winner,
        last_activity_at = now()
    where id = p_lobby_id;
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public._record_round_history(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._award_history_achievements(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_log_game_event() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 6) Profil-Statistik für das eigene Konto (A, B, C, E, F)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_profile_stats(p_season text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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
               sum(title_hits)::int as titles, sum(artist_hits)::int as artists, sum(wrong_guesses)::int as wrong,
               count(*) filter (where place = 1)::int as wins
        from account_rounds where user_id = v_uid and playlist is not null
        group by playlist
      ) x
    ), '[]'::jsonb),
    -- A: letzte 20 Matches
    'recent', coalesce((
      select jsonb_agg(m order by m.finished_at desc) from (
        select finished_at, rounds_total, place, players_count, humans_count, bots_count,
               total_points, round_wins, playlists, title_hits, artist_hits, wrong_guesses, ranked
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

REVOKE ALL ON FUNCTION public.get_my_profile_stats(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_profile_stats(text) TO authenticated;

-- ------------------------------------------------------------
-- 7) Admin-Auswertungen (G, H, I) – nur Platform-Admins, Prüfung über auth.uid()
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._require_platform_admin()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where id = auth.uid() and coalesce(is_platform_admin, false)
  ) then
    raise exception 'not_authorized';
  end if;
end;
$function$;
REVOKE ALL ON FUNCTION public._require_platform_admin() FROM PUBLIC, anon, authenticated;

-- G: Wie gut wird jeder Song erkannt? (nur Menschen)
CREATE OR REPLACE FUNCTION public.admin_song_stats(p_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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
               round(avg(ms) filter (where kind = 'title'))::int as avg_ms
        from public.game_events
        where not is_bot and created_at > now() - make_interval(days => greatest(1, p_days))
        group by song_id
      ) e on e.song_id = sp.id
      where sp.plays > 0
    ) s
  ), '[]'::jsonb);
end;
$function$;

-- H: Balance aus echten Spielen
CREATE OR REPLACE FUNCTION public.admin_balance_stats(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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
               count(*) filter (where kind = 'title')::int as titles,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong,
               count(*) filter (where kind = 'exploded')::int as exploded,
               round(avg(ms) filter (where kind in ('title', 'artist')))::int as avg_answer_ms,
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
               count(*) filter (where kind in ('title', 'artist'))::int as answers,
               round(avg(ms) filter (where kind in ('title', 'artist')))::int as avg_answer_ms,
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
          having count(*) filter (where kind in ('title', 'artist')) > 0
        ) t
        group by 1
      ) w
    ), '[]'::jsonb),
    'playlists', coalesce((
      select jsonb_agg(p order by p.playlist) from (
        select playlist,
               count(*) filter (where kind = 'title')::int as titles,
               count(*) filter (where kind = 'artist')::int as artists,
               count(*) filter (where kind = 'wrong')::int as wrong
        from public.game_events where created_at > v_from and not is_bot and playlist is not null
        group by playlist
      ) p
    ), '[]'::jsonb)
  );
end;
$function$;

-- I: Weg der Spieler – anonyme Nutzungs-Ereignisse
CREATE TABLE IF NOT EXISTS public.funnel_events (
  id         bigserial PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  event      text NOT NULL,
  anon_id    text,
  props      jsonb
);
CREATE INDEX IF NOT EXISTS funnel_events_created_idx ON public.funnel_events (created_at);
CREATE INDEX IF NOT EXISTS funnel_events_anon_idx ON public.funnel_events (anon_id, created_at);
ALTER TABLE public.funnel_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.funnel_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.log_event(p_event text, p_anon text, p_props jsonb DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_event not in (
    'home_view', 'solo_start', 'solo_game_started', 'host_created', 'join_success', 'spectate',
    'game_finished', 'invite_share', 'invite_copy', 'invite_qr', 'result_share',
    'install_click', 'lang_en', 'register_success'
  ) then return; end if;
  if p_anon is null or length(p_anon) < 8 or length(p_anon) > 64 then return; end if;
  -- einfache Bremse gegen Spam: max. 120 Ereignisse pro Gerät und Stunde
  if (select count(*) from public.funnel_events
      where anon_id = p_anon and created_at > now() - interval '1 hour') >= 120 then
    return;
  end if;
  insert into public.funnel_events (event, anon_id, props)
  values (p_event, p_anon, case when p_props is null or pg_column_size(p_props) > 400 then null else p_props end);
end;
$function$;
REVOKE ALL ON FUNCTION public.log_event(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_event(text, text, jsonb) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_funnel(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public._require_platform_admin();
  return coalesce((
    select jsonb_agg(f order by f.devices desc) from (
      select event, count(*)::int as total, count(distinct anon_id)::int as devices
      from public.funnel_events
      where created_at > now() - make_interval(days => greatest(1, p_days))
        and coalesce(props ->> 'dev', 'false') <> 'true'
      group by event
    ) f
  ), '[]'::jsonb);
end;
$function$;

REVOKE ALL ON FUNCTION public.admin_song_stats(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_balance_stats(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_funnel(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_song_stats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_balance_stats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_funnel(integer) TO authenticated;

-- ------------------------------------------------------------
-- 8) Sicherheitsfix: rpc_get_admin_stats vertraute der mitgeschickten p_user_id.
--    Die Nutzer-IDs sind öffentlich lesbar (profiles.id) -> jeder konnte die Admin-Zahlen abrufen.
--    Jetzt muss p_user_id der eingeloggte Nutzer sein. Rest der Funktion unverändert.
-- ------------------------------------------------------------
DO $$
declare
  d text;
begin
  select pg_get_functiondef('public.rpc_get_admin_stats(uuid)'::regprocedure) into d;
  if position('if p_user_id is null then' in d) = 0 then
    raise exception 'rpc_get_admin_stats: erwartete Prüfung nicht gefunden';
  end if;
  d := replace(d, 'if p_user_id is null then', 'if p_user_id is null or p_user_id is distinct from auth.uid() then');
  execute d;
end $$;

-- ------------------------------------------------------------
-- 9) Aufräumen nach 90 Tagen (Rohdaten; Konto-Verlauf bleibt)
-- ------------------------------------------------------------
DO $$
begin
  if exists (select 1 from cron.job where jobname = 'kumpir-analytics-retention') then
    perform cron.unschedule('kumpir-analytics-retention');
  end if;
  perform cron.schedule(
    'kumpir-analytics-retention', '17 3 * * *',
    $job$delete from public.game_events where created_at < now() - interval '90 days';
         delete from public.funnel_events where created_at < now() - interval '90 days';$job$
  );
end $$;

COMMIT;
