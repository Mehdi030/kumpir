# 📦 KUMPIR — Migrationen

Hier liegen Schema-Änderungen, die in Supabase noch ausgeführt werden müssen.
Nummerierung ist chronologisch — **niemals umbenennen oder umordnen**.

## Anwenden (im Supabase Dashboard → SQL Editor)

In dieser Reihenfolge ausführen. Jede Migration ist idempotent (kann wiederholt werden).

| Nr | Datei | Zweck | Status |
|----|-------|-------|--------|
| 001 | [`001_topic_validation.sql`](001_topic_validation.sql) | Topic-Mechanik B: Antwort sagen + Mehrheits-Voting | **PFLICHT** für die neue Spielmechanik |
| 002 | [`002_categories_seed.sql`](002_categories_seed.sql) | 49 deutsche Kategorien in `topic_pool` füllen + `example`-Spalte | Empfohlen (kann auch leer bleiben, dann musst du Topics manuell pflegen) |
| 003 | [`003_fix_rematch_topic_source.sql`](003_fix_rematch_topic_source.sql) | Bug-Fix: `rpc_start_rematch_if_ready` zog Topics aus `topics`, sollte `topic_pool` sein | **PFLICHT** wenn du Rematch nutzt, sonst crasht es |
| 004 | [`004_auth_link_optional.sql`](004_auth_link_optional.sql) | `rpc_create_lobby` + `rpc_join_lobby` um optionalen `p_user_id` Parameter erweitern (für Lifetime-Stats) | **PFLICHT** wenn du Auth opt-in nutzt (NEXT_PUBLIC_AUTH_DISABLED=0) |
| 005 | [`005_achievements.sql`](005_achievements.sql) | Tabellen `achievements` + `player_lifetime_stats` + `player_achievements` + Aggregations-Trigger | Pflicht für die `/achievements`-Seite |
| 006 | [`006_leaderboards.sql`](006_leaderboards.sql) | View `leaderboard_view` (joinet player_lifetime_stats × profiles.username) | Pflicht für die `/leaderboard`-Seite |
| 007 | [`007_bots.sql`](007_bots.sql) | `players.is_bot` Spalte + `rpc_add_bot` + `rpc_remove_bot` | Pflicht für „🤖 +Bot" Button in der Lobby |
| 008 | [`008_friends_and_saved_lobbies.sql`](008_friends_and_saved_lobbies.sql) | `friendships` + `saved_lobbies` Tabellen + 5 RPCs (send/accept/remove + save/unsave) + `friends_view` | Pflicht für `/friends`-Seite + Lobby-Merken-Button |
| 009 | [`009_reset_lobby.sql`](009_reset_lobby.sql) | Fehlende `rpc_reset_lobby` nachgereicht ("Zurück zur Lobby"-Button war kaputt) | **PFLICHT** — ohne sie wirft der Button einen Fehler |
| 010 | [`010_used_answers_reset.sql`](010_used_answers_reset.sql) | `used_answers` + `current_attempt_id` werden jetzt bei jedem Rundenstart und Rematch geleert | **PFLICHT** — sonst blockieren alte Antworten irgendwann jede neue Runde |
| 011 | [`011_round_speed_wiring.sql`](011_round_speed_wiring.sql) | `rpc_create_lobby` bekommt `p_round_speed`; `rpc_advance_from_countdown` + `rpc_tick_game` nutzen jetzt `calc_explode_seconds()` statt fixer 25s/15s | Empfohlen — vorher hatte die Rundengeschwindigkeits-Auswahl keinerlei Wirkung |
| 012 | [`012_rls_core_tables.sql`](012_rls_core_tables.sql) | RLS auf `lobbies`, `players`, `topic_pool`, `topic_votes`, `game_runs` (öffentlich lesbar, Schreiben nur über RPCs) + Lockout für `profiles`(Spalten-Grants)/`game_run_players`/`game_run_eliminations`/`round_stats`/`lobby_admin_*`/`staff_roles`/`kv_store_8e1b0e4b` | **PFLICHT** (Sicherheit) — vorher waren diese Tabellen über den öffentlichen Anon-Key frei lesbar/schreibbar |
| 013 | [`013_legacy_cleanup.sql`](013_legacy_cleanup.sql) | Tote Tabellen `lobby_players`, `topics`, `game_state` gelöscht (durch `players`/`topic_pool`/`lobbies` ersetzt, nirgends mehr referenziert) | Empfohlen (Aufräumen) |
| 014 | [`014_bots_stay_ready.sql`](014_bots_stay_ready.sql) | `rpc_reset_lobby` + `rpc_rematch` + `rpc_start_rematch_if_ready` setzten `ready=false` für ALLE Spieler inkl. Bots — Bots können sich aber nirgends selbst wieder bereit melden, blieben also für immer hängen | **PFLICHT** — sonst blockiert jeder Bot nach der ersten Runde jedes weitere Rematch/Reset |
| 015 | [`015_security_definer_views.sql`](015_security_definer_views.sql) | `leaderboard_view` + `friends_view` liefen ohne `security_invoker` (Supabase Advisor: CRITICAL) — RLS der referenzierten Tabellen wurde beim Zugriff über die View umgangen | **PFLICHT** (Sicherheit) |
| 016 | [`016_function_search_path_hardening.sql`](016_function_search_path_hardening.sql) | 15 SECURITY DEFINER Funktionen ohne `SET search_path` gegen search_path-Hijacking abgesichert (reine Config-Änderung, kein Verhaltens-Unterschied) | Empfohlen (Härtung) |
| 017 | [`017_restrict_email_lookup.sql`](017_restrict_email_lookup.sql) | `get_email_for_username` gab für JEDEN bekannten Username die Klartext-Email an anon/authenticated heraus (Username→Email-Harvesting) — EXECUTE entzogen, Username-Login läuft jetzt über `actions/login.ts` + `SUPABASE_SERVICE_ROLE_KEY` | **PFLICHT** (Sicherheit) — braucht `SUPABASE_SERVICE_ROLE_KEY` in der Server-Umgebung, sonst funktioniert nur noch Email-Login |
| 018 | [`018_resolve_stale_attempts.sql`](018_resolve_stale_attempts.sql) | Neue RPC `rpc_resolve_stale_attempt`: löst einen hängenden Pass-Versuch nach 8s per Mehrheit der bis dahin abgegebenen Stimmen auf (bei 0:0 im Zweifel für den Halter) — ohne das blockierte ein einzelner Non-Voter/Ablehner bei 3 lebenden Spielern jeden Pass für immer | **PFLICHT** — sonst bleibt die in BALANCE_REPORT.md (Fund #2) beschriebene Blockade bestehen |
| 019 | [`019_guard_reset_rematch.sql`](019_guard_reset_rematch.sql) | `rpc_reset_lobby`/`rpc_rematch` nahmen nur den 4-stelligen Code entgegen — jeder, der je den Join-Link gesehen hatte, konnte damit JEDE laufende Partie jederzeit zurücksetzen/in den Rematch zwingen. Verlangen jetzt zusätzlich `p_player_id` (muss aktives Mitglied sein) und wirken nur noch aus `phase='finished'` | **PFLICHT** (Sicherheit) — schwerwiegender als die Player-Impersonation-Problematik, da nicht mal eine Spieler-ID nötig war |
| 020 | [`020_validate_privacy.sql`](020_validate_privacy.sql) | `rpc_create_lobby`s `p_privacy` war ungeprüft (anders als `p_round_speed`) — jetzt per Allow-List auf `private`/`public` geprüft | Empfohlen (Konsistenz) — aktuell nicht ausnutzbar, da "Public" im Frontend noch deaktiviert ist |
| 021 | [`021_enable_realtime_publication.sql`](021_enable_realtime_publication.sql) | `lobbies`/`players`/`topic_votes`/`pass_attempts`/`pass_attempt_votes` waren nie Teil der `supabase_realtime`-Publication — der WebSocket verband erfolgreich, aber Postgres schickte nie ein Change-Event. Die App lief die ganze Zeit nur über den Polling-Fallback (spürbare Verzögerung im Live-Test) | **PFLICHT** — sonst bleibt Realtime komplett wirkungslos, egal was der Client tut |
| 022 | [`022_fix_kick_and_leave.sql`](022_fix_kick_and_leave.sql) | Zwei Regressionen: `kick_player` komplett kaputt (Migration 019 hat einen nie gedumpten Legacy-Trigger zerschossen, der intern `rpc_reset_lobby(text)` aufruft) + `rpc_leave_lobby` neu ("Lobby verlassen" schrieb seit Migration 012 direkt in `players`, RLS blockte das im Stillen) | **PFLICHT** — beide von der Cheat-Probe gefunden |
| 023 | [`023_session_tokens.sql`](023_session_tokens.sql) | Session-Token-System: `players.session_token` (nicht lesbar für andere), geprüft in allen Spiel-Aktionen (`rpc_toggle_ready`, `rpc_vote_topic`, `rpc_attempt_pass`, `rpc_vote_answer`, `rpc_join_lobby`, `rpc_create_lobby`, `rpc_leave_lobby`) | **PFLICHT** (Sicherheit) — schließt Vote-Stuffing, Ready-Toggle-Spoofing, Fremd-Antworten (alle von der Cheat-Probe nachgewiesen) |
| 024 | [`024_session_tokens_host_actions.sql`](024_session_tokens_host_actions.sql) | Session-Token-Prüfung auch für Host-Aktionen (`kick_player`, `transfer_host`, `set_lobby_*`, `rpc_begin_topic_vote`, `rpc_add_bot`, `rpc_remove_bot`, `rpc_reset_lobby`, `rpc_rematch`) | **PFLICHT** (Sicherheit) — vorher reichte die öffentlich sichtbare Host-ID |
| 025 | [`025_song_category.sql`](025_song_category.sql) | Neue Themen-Kategorie "Deutschrap-Songs" (nutzt die bestehende Topic-Mechanik B unverändert) | Empfohlen (Content) |
| 026 | [`026_music_genres.sql`](026_music_genres.sql) | 3 weitere Musik-Kategorien ("Deutschrap Klassiker", "Englische All-Time-Hits", "Internationale Pop-Charts", je mit echter Spotify-Playlist) + `lobbies.topic_filter` + `set_lobby_topic_filter` — Host kann eine Lobby auf reine Musik-Genres festlegen statt zufällig aus allen Kategorien zu ziehen | Empfohlen (Content + Feature) |
| 027 | [`027_topic_answer_database.sql`](027_topic_answer_database.sql) | Neue Tabelle `topic_answers` (~1100 Antworten über alle 54 Kategorien, "Bäume" deutlich erweitert) — `rpc_attempt_pass` nimmt eine bekannte Antwort jetzt SOFORT an, ohne Mehrheits-Voting. Unbekannte Antworten fallen weiter auf das bestehende Voting zurück | Empfohlen (Feature) — macht das Spiel spürbar schneller |
| 028 | [`028_countdown_skip.sql`](028_countdown_skip.sql) | Neue RPC `rpc_maybe_shorten_topic_vote`: Themen-Countdown springt auf 5s, sobald alle menschlichen Spieler abgestimmt haben (Bots zählen nicht) | Empfohlen (Feature) |
| 029 | [`029_song_guess_mode.sql`](029_song_guess_mode.sql) | Musik-Modus: `song_pool` (85 echte Songtitel über die 4 Musik-Kategorien) + `lobbies.current_song_id` — ersetzt die sichtbare Spotify-Ambient-Playlist durch einen versteckten, pro Halter rotierenden Song (iTunes-30s-Preview clientseitig, Titel wird nie gerendert). `rpc_advance_from_countdown`/`rpc_pass_potato`/`rpc_tick_game` ziehen bei jedem Halterwechsel neu, `rpc_attempt_pass` prüft im Song-Modus gegen genau den einen aktuellen Song statt die ganze Kategorie-Antwortliste | Empfohlen (Feature) |

**Wichtig für 023/024:** der Client muss ab sofort bei jedem Supabase-Request den Header `x-kumpir-session` mitschicken (`apps/web/src/lib/supabaseClient.ts` + `supabaseServer.ts` machen das automatisch) — ohne dieses Frontend-Update lehnen alle Spiel-/Host-Aktionen mit `invalid_session` ab.

## Was du **NICHT** machen musst

- **Migration für Teleport/Reverse**: Deine `rpc_pass_potato` und `rpc_tick_game` enthalten die Mode-Logik **bereits**. Die `pass_direction`-Spalte ist auch schon da. Kein Migrations-Bedarf.
- **Migration für Auth**: `profiles`, `handle_new_user`-Trigger, `sync_profile_verification`, `lobby_admin_sessions` sind alles schon vorbereitet. Auth lässt sich per `NEXT_PUBLIC_AUTH_DISABLED=0` reaktivieren, sobald das Frontend dafür bereit ist (Etappe 3).

## Wenn etwas schief geht

Jede Migration steht in einem `BEGIN; ... COMMIT;`-Block. Wenn ein Statement fehlschlägt, wird der ganze Block zurückgerollt — du musst nichts manuell aufräumen.

Bei Konflikten (z.B. „relation already exists"): die Migrations sind mit `IF NOT EXISTS` und `ON CONFLICT DO NOTHING` geschrieben, also sollten sie auch nach Mehrfach-Anwendung sauber bleiben. Falls doch was hakt: Fehler-Text hierher, ich passe an.
