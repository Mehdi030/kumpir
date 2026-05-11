# 🗄️ KUMPIR — Datenbank-Verzeichnis

Hier liegt das **Datenbank-Schema** als Code (SQL).

> ✅ **Stand 2026-05-11:** `schema.sql` enthält das echte Schema (User-Dump vom Supabase-Dashboard). Funktionen und Policies fehlen noch — siehe HOW_TO_DUMP.md.

---

## Struktur

```
db/
├── README.md                         ← diese Datei
├── HOW_TO_DUMP.md                    ← Anleitung um echtes Schema/Funktionen/Policies zu exportieren
├── schema.sql                        ← echtes Tabellen-Schema (User-Dump 2026-05-11)
├── functions.sql                     ← TODO: echte RPC-Funktionen (Query 2 ausstehend)
├── policies.sql                      ← TODO: echte RLS-Policies (Query 3 ausstehend)
└── migrations/                       ← neue Schema-Änderungen, chronologisch nummeriert
    ├── 001_topic_validation.sql      ← Topic-Mechanik B (Antwort sagen + validieren)
    ├── 002_categories_seed.sql       ← 49 Kategorien für topic_pool
    └── 003_teleport_reverse_modes.sql ← Helper für Teleport/Reverse Modi
```

---

## 🔧 Dein echtes Schema dumpen

**Variante A — Supabase CLI (empfohlen, einmaliger Setup-Aufwand):**

```bash
# 1. Supabase CLI installieren (https://supabase.com/docs/guides/cli)
npm install -g supabase

# 2. Login in deinem Account
supabase login

# 3. Im Repo-Root: Projekt verknüpfen (Project-Ref findest du im Supabase-Dashboard URL)
supabase link --project-ref <DEIN_PROJECT_REF>

# 4. Schema dumpen (überschreibt die rekonstruierte Datei)
supabase db dump --schema public > db/schema.sql
supabase db dump --schema public --data-only > db/seed.sql   # optional
```

**Variante B — pg_dump direkt (wenn du Postgres-Connection-String hast):**

```bash
# Connection-String findest du im Supabase-Dashboard → Project Settings → Database
pg_dump "postgres://postgres:<PASSWORD>@db.<REF>.supabase.co:5432/postgres" \
  --schema-only --schema=public \
  > db/schema.sql
```

**Variante C — Supabase-Dashboard manuell:**

Dashboard → SQL Editor → führe aus:
```sql
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
ORDER BY proname;
```

Output kopierst du in `db/functions/`, aufgeteilt nach Funktion.

---

## 📝 Migrationen anwenden

Wenn ich eine neue Migration in `db/migrations/` lege:

1. Datei öffnen, SQL prüfen
2. Im Supabase-Dashboard → SQL Editor einfügen → ausführen
3. **Oder** mit CLI: `supabase db push`

Migrationen sind **nummeriert + zeitstabil** — niemals umbenennen oder umordnen, sonst Chaos auf produktiven DBs.

---

## 📦 Rekonstruierter Stand (was ich aus dem Code weiß)

### Tabellen
- `lobbies` — eine Lobby pro 4-Zeichen-Code
- `players` — Spieler einer Lobby (Identität: client-generierte UUID in `kumpir_player_id` LocalStorage)
- `topic_votes` — Voting-Stimmen während `phase = 'topic_vote'`
- `profiles` — (vermutet) Profile für authentifizierte User mit Username

### RPCs (21 Stück)

| RPC | Aufrufer | Zweck |
|-----|----------|-------|
| `rpc_create_lobby(p_host_name, p_privacy, p_max_players, p_round_seconds)` | Host-Page | Lobby anlegen, gibt `{code, host_player_id}` zurück |
| `rpc_join_lobby(p_code, p_player_id, p_name)` | Host + Join | Spieler beitreten (idempotent via Client-UUID) |
| `rpc_toggle_ready(p_lobby_id, p_player_id)` | Lobby-Page | Ready-Status umschalten |
| `rpc_begin_topic_vote(p_lobby_id, p_player_id)` | startGame action | Host startet, geht in `phase = topic_vote` |
| `rpc_vote_topic(p_lobby_id, p_player_id, p_choice)` | Game-Page | Spieler wählt Thema (1, 2, 3) |
| `rpc_finalize_topic_vote(p_lobby_id)` | Game-Page (Client-Tick) | Voting auswerten → Countdown |
| `rpc_advance_from_countdown(p_lobby_id)` | Game-Page (Client-Tick) | Countdown durch → Running |
| `rpc_tick_game(p_code)` | Game-Page (Holder bei Explosion) | Server prüft `explode_at`, eliminiert Halter, geht weiter |
| `rpc_pass_potato(p_code, p_player_id)` | Game-Page (Halter) | Kartoffel an nächsten Spieler im Ring |
| `rpc_rematch(p_code)` | Game-Page (Finished) | Neues Spiel mit gleicher Spielerliste |
| `rpc_reset_lobby(p_code)` | Game-Page (Finished) | Lobby auf Anfang zurücksetzen |
| `rpc_heartbeat(p_lobby_id, p_player_id)` | useHeartbeat | Alle 8s — markiert Spieler als "online" |
| `cleanup_lobby(p_lobby_id, p_stale_seconds)` | useHeartbeat (Host) | Spieler ohne Heartbeat seit `staleSeconds` rauswerfen |
| `kick_player(p_lobby_id, p_me_player_id, p_target_player_id)` | Admin-Page | Host kickt Spieler |
| `set_lobby_lock(p_lobby_id, p_me_player_id, p_locked)` | Admin-Page | Host sperrt/öffnet Lobby |
| `transfer_host(p_lobby_id, p_me_player_id, p_new_host_player_id)` | Admin-Page | Host-Rolle übertragen |
| `set_max_players(p_lobby_id, p_me_player_id, p_max_players)` | Settings | Max-Spieler ändern |
| `set_lobby_mode(p_lobby_id, p_me_player_id, p_mode)` | Settings | Game-Mode ändern |
| `set_lobby_topic(p_lobby_id, p_me_player_id, p_topic)` | Settings | Thema setzen |
| `is_username_available(p_username)` | Register | Username-Verfügbarkeit prüfen |
| (legacy) `join_lobby(p_lobby_code, p_name)` | ehemals JoinClient | wurde durch `rpc_join_lobby` ersetzt — kann später entfernt werden |
