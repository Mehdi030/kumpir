-- ============================================================
-- 142: Roulette-Prüfung – Mehrzahl und Buchstabendreher (Wunsch Mehdi, 2026-11-04)
-- ============================================================
-- _letters_close (141) erweitert:
--   * Mehrzahl: Hund -> Hunde, Bär -> Bären, Löwe -> Löwen, Kiwi -> Kiwis (Endungen s, n, e, en, er, nen; ab 3 Buchstaben)
--   * Buchstabendreher ab 5 Buchstaben (Berlni, Elefnat) zählen wie ein Tippfehler, auch wenn Levenshtein 2 sagt
-- Alles andere bleibt: bis 4 Buchstaben exakt, 5 nur Dreher, 6–9: ein Fehler, 10–15: zwei, ab 16: drei.
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._letters_close(p_term text, p_typed text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE ca text; cb text; v_len int; i int;
BEGIN
  IF coalesce(p_term, '') = '' OR coalesce(p_typed, '') = '' THEN RETURN false; END IF;
  ca := replace(p_term, ' ', ''); cb := replace(p_typed, ' ', '');
  IF ca = cb THEN RETURN true; END IF;
  v_len := length(ca);
  -- Mehrzahl (die Listen enthalten die Einzahl)
  IF v_len >= 3 AND length(cb) > v_len AND length(cb) <= v_len + 3 AND left(cb, v_len) = ca AND substr(cb, v_len + 1) IN ('s', 'n', 'e', 'en', 'er', 'nen') THEN RETURN true; END IF;
  IF v_len <= 4 THEN RETURN false; END IF;
  -- zwei vertauschte Nachbarbuchstaben
  IF length(cb) = v_len THEN
    FOR i IN 1..v_len - 1 LOOP
      IF substr(ca, 1, i - 1) || substr(ca, i + 1, 1) || substr(ca, i, 1) || substr(ca, i + 2) = cb THEN RETURN true; END IF;
    END LOOP;
  END IF;
  IF v_len = 5 THEN RETURN false; END IF;
  RETURN levenshtein(ca, cb) <= CASE WHEN v_len <= 9 THEN 1 WHEN v_len <= 15 THEN 2 ELSE 3 END;
END $$;
REVOKE ALL ON FUNCTION public._letters_close(text, text) FROM PUBLIC;

COMMIT;
