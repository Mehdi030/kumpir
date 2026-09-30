-- ============================================================
-- Migration 052: current_song_started_at -- synchrone Song-Wiedergabe
-- ============================================================
-- Bisher startete jeder Client seinen <audio>-Tag einfach, sobald SEIN
-- eigener Preview-URL-Request/Buffer fertig war -- je nach Netzwerk-
-- Timing hörte jeder Spieler den Song an einer anderen Stelle. Neue
-- Spalte lobbies.current_song_started_at wird von _pick_next_song genau
-- dann gesetzt, wenn ein neuer Song gezogen wird -- das Frontend
-- berechnet daraus für jeden Client dieselbe Ziel-Wiedergabeposition
-- (Date.now() - current_song_started_at) und synct periodisch nach.
-- ============================================================

BEGIN;

ALTER TABLE public.lobbies ADD COLUMN IF NOT EXISTS current_song_started_at timestamptz;

-- Migration 049 hat gezeigt: eine neue Spalte erbt NICHT automatisch das
-- SELECT-Grant, das für die restliche Tabelle gilt (bekam nur REFERENCES).
-- Hier defensiv nochmal explizit granten, damit das Frontend sie sofort
-- lesen kann, unabhängig davon, ob lobbies ursprünglich per Tabellen- oder
-- Spalten-Grant abgesichert wurde.
GRANT SELECT ON public.lobbies TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._pick_next_song(p_lobby_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
    update public.lobbies set current_song_id = null, current_song_started_at = null where id = p_lobby_id;
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
      current_song_started_at = case when v_song_id is null then null else now() end,
      used_song_ids = case when v_song_id is null then used_song_ids else array_append(v_used, v_song_id) end
  where id = p_lobby_id;
end;
$function$;

COMMIT;
