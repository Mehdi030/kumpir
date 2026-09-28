-- ============================================================
-- Migration 029: Song-Raten statt Ambient-Playlist im Musik-Modus
-- ============================================================
-- Bisher: die 4 Musik-Kategorien (Deutschrap-Songs, Deutschrap
-- Klassiker, Englische All-Time-Hits, Internationale Pop-Charts)
-- betteten nur eine Spotify-Playlist als Dauerberieselung ein --
-- Spotifys Embed-Widget zeigt den Songnamen aber IMMER sichtbar an,
-- das lässt sich nicht unterdrücken. Für ein echtes "errate den Song"
-- braucht es eine Audioquelle ohne sichtbaren Titel.
--
-- Neu: song_pool -- pro Musik-Kategorie eine Liste echter Songtitel
-- (aus den bereits kuratierten Antworten von Migration 027 übernommen).
-- lobbies.current_song_id zeigt auf den GENAU EINEN Song, den der
-- aktuelle Halter gerade "hat". Der Client rendert den Titel nirgends,
-- sondern nutzt title+artist nur als Suchbegriff für einen 30s-Preview-
-- Clip von der iTunes Search API (öffentlich, kein API-Key, CORS offen
-- -- curl-verifiziert). Die Antwort-Prüfung läuft weiterhin serverseitig
-- gegen den in song_pool gespeicherten Titel.
--
-- Rotation: ein neuer Song wird gezogen bei Rundenstart
-- (rpc_advance_from_countdown), bei jedem erfolgreichen Pass
-- (rpc_pass_potato) und bei jeder Explosion/Elimination
-- (rpc_tick_game) -- also genau dann, wenn der Halter wechselt.
-- Bereits gespielte Songs merkt sich lobbies.used_song_ids und wird
-- beim Ziehen ausgeschlossen, damit derselbe Song nicht zweimal im
-- selben Match drankommt.
--
-- Transparenz-Hinweis: song_pool ist wie topic_answers (Migration 027)
-- bewusst normal SELECT-lesbar (RLS "for all") -- der Titel wird nie
-- im UI gerendert, ist über die Netzwerk-Konsole aber technisch
-- einsehbar, genau wie die bestehende Antwort-Datenbank. Für "wirklich
-- unmöglich nachzuschauen" bräuchte es einen Service-Role-Server-Call;
-- das ist hier bewusst nicht gebaut, um keinen neuen Secret-Typ in die
-- bislang rein Anon-Key-basierte Architektur einzuführen.
-- ============================================================

BEGIN;

ALTER TABLE public.topic_pool
    ADD COLUMN IF NOT EXISTS is_song_category BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.topic_pool
SET is_song_category = TRUE
WHERE text IN ('Deutschrap-Songs', 'Deutschrap Klassiker', 'Englische All-Time-Hits', 'Internationale Pop-Charts');

CREATE TABLE IF NOT EXISTS public.song_pool (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic_pool_id  UUID NOT NULL REFERENCES public.topic_pool(id) ON DELETE CASCADE,
    title          TEXT NOT NULL,
    artist         TEXT,
    lower_title    TEXT GENERATED ALWAYS AS (lower(title)) STORED,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (topic_pool_id, lower_title)
);

ALTER TABLE public.song_pool ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS song_pool_select_all ON public.song_pool;
CREATE POLICY song_pool_select_all ON public.song_pool FOR SELECT USING (true);

GRANT SELECT ON public.song_pool TO anon, authenticated;

