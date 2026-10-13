-- ============================================================
-- 110: Langsameres Tempo (Wunsch Mehdi 2026-10-13: "es ist zu schnell")
-- ============================================================
-- Zündschnur-Grundzeiten (Sekunden, min–max): Blitz 14–26 (= bisheriges Standard), Standard 20–36, Casual 28–50.
-- Verkürzung pro Ausscheiden -5 % statt -6 %, höchstens bis 55 % statt 45 %.
BEGIN;

CREATE OR REPLACE FUNCTION public.calc_explode_seconds(p_round_speed text, p_alive_count integer, p_round_number integer, p_exponent numeric DEFAULT 1.9, p_quantize_step_sec numeric DEFAULT 0.5, p_clamp_min_sec numeric DEFAULT 3)
 RETURNS numeric
 LANGUAGE plpgsql
AS $function$
declare
  base_min numeric;
  base_max numeric;
  scale_alive numeric;
  scale_round numeric;
  scale_duel numeric := 1.0;
  min_sec numeric;
  max_sec numeric;
  u numeric;
  biased numeric;
  raw numeric;
  quantized numeric;
begin
  -- 110: alles langsamer (Wunsch Mehdi 2026-10-13): Blitz = bisheriges Standard, Standard/Casual neu
  if p_round_speed = 'fast' then
    base_min := 14; base_max := 26;
  elsif p_round_speed = 'normal' then
    base_min := 20; base_max := 36;
  elsif p_round_speed = 'calm' then
    base_min := 28; base_max := 50;
  else
    base_min := 20; base_max := 36;
  end if;

  scale_alive := greatest(0.75, least(1.25, 1.15 - (p_alive_count * 0.035)));

  -- Tempo-Stufen: -5 % pro Eliminierung, nicht unter 55 % (110, vorher -6 % / 45 %).
  scale_round := greatest(0.55, 1.0 - greatest(0, (p_round_number - 1)) * 0.05);

  -- Duell-Finale: bei 2 Lebenden 20 % kürzer.
  if p_alive_count <= 2 then scale_duel := 0.8; end if;

  min_sec := greatest(p_clamp_min_sec, base_min * scale_alive * scale_round * scale_duel);
  max_sec := greatest(min_sec + 1, base_max * scale_alive * scale_round * scale_duel);

  u := random();
  biased := power(u, p_exponent);
  raw := min_sec + biased * (max_sec - min_sec);

  quantized := round(raw / p_quantize_step_sec) * p_quantize_step_sec;

  return greatest(p_clamp_min_sec, quantized);
end;
$function$;

COMMIT;
