-- ============================================================
-- 092: Bots raten meist den Künstler, Liste der erratenen Songs, keine Song-Wiederholung im Match,
--      Lobby-Einladungen an Freunde (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- 1) Bots: Wenn ein Bot etwas errät, nennt er zu 70–80 % den Künstler (½ Punkt) und nur zu 20–30 %
--    den Titel – vorher nannten Bots fast immer den Titel (zu stark):
--    Anfänger 80 % Künstler · Mittel 75 % · Profi 70 %.
-- 2) "Schon gesagt": statt der getippten Eingabe steht dort der richtige Song: "Titel – Künstler"
--    (inkl. Feature-Künstler, so wie er in der Song-Liste steht).
-- 3) Songs wiederholen sich innerhalb eines Matches nicht mehr (3 oder 5 Runden): die Liste der
--    gespielten Songs wird nur noch beim ersten Durchgang eines Matches geleert.
-- 4) Lobby-Einladungen: Wer in einer Lobby ist, kann Freunde einladen; der Freund bekommt ein
--    Pop-up "X hat dich eingeladen" mit Beitreten / Nicht beitreten.
-- ============================================================
BEGIN;

-- ------------------------------------------------------------ 1) Bots
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
    select l.id as lobby_id, p.player_id, l.topic_vote_started_at, l.topic_vote_cards
    from public.lobbies l
    join public.players p on p.lobby_id = l.id and p.is_bot = true and p.status = 'active'
    where l.phase = 'topic_vote' and l.topic_vote_started_at is not null
      and not exists (select 1 from public.topic_votes v where v.lobby_id = l.id and v.player_id = p.player_id)
  loop
    v_seed := r.player_id::text || r.topic_vote_started_at::text;
    v_delay := 1.0 + (abs(hashtext(v_seed)) % 2500) / 1000.0;
    if now() - r.topic_vote_started_at >= v_delay * interval '1 second' then
      insert into public.topic_votes (lobby_id, player_id, choice)
      values (r.lobby_id, r.player_id, 1 + (abs(hashtext('c' || v_seed)) % greatest(1, least(3, r.topic_vote_cards))))
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

    -- Migration 092: meist den Künstler (½ Punkt), seltener den Titel
    v_artist_chance := case r.skill when 1 then 0.80 when 3 then 0.70 else 0.75 end;

    v_answer := null;
    if r.current_song_id is not null then
      if (abs(hashtext('a' || v_seed)) % 1000) / 1000.0 < v_artist_chance then
        select trim(split_part(split_part(artist, ',', 1), '&', 1)) into v_answer from public.song_pool where id = r.current_song_id;
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

-- ------------------------------------------------------------ 2) Erratene Songs
CREATE OR REPLACE FUNCTION public._finalize_attempt_accept(p_attempt_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_attempt   public.pass_attempts%ROWTYPE;
    v_lobby     public.lobbies%ROWTYPE;
    v_code      TEXT;
    v_shown     TEXT;
BEGIN
    SELECT * INTO v_attempt FROM public.pass_attempts WHERE id = p_attempt_id;
    SELECT * INTO v_lobby FROM public.lobbies WHERE id = v_attempt.lobby_id;
    v_code := v_lobby.code;

    -- Song-Runde: den richtigen Song zeigen ("Titel – Künstler"), nicht die Eingabe
    v_shown := v_attempt.answer;
    IF v_lobby.current_song_id IS NOT NULL THEN
        SELECT sp.title || ' – ' || sp.artist INTO v_shown FROM public.song_pool sp WHERE sp.id = v_lobby.current_song_id;
        v_shown := coalesce(v_shown, v_attempt.answer);
    END IF;

    UPDATE public.pass_attempts
    SET status = 'accepted', decided_at = NOW()
    WHERE id = p_attempt_id;

    UPDATE public.lobbies
    SET current_attempt_id = NULL,
        used_answers = array_append(used_answers, v_shown)
    WHERE id = v_lobby.id;

    -- Bestehende rpc_pass_potato hält die Logik (next holder, stats etc.)
    PERFORM public.rpc_pass_potato(v_code, v_attempt.holder_player_id);
END;
$function$;

-- ------------------------------------------------------------ 3) Keine Wiederholung im Match
CREATE OR REPLACE FUNCTION public.rpc_advance_from_countdown(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_holder uuid;
  v_alive_count int;
  v_round_speed text;
  v_round_number int;
  v_explode_seconds numeric;
  v_phase text;
begin
  select phase, round_speed, coalesce(round_number, 0), countdown_starter_player_id
    into v_phase, v_round_speed, v_round_number, v_holder
  from public.lobbies where id = p_lobby_id for update;

  if v_phase is distinct from 'countdown' then return; end if;
  if coalesce(current_setting('request.headers', true), '') <> '' and exists (select 1 from public.lobbies where id = p_lobby_id and countdown_ends_at > now() + interval '1 second') then return; end if;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = p_lobby_id and status = 'active' and is_alive = true;

  if v_holder is null or not exists (
    select 1 from public.players
    where lobby_id = p_lobby_id and player_id = v_holder and status = 'active' and is_alive = true
  ) then
    select player_id into v_holder
    from public.players
    where lobby_id = p_lobby_id and status = 'active' and is_alive = true
    order by random() limit 1;
  end if;

  if v_holder is null then raise exception 'Kein Startspieler gefunden'; end if;

  -- Faire Weitergabe-Reihenfolge: Sitzplätze zufällig mischen.
  with act as (
    select player_id, seat_index as old_seat,
           row_number() over (order by seat_index) as rk
    from public.players
    where lobby_id = p_lobby_id and status = 'active'
  ), shuf as (
    select player_id, row_number() over (order by random()) as rk from act
  ), pick as (
    select s.player_id, a.old_seat
    from shuf s join act a on a.rk = s.rk
  )
  update public.players p set seat_index = -(pick.old_seat + 1)
  from pick where p.lobby_id = p_lobby_id and p.player_id = pick.player_id;

  update public.players set seat_index = -seat_index - 1
  where lobby_id = p_lobby_id and status = 'active' and seat_index < 0;

  update public.players set skips_left = 1
  where lobby_id = p_lobby_id and status = 'active';

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
      countdown_starter_player_id = null,
      used_answers = '{}',
      -- Migration 092: gespielte Songs nur beim ersten Durchgang eines Matches leeren
      used_song_ids = case when coalesce(series_index, 1) <= 1 then '{}' else coalesce(used_song_ids, '{}') end,
      current_attempt_id = null,
      round_bonus_used = 0,
      last_pass_quality = 1,
      last_activity_at = now()
  where id = p_lobby_id and phase = 'countdown';

  perform public._pick_next_song(p_lobby_id);
end;
$function$;

-- ------------------------------------------------------------ 4) Lobby-Einladungen
CREATE TABLE IF NOT EXISTS public.lobby_invites (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lobby_id    uuid NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
  from_user   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  to_user     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lobby_id, to_user)
);
ALTER TABLE public.lobby_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lobby_invites FROM PUBLIC, anon, authenticated;