-- Seed: Titel 1:1 aus der bereits kuratierten Antwort-Datenbank
-- (Migration 027) übernommen, Künstler wo sicher bekannt ergänzt --
-- fehlende Künstler sind kein Problem, die iTunes-Suche läuft auch
-- mit Titel allein (ggf. etwas unschärfer beim Treffer).
INSERT INTO public.song_pool (topic_pool_id, title, artist)
SELECT tp.id, v.title, v.artist
FROM (VALUES
    ('Deutschrap-Songs', 'Tequila', 'Eno feat. Bonez MC & Gzuz'),
    ('Deutschrap-Songs', 'Wolke 10', 'Apache 207'),
    ('Deutschrap-Songs', 'Puuh Bär', NULL),
    ('Deutschrap-Songs', 'Rockstar', 'Ufo361'),
    ('Deutschrap-Songs', 'Athen', 'Apache 207'),
    ('Deutschrap-Songs', 'Neymar', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Millionär', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Blaulicht', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Vermissen', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Dior', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Bonez MC', NULL),
    ('Deutschrap-Songs', 'Gangsta Rap', NULL),
    ('Deutschrap-Songs', 'Willst du', 'Bausa'),
    ('Deutschrap-Songs', 'Anfang', NULL),
    ('Deutschrap-Songs', 'Powergirl', NULL),
    ('Deutschrap-Songs', 'Meine Soldaten', NULL),
    ('Deutschrap-Songs', 'Roller', 'Apache 207'),
    ('Deutschrap-Songs', 'Blackout', NULL),
    ('Deutschrap-Songs', 'Palmen aus Plastik', 'Bonez MC & RAF Camora'),
    ('Deutschrap-Songs', 'Nicht verdient', NULL),
    ('Deutschrap-Songs', '3 Millionen', NULL),
    ('Deutschrap-Songs', 'Nightliner', NULL),
    ('Deutschrap-Songs', 'Nur noch Gangster', NULL),
    ('Deutschrap-Songs', 'Nummer 1', NULL),
    ('Deutschrap-Songs', 'Nicht so wichtig', NULL),
    ('Deutschrap-Songs', 'Nur für dich', NULL),
    ('Deutschrap Klassiker', 'Halt dich fest', 'Marteria'),
    ('Deutschrap Klassiker', 'Wilma rennt', 'Seeed'),
    ('Deutschrap Klassiker', 'Für immer jung', NULL),
    ('Deutschrap Klassiker', '1000 PS', 'Kollegah & Farid Bang'),
    ('Deutschrap Klassiker', 'Wer hat Angst vorm schwarzen Mann', 'Fettes Brot'),
    ('Deutschrap Klassiker', 'Wo ist das Geld', 'Bushido'),
    ('Deutschrap Klassiker', 'Berlin lebt', 'Bushido'),
    ('Deutschrap Klassiker', 'Alles auf Rot', 'Sido'),
    ('Deutschrap Klassiker', 'Bilder im Kopf', 'Kontra K'),
    ('Deutschrap Klassiker', 'Frei sein', 'Kontra K'),
    ('Deutschrap Klassiker', 'Phantom', 'Sido'),
    ('Deutschrap Klassiker', 'Adrenalin', 'Bushido'),
    ('Deutschrap Klassiker', 'Vermissen', 'Bonez MC & RAF Camora'),
    ('Deutschrap Klassiker', 'Prinzessin', 'Fler'),
    ('Deutschrap Klassiker', 'Willkommen im Bundestag', 'Deichkind'),
    ('Deutschrap Klassiker', 'Aggro Ansage Nr.1', NULL),
    ('Deutschrap Klassiker', 'Bild dir deine Meinung', 'Fettes Brot'),
    ('Deutschrap Klassiker', 'Denkmal', 'Sido'),
    ('Deutschrap Klassiker', 'Wilder Wilder Westen', 'Peter Fox'),
    ('Deutschrap Klassiker', 'Party Prinzessin', NULL),
    ('Englische All-Time-Hits', 'Bohemian Rhapsody', 'Queen'),
    ('Englische All-Time-Hits', 'Billie Jean', 'Michael Jackson'),
    ('Englische All-Time-Hits', 'Rolling in the Deep', 'Adele'),
    ('Englische All-Time-Hits', 'Shape of You', 'Ed Sheeran'),
    ('Englische All-Time-Hits', 'Blinding Lights', 'The Weeknd'),
    ('Englische All-Time-Hits', 'Someone Like You', 'Adele'),
    ('Englische All-Time-Hits', 'Sweet Child O'' Mine', 'Guns N'' Roses'),
    ('Englische All-Time-Hits', 'Smells Like Teen Spirit', 'Nirvana'),
    ('Englische All-Time-Hits', 'Hotel California', 'Eagles'),
    ('Englische All-Time-Hits', 'I Want It That Way', 'Backstreet Boys'),
    ('Englische All-Time-Hits', 'Uptown Funk', 'Mark Ronson feat. Bruno Mars'),
    ('Englische All-Time-Hits', 'Umbrella', 'Rihanna'),
    ('Englische All-Time-Hits', 'Poker Face', 'Lady Gaga'),
    ('Englische All-Time-Hits', 'Firework', 'Katy Perry'),
    ('Englische All-Time-Hits', 'Radioactive', 'Imagine Dragons'),
    ('Englische All-Time-Hits', 'Thinking Out Loud', 'Ed Sheeran'),
    ('Englische All-Time-Hits', 'Shake It Off', 'Taylor Swift'),
    ('Englische All-Time-Hits', 'Stayin'' Alive', 'Bee Gees'),
    ('Englische All-Time-Hits', 'Like a Prayer', 'Madonna'),
    ('Englische All-Time-Hits', 'Wonderwall', 'Oasis'),
    ('Internationale Pop-Charts', 'Espresso', 'Sabrina Carpenter'),
    ('Internationale Pop-Charts', 'Flowers', 'Miley Cyrus'),
    ('Internationale Pop-Charts', 'As It Was', 'Harry Styles'),
    ('Internationale Pop-Charts', 'Anti-Hero', 'Taylor Swift'),
    ('Internationale Pop-Charts', 'Cruel Summer', 'Taylor Swift'),
    ('Internationale Pop-Charts', 'Levitating', 'Dua Lipa'),
    ('Internationale Pop-Charts', 'Peaches', 'Justin Bieber'),
    ('Internationale Pop-Charts', 'Watermelon Sugar', 'Harry Styles'),
    ('Internationale Pop-Charts', 'Good 4 U', 'Olivia Rodrigo'),
    ('Internationale Pop-Charts', 'Stay', 'The Kid LAROI & Justin Bieber'),
    ('Internationale Pop-Charts', 'Circles', 'Post Malone'),
    ('Internationale Pop-Charts', 'Blinding Lights', 'The Weeknd'),
    ('Internationale Pop-Charts', 'Kill Bill', 'SZA'),
    ('Internationale Pop-Charts', 'Vampire', 'Olivia Rodrigo'),
    ('Internationale Pop-Charts', 'Greedy', 'Tate McRae'),
    ('Internationale Pop-Charts', 'Lose Control', 'Teddy Swims'),
    ('Internationale Pop-Charts', 'Die With a Smile', 'Lady Gaga & Bruno Mars'),
    ('Internationale Pop-Charts', 'Birds of a Feather', 'Billie Eilish'),
    ('Internationale Pop-Charts', 'Houdini', 'Dua Lipa')
) AS v(category, title, artist)
JOIN public.topic_pool tp ON tp.text = v.category
ON CONFLICT (topic_pool_id, lower_title) DO NOTHING;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS current_song_id UUID REFERENCES public.song_pool(id),
    ADD COLUMN IF NOT EXISTS used_song_ids UUID[] NOT NULL DEFAULT '{}';

-- Zieht (falls das aktuelle Thema eine Musik-Kategorie ist) einen neuen,
-- in diesem Match noch nicht gespielten Song und setzt current_song_id.
-- Kein Song-Thema -> current_song_id wird genullt. Aufrufer hält die
-- Lobby-Row bereits per FOR UPDATE (rpc_advance_from_countdown,
-- rpc_pass_potato, rpc_tick_game locken schon vor ihrem Aufruf).
CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid;
begin
  select topic_selected, used_song_ids into v_topic, v_used
  from public.lobbies where id = p_lobby_id;

  select tp.id into v_topic_pool_id
  from public.topic_pool tp
  where tp.is_song_category is true and lower(tp.text) = lower(coalesce(v_topic, ''));

  if v_topic_pool_id is null then
    update public.lobbies set current_song_id = null where id = p_lobby_id;
    return;
  end if;

  select sp.id into v_song_id
  from public.song_pool sp
  where sp.topic_pool_id = v_topic_pool_id
    and not (sp.id = any(coalesce(v_used, '{}')))
  order by random() limit 1;

  -- Songs im Match aufgebraucht -> Pool für dieses Match wieder freigeben.
  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
    order by random() limit 1;
    v_used := '{}';
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

-- rpc_advance_from_countdown: ersten Song fürs Match ziehen.
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
begin
  select round_speed, coalesce(round_number, 0)
    into v_round_speed, v_round_number
  from public.lobbies where id = p_lobby_id for update;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  select player_id into v_holder
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true
  order by random() limit 1;

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
      used_answers = '{}',
      used_song_ids = '{}',
      current_attempt_id = null,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- rpc_pass_potato: bei jedem erfolgreichen Pass den nächsten Song ziehen.
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_last_pass timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
  from public.lobbies l
  where l.code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;

  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;

  if v_holder is null or v_holder <> p_player_id then
    raise exception 'Not holder';
  end if;

  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index) into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- Mode-aware next holder
  if v_mode = 'teleport' then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id
      and p.status = 'active' and p.is_alive = true
      and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then return; end if;

  elsif v_mode = 'reverse' then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];

  else
    next_idx := idx + 1;
    if next_idx > n then next_idx := 1; end if;
    v_next := alive_ids[next_idx];
  end if;

  update public.lobbies set holder_player_id = v_next, last_activity_at = v_now where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  -- Stats tracking
  select last_pass_at into v_last_pass from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms from public.lobbies where id = v_lobby_id;
  end if;

  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set pass_count = coalesce(pass_count, 0) + 1,
      last_pass_at = v_now,
      total_hold_ms = coalesce(total_hold_ms, 0) + v_pass_ms,
      fastest_pass_ms = case
        when fastest_pass_ms is null then v_pass_ms
        when v_pass_ms < fastest_pass_ms then v_pass_ms
        else fastest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

