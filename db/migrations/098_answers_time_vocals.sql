-- ============================================================
-- 098: Bessere Antwort-Erkennung, 1,5 Punkte für Titel + Künstler, mehr Zeit, Gesangsstart (2026-10-12)
-- ============================================================
-- Wünsche Mehdi:
--  * Feature-Partner wurden nicht erkannt: beim Playlist-Bau wurde "(feat. X)" aus dem Titel entfernt ->
--    neue Spalte song_pool.feat_artists (gefüllt von db/scripts/fetch-features.mjs, Daten-Migration 099).
--  * Schreibvarianten: Groß/klein, Umlaute (ä/a, ß/ss), Akzente, Satzzeichen, "&"/"und", Leerzeichen
--    ("capitalbra"), "feat." werden jetzt einheitlich behandelt (_ans_norm / _ans_close).
--  * Titel UND Künstler in einer Eingabe ("Wolke 7 Gzuz", "Gzuz - Wolke 7", "Wolke 7 von Gzuz") = 1,5 Punkte.
--    Mehrere Künstler auf einmal ("Kurdo & Dardan") zählen als Künstler (½ Punkt).
--  * Zeit: Echte Spieler brauchten seit 094 für den Künstler im Schnitt 7,0 s (90 %: 9,2 s), jede 4. Explosion
--    eines Menschen kam nach genau 7 s Schutzzeit. Schutzzeit jetzt 7/8/9 s (Blitz/Standard/Casual), min. 6 s.
--  * Netz-Toleranz: Die Kumpir platzt erst 0,4 s nach Ablauf – eine Antwort, die kurz vor Schluss abgeschickt
--    wurde und noch unterwegs ist, kommt so noch an (rpc_attempt_pass nimmt bis +0,5 s an).
--  * Gesang statt Intro: song_pool.vocal_start_ms = Stelle, an der in der Hörprobe der Gesang einsetzt
--    (db/scripts/vocal-start.py, Demucs). Der Browser spielt ab dort (Daten-Migration 099).
-- ============================================================
BEGIN;

ALTER TABLE public.song_pool
  ADD COLUMN IF NOT EXISTS feat_artists text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS vocal_start_ms int NOT NULL DEFAULT 0;
-- song_pool hat Spalten-Freigaben (Titel/Künstler bleiben für Clients gesperrt, Migration 063);
-- der Browser braucht nur die Startstelle. feat_artists bleibt gesperrt (wäre ein Hinweis auf die Lösung).
GRANT SELECT (vocal_start_ms) ON public.song_pool TO anon, authenticated;

