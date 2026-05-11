-- ============================================================
-- Migration 010: Schnelles Spiel — Ermahnungs-Mechanik statt Voting
-- ============================================================
-- Neue Gameplay-Idee:
--   - Halter sagt Antwort MÜNDLICH, klickt Pass → Kartoffel geht SOFORT weiter
--   - Andere können für ~5 Sek danach „⚠️ Ermahnen" klicken falls Antwort Mist war
--   - Ermahnungen akkumulieren pro Spieler (sichtbar als Counter)
--   - Bei Spielende: Top-Mogler-Stats
--
-- Was sich ändert:
--   - rpc_pass_potato erweitert um pass_counter Inkrement + last_pass_target
--   - Neue Tabelle pass_warnings (1 Warning pro warner + pass_counter)
--   - Neue RPC rpc_warn_player
--   - Neue Spalte players.warnings_received für UI-Counter
--
-- Die Topic-B-Voting-Tabellen aus Migration 001 (pass_attempts +
-- pass_attempt_votes) bleiben in der DB stehen — werden vom neuen Frontend
-- aber nicht mehr genutzt. Können später für andere Modi wiederverwendet werden.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Neue Spalten in lobbies + players
-- ------------------------------------------------------------
ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS pass_counter INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS last_pass_target_id UUID;

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS last_pass_at TIMESTAMPTZ;

ALTER TABLE public.players
    ADD COLUMN IF NOT EXISTS warnings_received INTEGER NOT NULL DEFAULT 0;


-- ------------------------------------------------------------
-- Tabelle: pass_warnings
-- ------------------------------------------------------------
-- 1 Warning pro warner + pass_counter (sonst kann jemand spammen).
CREATE TABLE IF NOT EXISTS public.pass_warnings (
    lobby_id            UUID NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
    pass_counter        INTEGER NOT NULL,
    target_player_id    UUID NOT NULL,
    warner_player_id    UUID NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (lobby_id, pass_counter, warner_player_id)
);

CREATE INDEX IF NOT EXISTS idx_pass_warnings_target
    ON public.pass_warnings (lobby_id, target_player_id);


