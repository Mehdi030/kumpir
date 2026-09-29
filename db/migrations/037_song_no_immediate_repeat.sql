-- ============================================================
-- Migration 037: Song-Wiederholung -- kein direktes Zweimal-hintereinander
-- ============================================================
-- _pick_next_song schließt bereits gespielte Songs aus (used_song_ids),
-- aber sobald der Pool einer Kategorie erschöpft ist (alle ~20 Songs
-- schon dran), wird er komplett zurückgesetzt und OHNE jede Ausnahme neu
-- gezogen -- dabei konnte der GERADE eben gespielte Song direkt nochmal
-- gezogen werden (spürbar als "der gleiche Song wie eben"). Bei vielen
-- Spielern + dem Pass-Bonus aus Migration 032 (viele Halterwechsel pro
-- Runde) ist der Pool schneller erschöpft als gedacht, der Fall tritt
-- also öfter auf als ursprünglich angenommen.
--
-- Fix: beim Reset wird der aktuell gespielte Song explizit von der
-- Neuziehung ausgeschlossen, garantiert also mindestens "kein Song
-- zweimal direkt hintereinander".
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id UUID)
 RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic text; v_topic_pool_id uuid; v_used uuid[]; v_song_id uuid; v_current uuid;
begin
  select topic_selected, used_song_ids, current_song_id into v_topic, v_used, v_current
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

  -- Songs im Match aufgebraucht -> Pool für dieses Match wieder freigeben,
  -- aber den gerade gespielten Song von der Neuziehung ausschließen, damit
  -- er nicht direkt zweimal hintereinander drankommt.
  if v_song_id is null then
    select sp.id into v_song_id
    from public.song_pool sp
    where sp.topic_pool_id = v_topic_pool_id
      and (v_current is null or sp.id <> v_current)
    order by random() limit 1;
    v_used := '{}';
  end if;

  update public.lobbies
  set current_song_id = v_song_id,
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

COMMIT;