-- ---------- Normalisierung ----------
CREATE OR REPLACE FUNCTION public._ans_norm(p text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s text := lower(coalesce(p, ''));
BEGIN
  s := regexp_replace(s, '\(.*?\)|\[.*?\]', ' ', 'g');
  s := replace(replace(s, 'ß', 'ss'), '$', 's');
  s := translate(s, 'äöüáàâãåāéèêëēíìîïıóòôõøúùûçñšşžćčđğ', 'aouaaaaaaeeeeeiiiiiooooouuucnsszccdg');
  s := regexp_replace(s, '\m(feat|ft|featuring)\M\.?', ' ', 'g');
  s := regexp_replace(s, '[^a-z0-9 ]+', ' ', 'g');
  s := regexp_replace(trim(s), '\s+', ' ', 'g');
  RETURN s;
END;
$$;

-- Sind zwei (normalisierte) Texte "gleich genug"? Auch ohne Leerzeichen und mit kleinen Tippfehlern.
CREATE OR REPLACE FUNCTION public._ans_close(p_a text, p_b text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  ca text; cb text; v_len int; v_th int;
BEGIN
  IF coalesce(p_a, '') = '' OR coalesce(p_b, '') = '' THEN RETURN false; END IF;
  IF p_a = p_b THEN RETURN true; END IF;
  ca := replace(p_a, ' ', ''); cb := replace(p_b, ' ', '');
  IF ca = cb THEN RETURN true; END IF;
  v_len := length(ca);
  v_th := CASE WHEN v_len <= 3 THEN 0 WHEN v_len <= 9 THEN 1 WHEN v_len <= 15 THEN 2 ELSE 3 END;
  IF v_th = 0 THEN RETURN false; END IF;
  RETURN levenshtein(ca, cb) <= v_th;
END;
$$;

-- Alle Künstlernamen eines Songs (normalisiert): Hauptkünstler, Mitwirkende, Feature-Partner
CREATE OR REPLACE FUNCTION public._song_artist_names(p_artist text, p_feat text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(array_agg(DISTINCT n) FILTER (WHERE n <> ''), '{}')
  FROM (
    SELECT public._ans_norm(x) AS n
    FROM unnest(regexp_split_to_array(coalesce(p_artist, ''), '\s*,\s*|\s*&\s*|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+und\s+', 'i')) AS x
    UNION ALL
    SELECT public._ans_norm(f) FROM unnest(coalesce(p_feat, '{}')) AS f
  ) t;
$$;

-- Besteht ein (normalisierter) Text nur aus Künstlernamen dieses Songs? ("eno nimo", "kurdo und dardan")
CREATE OR REPLACE FUNCTION public._only_artist_names(p_text text, p_names text[])
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text := ' ' || coalesce(p_text, '') || ' ';
  n text;
BEGIN
  IF coalesce(p_text, '') = '' THEN RETURN false; END IF;
  FOR n IN SELECT x FROM unnest(p_names) x WHERE x <> '' ORDER BY length(x) DESC LOOP
    v := replace(v, ' ' || n || ' ', '  ');
  END LOOP;
  v := regexp_replace(v, '\s(und|x|feat|ft|mit|von|by)\s', '  ', 'g');
  RETURN trim(v) = '';
END;
$$;

-- Bewertung einer Antwort: 1,5 = Titel + Künstler, 1 = Titel, 0,5 = Künstler, 0 = falsch
CREATE OR REPLACE FUNCTION public._score_song_answer(p_title text, p_artist text, p_feat text[], p_answer text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  a text := public._ans_norm(p_answer);
  t text := public._ans_norm(p_title);
  full_artist text := public._ans_norm(p_artist);
  names text[] := public._song_artist_names(p_artist, p_feat);
  conn text := '^(von|by|x|und|mit|feat|ft|from|ist|is)\s+|\s+(von|by|x|und|mit|feat|ft|from)$';
  n text; rest text; parts text[]; part text; ok boolean;
BEGIN
  IF a = '' OR t = '' THEN RETURN 0; END IF;

  -- nur der Titel
  IF public._ans_close(t, a) THEN RETURN 1; END IF;

  -- Titel + Künstler: Künstler (exakt, normalisiert) vorne oder hinten, der Rest ist der Titel (mit Tippfehler-Toleranz)
  FOREACH n IN ARRAY array_append(names, full_artist) LOOP
    CONTINUE WHEN n = '' OR length(a) <= length(n) + 1;
    rest := NULL;
    IF a LIKE n || ' %' THEN rest := substr(a, length(n) + 2);
    ELSIF a LIKE '% ' || n THEN rest := left(a, length(a) - length(n) - 1);
    END IF;
    CONTINUE WHEN rest IS NULL;
    rest := trim(regexp_replace(rest, conn, '', 'g'));
    IF public._ans_close(t, rest) THEN RETURN 1.5; END IF;
  END LOOP;

  -- Titel (exakt) vorne oder hinten, der Rest ist ein Künstler (mit Tippfehler-Toleranz)
  rest := NULL;
  IF length(a) > length(t) + 1 THEN
    IF a LIKE t || ' %' THEN rest := substr(a, length(t) + 2);
    ELSIF a LIKE '% ' || t THEN rest := left(a, length(a) - length(t) - 1);
    END IF;
  END IF;
  IF rest IS NOT NULL THEN
    rest := trim(regexp_replace(rest, conn, '', 'g'));
    IF public._ans_close(full_artist, rest) OR public._only_artist_names(rest, names) THEN RETURN 1.5; END IF;
    FOREACH n IN ARRAY names LOOP
      IF public._ans_close(n, rest) THEN RETURN 1.5; END IF;
    END LOOP;
  END IF;

  -- nur Künstler: ein Name, alle Namen zusammen oder mehrere Namen aufgezählt ("Kurdo & Dardan", "Kurdo, Dardan")
  IF public._ans_close(full_artist, a) OR public._only_artist_names(a, names) THEN RETURN 0.5; END IF;
  FOREACH n IN ARRAY names LOOP
    IF public._ans_close(n, a) THEN RETURN 0.5; END IF;
  END LOOP;
  parts := regexp_split_to_array(lower(coalesce(p_answer, '')), '\s*,\s*|\s*&\s*|\s*\+\s*|\s+x\s+|\s+und\s+|\s+feat\.?\s+|\s+ft\.?\s+');
  IF array_length(parts, 1) > 1 THEN
    ok := true;
    FOREACH part IN ARRAY parts LOOP
      part := public._ans_norm(part);
      CONTINUE WHEN part = '';
      IF NOT EXISTS (SELECT 1 FROM unnest(names) x WHERE public._ans_close(x, part)) THEN ok := false; EXIT; END IF;
    END LOOP;
    IF ok THEN RETURN 0.5; END IF;
  END IF;

  RETURN 0;
END;
$$;

-- ---------- Schutzzeit 7/8/9 s, min. 6 s ----------
CREATE OR REPLACE FUNCTION public.calc_pass_grace_seconds(p_round_speed text, p_used int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(6,
    (CASE p_round_speed WHEN 'fast' THEN 7 WHEN 'calm' THEN 9 ELSE 8 END) - greatest(0, coalesce(p_used, 0))
  )::numeric;
$$;

-- ---------- Antwort prüfen (neue Bewertung) ----------
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(p_code text, p_player_id uuid, p_answer text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_song_title text;
  v_song_artist text;
  v_song_feat text[];
  v_plays int; v_hits int;
  v_points numeric;
  v_last_wrong timestamptz;
  v_quality numeric := 1;
  v_diff numeric := 1;
  v_combo int := 0;
  v_combo_bonus numeric := 0;
  v_is_bot boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  if v_lobby.explode_at is not null and now() > v_lobby.explode_at + interval '500 milliseconds' then
    raise exception 'time_up';
  end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if v_lobby.current_song_id is null and exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  if v_lobby.current_song_id is not null then
    select last_wrong_guess_at, combo, coalesce(is_bot, false) into v_last_wrong, v_combo, v_is_bot
    from public.players where lobby_id = v_lobby.id and player_id = p_player_id;
    if v_last_wrong is not null and now() < v_last_wrong + interval '1 second' then
      raise exception 'too_fast';
    end if;

    select title, artist, feat_artists, plays, hits into v_song_title, v_song_artist, v_song_feat, v_plays, v_hits
    from public.song_pool where id = v_lobby.current_song_id;

    v_points := public._score_song_answer(v_song_title, v_song_artist, v_song_feat, v_clean);

    -- Nachspielzeit (094): nur der Interpret reicht nicht -> kein Fehlversuch, nur Hinweis
    if v_points = 0.5 and coalesce(v_lobby.grace_count, 0) > 0 then
      raise exception 'overtime_title_only';
    end if;

    if v_points = 0 then
      update public.players set last_wrong_guess_at = now(), combo = 0
      where lobby_id = v_lobby.id and player_id = p_player_id;
      return null;
    end if;

    -- Bonuszeit-Faktor wie bisher (Titel 1 / Interpret 0.5), Titel + Künstler zählt wie Titel
    v_quality := least(v_points, 1);
    v_diff := case public._song_difficulty(v_plays, v_hits) when 1 then 0.8 when 3 then 1.3 else 1.0 end;

    if v_points >= 1 then
      v_combo := coalesce(v_combo, 0) + 1;
      v_combo_bonus := case when v_combo >= 2 then least(2, 0.5 * (v_combo - 1)) else 0 end;
      if not coalesce(v_is_bot, false) then
        update public.song_pool set hits = hits + 1 where id = v_lobby.current_song_id;
      end if;
    else
      v_combo := 0;
    end if;

    update public.players
    set song_points = song_points + v_points, combo = v_combo
    where lobby_id = v_lobby.id and player_id = p_player_id;
  end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies
  set current_attempt_id = v_attempt, last_pass_quality = v_quality,
      last_pass_diff = v_diff, last_pass_combo_bonus = v_combo_bonus
  where id = v_lobby.id;

  perform public._finalize_attempt_accept(v_attempt);

  return v_attempt;
end;
$function$;

-- ---------- Netz-Toleranz: erst 0,4 s nach Ablauf platzen ----------
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int; v_dir int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, pass_direction
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_dir
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  -- 098: Antworten, die kurz vor Schluss abgeschickt wurden, haben 0,4 s Zeit anzukommen
  if v_now < v_explode_at + interval '400 milliseconds' then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0, combo = 0
  where lobby_id = v_lobby_id and player_id = v_loser;

  update public.players
  set survival_streak = survival_streak + 1
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  update public.lobbies
  set round_number = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at = v_now
  where id = v_lobby_id
  returning round_number into v_round_number;

  update public.players
  set eliminated_at_round = v_round_number
  where lobby_id = v_lobby_id and player_id = v_loser;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    perform public._finish_round(v_lobby_id);
    return;
  end if;

  v_next_holder := public._next_alive(v_lobby_id, v_loser, case when v_game_mode = 'original' then v_dir else 1 end);

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true and player_id != v_loser
    order by random() limit 1;
  end if;

  v_round_duration := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'),
    v_alive_count,
    coalesce(v_round_number, 1)
  ) * interval '1 second';

  update public.lobbies
  set holder_player_id = v_next_holder,
      explode_at = v_now + v_round_duration,
      round_bonus_used = 0,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
end;
$function$;

COMMIT;
