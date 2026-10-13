-- ============================================================
-- 116: Zeitgeber-Protokoll aufräumen (Fund aus dem Gesamttest 2026-10-13)
-- ============================================================
-- cron.job_run_details bekommt für JEDEN Lauf einen Eintrag; die Spiel-Zeitgeber laufen jede Sekunde
-- (kumpir-bot-tick) bzw. alle 2 Sekunden (kumpir-server-tick) = ca. 130.000 Einträge / 20 MB pro Tag.
-- Es gab kein Aufräumen: 1,14 Mio. Einträge, 171 MB von 202 MB Gesamtgröße der Datenbank.
-- Jetzt: einmal leeren (Fehlerverlauf aus der Vergangenheit wird nicht gebraucht, alle Läufe waren erfolgreich)
-- und alle 30 Minuten alles bis auf die letzten 60.000 Einträge (~8 Stunden) löschen.
TRUNCATE cron.job_run_details;

SELECT cron.schedule(
  'kumpir-cron-log-cleanup',
  '*/30 * * * *',
  $$delete from cron.job_run_details where runid < (select max(runid) from cron.job_run_details) - 60000$$
);