-- rpc_tick_game: bei jeder Explosion/Elimination den nächsten Song ziehen.
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_lobby_id uuid; v_phase text; v_holder uuid; v_explode_at timestamptz; v_game_mode text;
  v_round_speed text; v_round_number int;
  v_alive_count int; v_loser uuid; v_next_holder uuid;
  v_round_duration interval;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed
  from public.lobbies where code = upper(p_code) for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if v_phase is distinct from 'running' then return; end if;
  if v_explode_at is null then return; end if;
  if v_now < v_explode_at then return; end if;

  v_loser := v_holder;
  if v_loser is null then return; end if;

  update public.players
  set is_alive = false, survival_streak = 0
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

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase = 'finished', explode_at = null, current_song_id = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  -- Nächster alive Spieler nach Loser (seat_index aufsteigend)
  select p2.player_id into v_next_holder
  from public.players p_loser
  join public.players p2 on p2.lobby_id = p_loser.lobby_id
    and p2.status = 'active' and p2.is_alive = true
    and p2.seat_index > p_loser.seat_index
  where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
  order by p2.seat_index asc limit 1;

  if v_next_holder is null then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active' and is_alive = true
    order by seat_index asc limit 1;
  end if;

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
      pass_direction = case
        when v_game_mode = 'reverse' then (pass_direction * -1)::smallint
        else pass_direction
      end
  where id = v_lobby_id;

  perform public._pick_next_song(v_lobby_id);
