-- ============================================================
-- Migration 075: Spiele gegen Bots zählen nicht für Bestenliste/Statistik
-- ============================================================
-- Mit "Solo gegen Bots" (ein Tipp, 3 schwache/mittlere Bots) konnte man sich
-- Saison-Punkte, Siege und Achievements beliebig erspielen. Ab jetzt werden
-- season_points und player_lifetime_stats (inkl. Achievements) nur noch
-- gutgeschrieben, wenn mindestens 2 Menschen in der Lobby mitgespielt haben
-- (Menschen, die mittendrin gegangen sind, zählen mit).
--
-- Spielablauf unverändert: series_results (Zwischenstand/Endstand) wird wie
-- bisher geschrieben, Phasenwechsel identisch zur Live-Version aus 062.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._lobby_human_count(p_lobby_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select count(*)::int from public.players
  where lobby_id = p_lobby_id and not coalesce(is_bot, false);
$function$;

REVOKE ALL ON FUNCTION public._lobby_human_count(uuid) FROM PUBLIC, anon, authenticated;

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

CREATE OR REPLACE FUNCTION public.trg_aggregate_on_finished()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.phase = 'finished' AND (OLD.phase IS DISTINCT FROM NEW.phase)
       AND public._lobby_human_count(NEW.id) >= 2 THEN
        PERFORM public.aggregate_player_stats(NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
