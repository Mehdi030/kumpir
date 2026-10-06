-- ============================================================
-- Migration 072: Combo / Rache-Pass / Richtung pro Runde wieder zurücksetzen
-- ============================================================
-- Regression aus Migration 066: dort wurde _reset_series_on_phase neu definiert und der
-- Zweig "neues Themen-Voting = neue Runde" aus 063 ging verloren. Folge: Combo und
-- Rache-Pass (einmal pro Runde) wurden nie zurückgesetzt, eine gedrehte Richtung blieb
-- in der nächsten Runde erhalten. Hier wieder zusammengeführt.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._reset_series_on_phase()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if NEW.phase in ('waiting', 'rematch_wait') and OLD.phase is distinct from NEW.phase then
    NEW.series_index := 1;
    NEW.series_topics := '{}';
    NEW.series_starters := '{}';
    delete from public.series_results where lobby_id = NEW.id;
  end if;
  if NEW.phase = 'topic_vote' and OLD.phase is distinct from NEW.phase then
    update public.players set combo = 0, revenge_used = false where lobby_id = NEW.id;
    NEW.pass_direction := 1;
  end if;
  return NEW;
end;
$function$;

COMMIT;
