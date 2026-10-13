-- ============================================================
-- 111: Meistgespielte Modi (Wunsch Mehdi 2026-10-13)
-- ============================================================
-- "Lobby hosten" zeigt nur die 3 meistgespielten Modi offen, der Rest ist eingeklappt.
-- Gezählt wird jede gestartete Runde (countdown -> running/quiz). Bisherige Runden zählen als "original".
BEGIN;

CREATE TABLE IF NOT EXISTS public.mode_plays (
  mode text PRIMARY KEY,
  plays bigint NOT NULL DEFAULT 0
);
ALTER TABLE public.mode_plays ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mode_plays FROM anon, authenticated;

INSERT INTO public.mode_plays (mode, plays)
SELECT 'original', count(DISTINCT (match_id, round_index)) FROM public.account_rounds
ON CONFLICT (mode) DO NOTHING;

CREATE OR REPLACE FUNCTION public._trg_count_mode_play()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    insert into public.mode_plays (mode, plays) values (coalesce(NEW.game_mode, 'original'), 1)
    on conflict (mode) do update set plays = public.mode_plays.plays + 1;
  exception when others then
    null; -- darf den Spielstart nie stören
  end;
  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS lobbies_count_mode_play ON public.lobbies;
CREATE TRIGGER lobbies_count_mode_play
  AFTER UPDATE OF phase ON public.lobbies
  FOR EACH ROW
  WHEN (OLD.phase = 'countdown' AND NEW.phase IN ('running', 'quiz'))
  EXECUTE FUNCTION public._trg_count_mode_play();

CREATE OR REPLACE FUNCTION public.get_mode_popularity()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_object_agg(mode, plays), '{}'::jsonb) FROM public.mode_plays;
$function$;
GRANT EXECUTE ON FUNCTION public.get_mode_popularity() TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._trg_count_mode_play() FROM PUBLIC, anon, authenticated;

COMMIT;
