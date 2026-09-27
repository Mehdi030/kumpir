-- ============================================================
-- Migration 016: Fehlenden search_path bei SECURITY DEFINER-Funktionen ergänzt
-- ============================================================
-- Beim Sicherheits-Audit gefunden (nicht vom Advisor-Screenshot
-- gemeldet, aber dieselbe Fund-Klasse "Function Search Path Mutable",
-- die Supabase separat unter Security lintet): 15 SECURITY DEFINER
-- Funktionen hatten kein `SET search_path`, obwohl praktisch alle
-- anderen SECURITY DEFINER Funktionen im Projekt das bereits haben.
--
-- Risiko: Eine SECURITY DEFINER Funktion ohne fest verdrahteten
-- search_path lässt sich potenziell kapern, wenn ein Aufrufer (mit
-- Schema-Create-Rechten) ein gleichnamiges Objekt in einem Schema
-- anlegt, das vor `public` im search_path des Funktions-Besitzers
-- steht -- die Funktion würde dann unbemerkt das falsche Objekt
-- verwenden, mit den erhöhten Rechten des Funktions-Besitzers.
-- Da hier alle Tabellen-/Funktionsreferenzen im Code bereits mit
-- `public.` qualifiziert sind, ist die praktische Ausnutzbarkeit
-- gering -- trotzdem harte Absicherung nach Postgres/Supabase
-- Best-Practice, ohne jegliche Verhaltensänderung.
--
-- ALTER FUNCTION statt CREATE OR REPLACE: ändert nur die Config,
-- fasst den Funktionskörper nicht an -- risikofrei.
-- ============================================================

BEGIN;

ALTER FUNCTION public.cleanup_lobby(uuid, integer) SET search_path TO 'public';
ALTER FUNCTION public.kick_player(uuid, uuid, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_pass_potato(text, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_begin_topic_vote(uuid, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_create_lobby(text, text, integer, integer, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.rpc_heartbeat(uuid, uuid) SET search_path TO 'public';
ALTER FUNCTION public.rpc_tick_game(text) SET search_path TO 'public';
ALTER FUNCTION public.rpc_vote_topic(uuid, uuid, integer) SET search_path TO 'public';
ALTER FUNCTION public.set_lobby_mode(uuid, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.set_lobby_topic(uuid, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.set_max_players(uuid, uuid, integer) SET search_path TO 'public';
ALTER FUNCTION public.rpc_attempt_pass(text, uuid, text) SET search_path TO 'public';
ALTER FUNCTION public.rpc_vote_answer(uuid, uuid, boolean) SET search_path TO 'public';
ALTER FUNCTION public._finalize_attempt_accept(uuid) SET search_path TO 'public';
ALTER FUNCTION public._finalize_attempt_reject(uuid) SET search_path TO 'public';

COMMIT;
