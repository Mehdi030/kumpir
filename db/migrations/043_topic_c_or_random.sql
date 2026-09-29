-- ============================================================
-- Migration 043: dritte Voting-Karte zeigt "Zufällig" statt das
-- gleiche Thema nochmal, wenn kein echtes drittes Thema existiert
-- ============================================================
-- Bug aus Migration 042: wenn der (ggf. gefilterte) Pool keine 3
-- unterschiedlichen Themen hergibt (z.B. Musik-Filter nur auf
-- "Deutschrap-Songs" gesetzt -> nur 1 Kategorie verfügbar), wurde
-- topic_c NULL, und das Frontend blendete die dritte Karte einfach
-- aus -- aber der davor bestehende Fallback (topic_b := topic_a bei
-- nur 1 verfügbarem Thema) blieb bestehen, wodurch man "Deutschrap-
-- Songs" als Thema A UND B sah. Kombiniert mit der neuen dritten
-- Karte (falls doch mal minimal was da war) wirkte das wie 3x
-- derselbe Name.
--
-- Fix: Wenn topic_c NULL ist (kein echtes drittes Thema), zeigt die
-- dritte Karte wieder "Zufällig" (wie vor Migration 042) -- ein Klick
-- darauf verlost bei Sieg/Gleichstand zufällig zwischen Thema A und
-- B, zählt aber weiterhin als eigene Stimme. Nur wenn der Pool
-- WIRKLICH 3 unterschiedliche Themen hergibt, ist die dritte Karte
-- ein echtes drittes Thema (Migration-042-Verhalten bleibt dafür
-- unverändert).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_finalize_topic_vote(p_lobby_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_topic_a text; v_topic_b text; v_topic_c text;
  v_a_count int := 0; v_b_count int := 0; v_c_count int := 0;
  v_selected text; v_pick int; v_choices int[]; v_best int;
begin
  select topic_a, topic_b, topic_c into v_topic_a, v_topic_b, v_topic_c
  from public.lobbies where id = p_lobby_id limit 1;

  if v_topic_a is null then v_topic_a := 'Thema A'; end if;
  if v_topic_b is null then v_topic_b := 'Thema B'; end if;

  select count(*) into v_a_count from public.topic_votes where lobby_id = p_lobby_id and choice = 1;
  select count(*) into v_b_count from public.topic_votes where lobby_id = p_lobby_id and choice = 2;
  select count(*) into v_c_count from public.topic_votes where lobby_id = p_lobby_id and choice = 3;

  if v_topic_c is not null then
    -- Echtes drittes Thema: symmetrische 3-Wege-Wertung, Gleichstand
    -- lost zufällig unter den bestplatzierten Themen aus.
    v_best := greatest(v_a_count, v_b_count, v_c_count);
    v_choices := array[]::int[];
    if v_a_count = v_best then v_choices := array_append(v_choices, 1); end if;
    if v_b_count = v_best then v_choices := array_append(v_choices, 2); end if;
    if v_c_count = v_best then v_choices := array_append(v_choices, 3); end if;

    if array_length(v_choices, 1) = 1 then
      v_pick := v_choices[1];
      v_choices := null;
    else
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
    end if;

    v_selected := case v_pick when 1 then v_topic_a when 2 then v_topic_b else v_topic_c end;
  else
    -- Kein echtes drittes Thema -- Choice 3 ist "Zufällig" (wie vor
    -- Migration 042): gewinnt/steht im Gleichstand Choice 3, wird
    -- zwischen A und B ausgelost statt selbst ein Ziel zu sein.
    if v_a_count > v_b_count and v_a_count > v_c_count then
      v_selected := v_topic_a; v_pick := 1; v_choices := null;
    elsif v_b_count > v_a_count and v_b_count > v_c_count then
      v_selected := v_topic_b; v_pick := 2; v_choices := null;
    elsif v_c_count > v_a_count and v_c_count > v_b_count then
      v_pick := (array[1,2])[1 + floor(random() * 2)::int];
      v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      v_choices := array[3];
    else
      v_choices := array[]::int[];
      if v_a_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 1); end if;
      if v_b_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 2); end if;
      if v_c_count = greatest(v_a_count, v_b_count, v_c_count) then v_choices := array_append(v_choices, 3); end if;
      v_pick := v_choices[1 + floor(random() * array_length(v_choices, 1))::int];
      if v_pick = 1 then v_selected := v_topic_a;
      elsif v_pick = 2 then v_selected := v_topic_b;
      else
        v_pick := (array[1,2])[1 + floor(random() * 2)::int];
        v_selected := case when v_pick = 1 then v_topic_a else v_topic_b end;
      end if;
    end if;
  end if;

  update public.lobbies
  set phase = 'countdown',
      topic_selected = v_selected,
      topic_tie_choices = v_choices,
      topic_tie_pick = v_pick,
      countdown_started_at = now(),
      countdown_ends_at = now() + interval '5 seconds',
      last_activity_at = now()
  where id = p_lobby_id and phase = 'topic_vote';
end;
$function$;

COMMIT;