-- Einladen: nur Freunde, nur wer selbst gerade in der (wartenden) Lobby ist
CREATE OR REPLACE FUNCTION public.rpc_invite_friend(p_lobby_code text, p_friend_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_me uuid := auth.uid(); v_lobby uuid;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_logged_in'; END IF;
  PERFORM public._rate_limit('invite:' || v_me::text, 30, 600);
  SELECT l.id INTO v_lobby FROM public.lobbies l
   WHERE l.code = upper(trim(p_lobby_code)) AND l.phase = 'waiting'
     AND EXISTS (SELECT 1 FROM public.players p WHERE p.lobby_id = l.id AND p.user_id = v_me AND p.status = 'active');
  IF v_lobby IS NULL THEN RAISE EXCEPTION 'lobby_not_waiting'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.friendships f WHERE f.user_id = v_me AND f.friend_user_id = p_friend_user_id AND f.status = 'accepted') THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;
  INSERT INTO public.lobby_invites (lobby_id, from_user, to_user)
  VALUES (v_lobby, v_me, p_friend_user_id)
  ON CONFLICT (lobby_id, to_user) DO UPDATE SET status = 'pending', from_user = excluded.from_user, created_at = now();
END;
$$;

-- Offene Einladungen an mich (letzte 10 Minuten, Lobby wartet noch)
CREATE OR REPLACE FUNCTION public.rpc_my_invites()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  IF v_me IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', i.id, 'lobbyCode', l.code, 'fromName', coalesce(pr.display_name, pr.username, 'Ein Freund'),
             'fromEmoji', pr.avatar_emoji, 'createdAt', i.created_at) ORDER BY i.created_at DESC)
      FROM public.lobby_invites i
      JOIN public.lobbies l ON l.id = i.lobby_id
      LEFT JOIN public.profiles pr ON pr.id = i.from_user
     WHERE i.to_user = v_me AND i.status = 'pending'
       AND i.created_at > now() - interval '10 minutes'
       AND l.phase = 'waiting'
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_respond_invite(p_invite_id uuid, p_accept boolean)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_me uuid := auth.uid(); v_code text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_logged_in'; END IF;
  UPDATE public.lobby_invites i SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END
   WHERE i.id = p_invite_id AND i.to_user = v_me
  RETURNING (SELECT l.code FROM public.lobbies l WHERE l.id = i.lobby_id) INTO v_code;
  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_invite_friend(text, uuid), public.rpc_my_invites(), public.rpc_respond_invite(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_invite_friend(text, uuid), public.rpc_my_invites(), public.rpc_respond_invite(uuid, boolean) TO authenticated;

COMMIT;