end;
$function$;

-- rpc_attempt_pass: bei aktivem Song-Modus gegen den EINEN aktuellen Song
-- prüfen statt gegen die ganze Kategorie-Antwortliste.
CREATE OR REPLACE FUNCTION public.rpc_attempt_pass(
    p_code TEXT, p_player_id UUID, p_answer TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_lobby public.lobbies%ROWTYPE;
  v_attempt uuid;
  v_clean text;
  v_topic text;
  v_known boolean;
begin
  select * into v_lobby from public.lobbies where code = upper(p_code) for update;
  if not found then raise exception 'lobby_not_found'; end if;

  if not public._verify_session(v_lobby.id, p_player_id) then
    raise exception 'invalid_session';
  end if;

  if v_lobby.phase <> 'running' then raise exception 'lobby_not_running'; end if;
  if v_lobby.holder_player_id <> p_player_id then raise exception 'not_holder'; end if;
  if v_lobby.current_attempt_id is not null then raise exception 'attempt_already_open'; end if;

  v_clean := trim(p_answer);
  if length(v_clean) = 0 then raise exception 'empty_answer'; end if;
  if length(v_clean) > 60 then raise exception 'answer_too_long'; end if;

  if exists (
    select 1 from unnest(v_lobby.used_answers) as used
    where lower(used) = lower(v_clean)
  ) then raise exception 'answer_already_used'; end if;

  v_topic := coalesce(v_lobby.topic_selected, v_lobby.topic, '');

  insert into public.pass_attempts (lobby_id, round_number, holder_player_id, answer, topic)
    values (v_lobby.id, coalesce(v_lobby.round_number, 0), p_player_id, v_clean, v_topic)
    returning id into v_attempt;

  update public.lobbies set current_attempt_id = v_attempt where id = v_lobby.id;

  if v_lobby.current_song_id is not null then
    -- Song-Modus: gegen genau den einen aktuellen Song prüfen (Klammer-
    -- Zusätze wie "(feat. ...)" werden toleriert, exakte Interpreten-
    -- Schreibweise wird nicht verlangt).
    select exists (
      select 1 from public.song_pool sp
      where sp.id = v_lobby.current_song_id
        and (
          sp.lower_title = lower(v_clean)
          or regexp_replace(sp.lower_title, '\s*\(.*?\)\s*', '', 'g') = lower(v_clean)
        )
    ) into v_known;
  else
    -- Antwort-Datenbank: bekannte, korrekte Antwort -> sofort annehmen,
    -- kein Voting nötig. _finalize_attempt_accept setzt current_attempt_id
    -- selbst wieder auf null und stößt rpc_pass_potato an.
    select exists (
      select 1
      from public.topic_answers ta
      join public.topic_pool tp on tp.id = ta.topic_pool_id
      where lower(tp.text) = lower(v_topic)
        and ta.lower_answer = lower(v_clean)
    ) into v_known;
  end if;

  if v_known then
    perform public._finalize_attempt_accept(v_attempt);
  end if;

  return v_attempt;
end;
$function$;

COMMIT;
