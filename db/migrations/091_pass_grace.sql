-- ============================================================
-- 091: Schutzzeit beim Weitergeben (Wunsch Mehdi, 2026-10-07)
-- ============================================================
-- Problem: Die Zündschnur läuft pro Zug (nicht pro Spieler). Wer in letzter Sekunde weitergibt,
-- reichte dem Nächsten nur die Restzeit weiter – der platzte ohne jede Chance (im Duell gibt es
-- zusätzlich keine Bonuszeit).
--
-- Lösung: Wer die Kumpir bekommt, hat IMMER mindestens die Schutzzeit:
--   Blitz 5 s · Standard 6 s · Casual 7 s
-- Jede weitere Schutzzeit im selben Zug ist 1 s kürzer (nie unter 4 s) – so kann ein Zug nicht
-- endlos weiterlaufen, wenn alle immer kurz vor Schluss abgeben. Neuer Zug = wieder volle Schutzzeit.
-- lobbies.last_grace_sec sagt dem Browser, dass beim letzten Weitergeben die Schutzzeit gegriffen hat
-- (für den Hinweis beim Empfänger); 0 = normale Restzeit.
-- ============================================================
BEGIN;

ALTER TABLE public.lobbies
  ADD COLUMN IF NOT EXISTS grace_count int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_grace_sec numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.calc_pass_grace_seconds(p_round_speed text, p_used int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(4,
    (CASE p_round_speed WHEN 'fast' THEN 5 WHEN 'calm' THEN 7 ELSE 6 END) - greatest(0, coalesce(p_used, 0))
  )::numeric;
$$;

-- Neuer Zug (jemand ist geplatzt) oder neue Runde: Schutzzeit wieder voll
CREATE OR REPLACE FUNCTION public._trg_reset_grace()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.round_number IS DISTINCT FROM OLD.round_number
     OR (NEW.phase = 'running' AND OLD.phase IS DISTINCT FROM 'running') THEN
    NEW.grace_count := 0;
    NEW.last_grace_sec := 0;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS lobbies_reset_grace ON public.lobbies;
CREATE TRIGGER lobbies_reset_grace BEFORE UPDATE ON public.lobbies
  FOR EACH ROW EXECUTE FUNCTION public._trg_reset_grace();

CREATE OR REPLACE FUNCTION public.rpc_pass_potato(p_code text, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lobby_id uuid; v_mode text; v_holder uuid; v_dir smallint; v_explode_at timestamptz;
  v_round_number int; v_bonus_seconds numeric; v_bonus_used numeric; v_bonus_cap numeric; v_bonus_applied numeric;
  alive_ids uuid[]; n int; idx int; next_idx int; v_next uuid;
  v_now timestamptz := now();
  v_since timestamptz; v_pass_ms int; v_clutch int := 0; v_ms_left int;
  v_quality numeric; v_diff numeric; v_combo_bonus numeric;
  v_speed text; v_grace_count int; v_grace numeric; v_new_explode timestamptz; v_grace_applied numeric := 0;
begin
  select l.id, l.game_mode, l.holder_player_id, l.pass_direction, l.explode_at, l.round_number,
         coalesce(l.round_bonus_used, 0), coalesce(l.holder_since, l.run_started_at),
         coalesce(l.last_pass_quality, 1), coalesce(l.last_pass_diff, 1), coalesce(l.last_pass_combo_bonus, 0),
         coalesce(l.round_speed, 'normal'), coalesce(l.grace_count, 0)
    into v_lobby_id, v_mode, v_holder, v_dir, v_explode_at, v_round_number,
         v_bonus_used, v_since, v_quality, v_diff, v_combo_bonus,
         v_speed, v_grace_count
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
    -- Original: Richtung kann durch den Rache-Pass gedreht sein.
    if coalesce(v_dir, 1) >= 0 then
      next_idx := idx + 1;
      if next_idx > n then next_idx := 1; end if;
    else
      next_idx := idx - 1;
      if next_idx < 1 then next_idx := n; end if;
    end if;
    v_next := alive_ids[next_idx];
  end if;

  v_bonus_cap := public.calc_pass_bonus_cap(n);
  -- Basis (Runde) x Antwortqualität (Titel 1 / Interpret 0.5) x Song-
  -- Schwierigkeit + Combo-Bonus; im Duell (2 Lebende) gar keine Bonuszeit.
  v_bonus_seconds := public.calc_pass_bonus_seconds(v_round_number) * v_quality * v_diff + v_combo_bonus;
  if n <= 2 then v_bonus_seconds := 0; end if;
  v_bonus_applied := greatest(0, least(v_bonus_seconds, v_bonus_cap - v_bonus_used));

  v_new_explode := greatest(coalesce(v_explode_at, v_now), v_now) + (v_bonus_applied * interval '1 second');

  -- Schutzzeit: der Empfänger hat immer mindestens v_grace Sekunden (Migration 091)
  v_grace := public.calc_pass_grace_seconds(v_speed, v_grace_count);
  if v_new_explode < v_now + (v_grace * interval '1 second') then
    v_new_explode := v_now + (v_grace * interval '1 second');
    v_grace_applied := v_grace;
  end if;

  update public.lobbies
  set holder_player_id = v_next,
      explode_at = v_new_explode,
      round_bonus_used = v_bonus_used + v_bonus_applied,
      grace_count = v_grace_count + case when v_grace_applied > 0 then 1 else 0 end,
      last_grace_sec = v_grace_applied,
      last_pass_quality = 1, last_pass_diff = 1, last_pass_combo_bonus = 0,
      last_activity_at = v_now
  where id = v_lobby_id;
  perform public._pick_next_song(v_lobby_id);

  v_pass_ms := greatest(0, coalesce(extract(epoch from (v_now - coalesce(v_since, v_now))) * 1000, 0));

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
      slowest_pass_ms = case
        when slowest_pass_ms is null then v_pass_ms
        when v_pass_ms > slowest_pass_ms then v_pass_ms
        else slowest_pass_ms
      end,
      clutch_pass_count = coalesce(clutch_pass_count, 0) + v_clutch
  where lobby_id = v_lobby_id and player_id = p_player_id;
end;
$function$;

COMMIT;