-- ------------------------------------------------------------
-- rpc_pass_potato — erweitert mit pass_counter + last_pass_target
-- Fair-Timer (1.5s) bleibt, Modi-Balance bleibt.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_lobby_id    uuid;
  v_mode        text;
  v_holder      uuid;
  v_dir         smallint;
  v_explode_at  timestamptz;

  alive_ids     uuid[];
  n             int;
  idx           int;
  next_idx      int;
  v_next        uuid;

  v_now         timestamptz := now();
  v_last_pass   timestamptz;
  v_pass_ms     int;
  v_clutch      int := 0;
  v_ms_left     int;

  v_min_hold    interval := interval '1.5 seconds';
  v_teleport_chance numeric := 0.30;
  v_reverse_chance  numeric := 0.25;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at
  from public.lobbies l
  where l.code = upper(p_code)
  for update;

  if v_lobby_id is null then raise exception 'Lobby not found'; end if;
  if (select phase from public.lobbies where id = v_lobby_id) <> 'running' then
    raise exception 'Game not running';
  end if;
  if v_holder is null or v_holder <> p_player_id then raise exception 'Not holder'; end if;
  if not exists (
    select 1 from public.players p
    where p.lobby_id = v_lobby_id and p.player_id = p_player_id
      and p.status = 'active' and p.is_alive = true
  ) then raise exception 'Player not active/alive'; end if;

  select array_agg(p.player_id order by p.seat_index)
    into alive_ids
  from public.players p
  where p.lobby_id = v_lobby_id and p.status = 'active' and p.is_alive = true;

  n := coalesce(array_length(alive_ids, 1), 0);
  if n <= 1 then return; end if;

  idx := array_position(alive_ids, p_player_id);
  if idx is null then raise exception 'Holder not in alive list'; end if;

  -- Mode-Logik
  if v_mode = 'teleport' and random() < v_teleport_chance then
    select p.player_id into v_next
    from public.players p
    where p.lobby_id = v_lobby_id and p.status = 'active'
      and p.is_alive = true and p.player_id <> p_player_id
    order by random() limit 1;
    if v_next is null then
      next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
      v_next := alive_ids[next_idx];
    end if;
  elsif v_mode = 'reverse' and random() < v_reverse_chance then
    v_dir := coalesce(v_dir, 1) * -1;
    update public.lobbies set pass_direction = v_dir where id = v_lobby_id;
    if v_dir = 1 then
      next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1; if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  else
    if v_mode = 'reverse' then
      if coalesce(v_dir, 1) = 1 then
        next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
      else
        next_idx := idx - 1; if next_idx < 1 then next_idx := n; end if;
      end if;
    else
      next_idx := idx + 1; if next_idx > n then next_idx := 1; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  -- Lobby aktualisieren + Pass-Counter inkrementieren
  update public.lobbies
  set holder_player_id      = v_next,
      explode_at            = greatest(v_explode_at, v_now + v_min_hold),
      last_activity_at      = v_now,
      pass_counter          = coalesce(pass_counter, 0) + 1,
      last_pass_target_id   = p_player_id,
      last_pass_at          = v_now
  where id = v_lobby_id;

  -- Stats für vorigen Halter
  select last_pass_at into v_last_pass
  from public.players
  where lobby_id = v_lobby_id and player_id = p_player_id;

  if v_last_pass is not null then
    v_pass_ms := extract(epoch from (v_now - v_last_pass)) * 1000;
  else
    select extract(epoch from (v_now - coalesce(run_started_at, v_now))) * 1000
      into v_pass_ms
    from public.lobbies where id = v_lobby_id;
  end if;
  v_pass_ms := greatest(0, coalesce(v_pass_ms, 0));

  if v_explode_at is not null then
    v_ms_left := extract(epoch from (v_explode_at - v_now)) * 1000;
    if v_ms_left <= 2000 then v_clutch := 1; end if;
  end if;

  update public.players
  set
    pass_count        = coalesce(pass_count, 0) + 1,
    last_pass_at      = v_now,
    total_hold_ms     = coalesce(total_hold_ms, 0) + v_pass_ms,
    fastest_pass_ms   = case
                          when fastest_pass_ms is null then v_pass_ms
                          when v_pass_ms < fastest_pass_ms then v_pass_ms
                          else fastest_pass_ms
                        end,
    clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;


