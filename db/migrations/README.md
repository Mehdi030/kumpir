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

## Was du **NICHT** machen musst

- **Migration für Teleport/Reverse**: Deine `rpc_pass_potato` und `rpc_tick_game` enthalten die Mode-Logik **bereits**. Die `pass_direction`-Spalte ist auch schon da. Kein Migrations-Bedarf.
- **Migration für Auth**: `profiles`, `handle_new_user`-Trigger, `sync_profile_verification`, `lobby_admin_sessions` sind alles schon vorbereitet. Auth lässt sich per `NEXT_PUBLIC_AUTH_DISABLED=0` reaktivieren, sobald das Frontend dafür bereit ist (Etappe 3).

## Wenn etwas schief geht

Jede Migration steht in einem `BEGIN; ... COMMIT;`-Block. Wenn ein Statement fehlschlägt, wird der ganze Block zurückgerollt — du musst nichts manuell aufräumen.

Bei Konflikten (z.B. „relation already exists"): die Migrations sind mit `IF NOT EXISTS` und `ON CONFLICT DO NOTHING` geschrieben, also sollten sie auch nach Mehrfach-Anwendung sauber bleiben. Falls doch was hakt: Fehler-Text hierher, ich passe an.