-- ------------------------------------------------------------
-- rpc_warn_player — andere geben Ermahnung ab
-- Window: 5 Sekunden nach dem letzten Pass.
-- Validierung: warner != target, warner ist active+alive, target = last_pass_target.
-- Idempotent: PRIMARY KEY verhindert Doppel-Warnings.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_warn_player(
    p_code TEXT,
    p_warner_player_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_lobby_id           UUID;
    v_pass_counter       INTEGER;
    v_last_pass_target   UUID;
    v_last_pass_at       TIMESTAMPTZ;
    v_window             INTERVAL := INTERVAL '5 seconds';
BEGIN
    SELECT id, pass_counter, last_pass_target_id, last_pass_at
      INTO v_lobby_id, v_pass_counter, v_last_pass_target, v_last_pass_at
    FROM public.lobbies
    WHERE code = UPPER(p_code);

    IF v_lobby_id IS NULL THEN RAISE EXCEPTION 'lobby_not_found'; END IF;
    IF v_last_pass_target IS NULL OR v_last_pass_at IS NULL THEN
        RAISE EXCEPTION 'no_recent_pass';
    END IF;

    -- Time-Window: nur innerhalb 5s nach letztem Pass
    IF NOW() > v_last_pass_at + v_window THEN
        RAISE EXCEPTION 'warning_window_expired';
    END IF;

    -- warner darf sich nicht selbst ermahnen
    IF v_last_pass_target = p_warner_player_id THEN
        RAISE EXCEPTION 'cannot_warn_self';
    END IF;

    -- warner muss aktiv + lebendig sein
    IF NOT EXISTS (
        SELECT 1 FROM public.players
        WHERE lobby_id = v_lobby_id
          AND player_id = p_warner_player_id
          AND status = 'active'
          AND is_alive = TRUE
    ) THEN
        RAISE EXCEPTION 'warner_not_active';
    END IF;

    -- Warning einfügen (idempotent über PK)
    INSERT INTO public.pass_warnings (lobby_id, pass_counter, target_player_id, warner_player_id)
    VALUES (v_lobby_id, v_pass_counter, v_last_pass_target, p_warner_player_id)
    ON CONFLICT (lobby_id, pass_counter, warner_player_id) DO NOTHING;

    -- Counter beim Target hochzählen (nur wenn neuer insert)
    IF FOUND THEN
        UPDATE public.players
        SET warnings_received = COALESCE(warnings_received, 0) + 1
        WHERE lobby_id = v_lobby_id
          AND player_id = v_last_pass_target;
    END IF;
END;
$$;


-- ------------------------------------------------------------
-- RLS für pass_warnings
-- ------------------------------------------------------------
ALTER TABLE public.pass_warnings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pass_warnings_read_all" ON public.pass_warnings;
CREATE POLICY "pass_warnings_read_all" ON public.pass_warnings FOR SELECT USING (TRUE);


-- ------------------------------------------------------------
-- Pass-Counter bei Rundenwechsel resetten (im rpc_tick_game)
-- ------------------------------------------------------------
-- rpc_tick_game bekommt zusätzlich das Reset für pass_counter + last_pass_*
-- am Anfang einer neuen Runde, damit Warnings nicht über Runden zählen
-- als „aktuelles Warn-Fenster".
CREATE OR REPLACE FUNCTION public.rpc_tick_game(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_now         timestamptz := now();
  v_lobby_id    uuid;
  v_phase       text;
  v_holder      uuid;
  v_explode_at  timestamptz;
  v_game_mode   text;
  v_round_speed text;
  v_round_num   int;
  v_alive_count int;
  v_loser       uuid;
  v_next_holder uuid;
  v_next_seconds numeric;
begin
  select id, phase, holder_player_id, explode_at, game_mode, round_speed, round_number
    into v_lobby_id, v_phase, v_holder, v_explode_at, v_game_mode, v_round_speed, v_round_num
  from public.lobbies
  where code = upper(p_code)
  for update;

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
  set round_number         = coalesce(round_number, 0) + 1,
      last_loser_player_id = v_loser,
      last_activity_at     = v_now,
      used_answers         = '{}'
  where id = v_lobby_id;

  select count(*) into v_alive_count
  from public.players
  where lobby_id = v_lobby_id and status = 'active' and is_alive = true;

  if v_alive_count <= 1 then
    update public.lobbies
    set phase            = 'finished',
        explode_at       = null,
        holder_player_id = (
          select player_id from public.players
          where lobby_id = v_lobby_id and status = 'active' and is_alive = true
          limit 1
        )
    where id = v_lobby_id;
    return;
  end if;

  if v_game_mode = 'teleport' then
    select player_id into v_next_holder
    from public.players
    where lobby_id = v_lobby_id and status = 'active'
      and is_alive = true and player_id <> v_loser
    order by random() limit 1;
  else
    select p2.player_id into v_next_holder
    from public.players p_loser
    join public.players p2 on p2.lobby_id = p_loser.lobby_id
      and p2.status = 'active' and p2.is_alive = true
      and p2.seat_index > p_loser.seat_index
    where p_loser.lobby_id = v_lobby_id and p_loser.player_id = v_loser
    order by p2.seat_index asc limit 1;

    if v_next_holder is null then
      select player_id into v_next_holder from public.players
      where lobby_id = v_lobby_id and status = 'active' and is_alive = true
      order by seat_index asc limit 1;
    end if;
  end if;

  v_next_seconds := public.calc_explode_seconds(
    coalesce(v_round_speed, 'normal'), v_alive_count,
    coalesce(v_round_num, 0) + 1, 1.9, 0.5, 3
  );

  update public.lobbies
  set holder_player_id     = v_next_holder,
      explode_at           = v_now + make_interval(secs => v_next_seconds),
      pass_direction       = case
                               when v_game_mode = 'reverse' and random() < 0.40
                               then (pass_direction * -1)::smallint
                               else pass_direction
                             end,
      current_attempt_id   = null,
      -- Pass-Counter reset für neue Runde (Warnings über Rundengrenze hinaus blocken)
      pass_counter         = 0,
      last_pass_target_id  = null,
      last_pass_at         = null
  where id = v_lobby_id;
end;
$function$;


COMMIT;
