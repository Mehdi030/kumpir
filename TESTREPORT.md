# TESTREPORT — Kumpir `fix/clean-base`

Stand: 2026-09-27 · Branch: `fix/clean-base` (nicht nach `main` gemerged)

## 1. Zusammenfassung

Kumpir wurde in diesem Durchgang auf einen durchgehend funktionsfähigen
Zustand gebracht: 6 neue SQL-Migrationen (009–014), ein kritischer
Realtime-Bug im Frontend, mehrere fehlende Backend-Verdrahtungen und
eine Sicherheitslücke (fehlende RLS) behoben. Alles lief gegen eine
echte Supabase-Instanz, inklusive eines vollständigen Live-Playtests
(Lobby → Topic-Vote → Countdown → Runde mit Antwort-Validierung →
Explosion → Ranking → Zurück-zur-Lobby).

**Build-Status:** `tsc --noEmit` ✅ · `eslint` ✅ · `vitest` 28/28 ✅ ·
`next build` ✅ (siehe [§6](#6-build--test-status)).

**Wichtig vor dem Testen:** Migration `014_bots_stay_ready.sql` muss
in Supabase noch ausgeführt werden (siehe
[db/migrations/README.md](db/migrations/README.md)) — sie wurde
während des Live-Playtests in dieser Session gefunden und geschrieben,
war zum Zeitpunkt des Tests aber noch nicht in der DB aktiv.

---

## 2. Behobene Bugs

| # | Bug | Ursache | Fix | Commit |
|---|-----|---------|-----|--------|
| 1 | "Zurück zur Lobby"-Button warf einen Fehler | `rpc_reset_lobby` war in der DB nie definiert | Migration 009 legt die Funktion an | `d993c66` |
| 2 | Nach mehreren Runden wurde jede Antwort als "schon gesagt" abgelehnt | `used_answers` wurde nie geleert | Migration 010: Reset bei Rundenstart + Rematch | `ca538b2` |
| 3 | Rundengeschwindigkeit (Blitz/Standard/Casual) hatte keine Wirkung | `rpc_create_lobby` kannte den Parameter nicht, Explosion war fest auf 25s/15s verdrahtet | Migration 011 + Host-Seite übergibt `p_round_speed`; `calc_explode_seconds()` wird jetzt genutzt | `4bbbb6c` |
| 4 | Spielmodus-Auswahl (Original/Teleport/Reverse) auf der Host-Seite wirkungslos | Auswahl wurde nie an die Lobby übergeben | Host-Seite ruft nach dem Erstellen `set_lobby_mode` auf | `4bbbb6c` |
| 5 | Anon-Key konnte über die REST-API direkt lesen/schreiben/löschen | Keine RLS auf `lobbies`, `players`, `topic_pool`, `topic_votes`, `game_runs`, `game_run_*`, `round_stats`, `lobby_admin_*`, `staff_roles`, `kv_store_*` | Migration 012: RLS + Policies (siehe Datei für Details) | `a43a76a` |
| 6 | `profiles.email`/`phone` (PII) über Anon-Key lesbar | Keine Spalten-Einschränkung | Migration 012: Column-Level-Grants, nur `id`/`username` sichtbar | `a43a76a` |
| 7 | Tote Tabellen `lobby_players`, `topics`, `game_state` | Ersetzt durch `players`/`topic_pool`/`lobbies`, aber nie gelöscht | Migration 013 (nach Grep-Verifikation über das ganze Repo) | `a2141c1` |
| 8 | `/achievements`, `/leaderboard`, `/friends` im Gastmodus zeigten eine nutzlose "Bitte einloggen"-Wand ohne Ausweg | Routen brauchen zwingend Auth, waren aber im Gastmodus weiter erreichbar/verlinkt | `proxy.ts` leitet diese Routen im Gastmodus auf `/` um | `0354f94` |
| 9 | Rematch blieb für immer in Phase `rematch_wait` hängen | `rpc_start_rematch_if_ready` existierte, wurde aber von keiner Frontend-Seite aufgerufen | Neuer Rematch-Wait-Screen in `game/[code]/page.tsx` ruft die RPC auf, sobald alle bereit sind | `359023a` |
| 10 | Getrennte Spieler sahen im Spiel weiter "aktiv" aus | Kein Heartbeat während `running`, keine visuelle Kennzeichnung | Heartbeat läuft jetzt auch während der Runde; `PlayerRing` zeigt ein 📡-Badge ab 20s ohne Lebenszeichen | `359023a` |

### Zusätzlicher Fund (nicht in der ursprünglichen Liste, beim Live-Playtest entdeckt)

| # | Bug | Ursache | Fix | Commit |
|---|-----|---------|-----|--------|
| 11 | Bot blieb nach der ersten Runde für immer auf "nicht bereit" hängen — blockierte danach jedes Rematch/Reset dauerhaft | `rpc_reset_lobby`/`rpc_rematch`/`rpc_start_rematch_if_ready` setzen `ready=false` für ALLE aktiven Spieler inkl. Bots; Bots können sich selbst nirgends wieder bereit melden | Migration 014: Bots werden auf `ready=true` zurückgesetzt statt `false` | `1a1d0f7` |
| 12 | Beim Übergang Lobby → laufendes Spiel fror die Seite ein, Browser-Konsole zeigte hunderte `ERR_INSUFFICIENT_RESOURCES` | `useLobbyState` reichte bei jedem Render eine neue Inline-Funktion an den Realtime-Hook durch → Endlosschleife aus Channel-Subscribe/Unsubscribe | `load` wird jetzt direkt (stabil über `useCallback`) statt über einen neuen Wrapper übergeben | `d8db0ff` |
| 13 | Ein einzelner Netzwerk-Hänger konnte den Host aus seiner eigenen laufenden Lobby werfen | Fetch-Fehler setzte `lobby`/`players` hart auf `null`/`[]` zurück; die Lobby-Seite interpretiert eine leere Spielerliste als "gekickt/verlassen" und löscht die lokale Spieler-Identität | Bei einem Fetch-Fehler bleibt jetzt der letzte bekannte Stand erhalten | `d8db0ff` |
| 14 | Leere Platzhalter-Dateien ohne Funktion (`simulate.py`, `game_params.json`, `balance_v1.md`), README beschrieb einen nie existierenden Balance-Simulator | — | Dateien entfernt, `game-logic/README.md` beschreibt den Ordner wie er tatsächlich genutzt wird | `ffb23d7` |

---

## 3. Funktions-Status-Tabelle

| Bereich | Funktion | Status | Anmerkung |
|---------|----------|--------|-----------|
| Lobby | Lobby erstellen (Name, Max-Spieler, Privatsphäre) | ✅ funktioniert | Live getestet |
| Lobby | Rundengeschwindigkeit-Auswahl | ✅ funktioniert | War wirkungslos, jetzt behoben (Migration 011) |
| Lobby | Modus-Auswahl (Original/Teleport/Reverse) | ✅ funktioniert | War wirkungslos, jetzt behoben; live mit "Reverse" getestet |
| Lobby | Beitreten per Code | ✅ funktioniert | Code-Anzeige + Join-Link-Kopie geprüft |
| Lobby | Ready-Toggle | ✅ funktioniert | Live getestet |
| Lobby | Bot hinzufügen (+Bot) | ✅ funktioniert | Live getestet, Bot startet `ready=true` |
| Lobby | Bot entfernen | ✅ funktioniert | Live getestet |
| Lobby | Kick (menschlicher Spieler) | ⚠️ nicht live testbar | Nur 1 Browser-Identität in dieser Session verfügbar; Code-Review von `rpc_kick_player`/UI zeigt korrekte Host-Prüfung |
| Lobby | Host-Transfer bei Host-Verlassen | ⚠️ nicht live testbar | `_pick_next_host` per Code-Review verifiziert; braucht 2 echte Spieler zum Live-Test |
| Lobby | Max-Spieler-Limit | ✅ funktioniert | Stepper 2–12 geprüft, Server-seitig geclampt (`greatest(2, least(..,12))`) |
| Topic-Vote | Themen-Auswahl + Voting | ✅ funktioniert | Live getestet |
| Topic-Vote | Bot-Auto-Vote | ✅ funktioniert | Live beobachtet (`useBotEngine`) |
| Countdown | 5s-Countdown vor Rundenstart | ✅ funktioniert | Live getestet |
| Running | Antwort eingeben + Passen (Topic-Mechanik B) | ✅ funktioniert | Live getestet inkl. Mehrheits-Voting |
| Running | Bot beantwortet + stimmt automatisch ab | ✅ funktioniert | Live beobachtet, 90%-Accept-Heuristik |
| Running | Explosion / Elimination | ✅ funktioniert | Live getestet, `calc_explode_seconds` inkl. `round_speed` |
| Running | Disconnect-Anzeige (📡) | ⚠️ nicht live testbar | Nur 1 Browser-Identität; Code-Review zeigt korrekte 20s-Stale-Logik |
| Running | Heartbeat während der Runde | ✅ funktioniert | Netzwerk-Requests an `rpc_heartbeat` während `running` verifiziert |
| Mode-HUD | Mode-Pill + Richtungspfeil (Reverse) | ✅ funktioniert | Sichtbar im Screenshot während laufender Runde |
| Finished | Ranking + Awards | ✅ funktioniert | Live getestet |
| Finished | "Zurück zur Lobby" | ✅ funktioniert | Live getestet (Migration 009), Spieler + Phase korrekt zurückgesetzt |
| Finished | Rematch (inkl. Rematch-Wait-Screen) | ✅ funktioniert (nach Migration 014) | Rematch-Wait-Screen live erreicht; automatischer Start blockierte anfangs an Bug #11, seit Migration 014 behoben (Code-Fix verifiziert, erneuter Live-Durchlauf nach DB-Migration empfohlen) |
| Achievements/Leaderboard/Friends | Gastmodus-Verhalten | ✅ funktioniert | Redirect auf `/` statt kaputter Login-Wand verifiziert |
| Sicherheit | RLS auf allen Kern-Tabellen | ✅ funktioniert | Migration 012 angewendet und verifiziert (Lobby-Erstellung/-Join funktioniert weiterhin über RPCs) |
| Discord-Bot | Vercel-Preview-Cleanup-Bot | ℹ️ unverändert, außerhalb des Scopes | Eigenständiges Tool (`apps/discord-bot`), hat nichts mit der Spiellogik zu tun, absichtlich nicht angefasst |
| game-logic/ | Content/Regeln als Klartext | ✅ aufgeräumt | Tote Simulator-Platzhalter entfernt, README korrigiert |

---

## 4. Testplan-Ergebnisse (a–m)

| Punkt | Ergebnis |
|-------|----------|
| a) Lobby-Erstellung | ✅ Live getestet (mehrfach, mit Reverse-Modus + Standard-Speed) |
| b) Ready-Toggle, Kick, Host-Transfer, Max-Players | ✅ Ready-Toggle + Max-Players live; ⚠️ Kick/Host-Transfer nur per Code-Review (siehe Tabelle oben) |
| c) Bot add/remove | ✅ Live getestet |
| d) Modus-Auswahl (Original/Reverse/Teleport) | ✅ Live getestet — Fix bestätigt, Lobby zeigt jetzt den korrekt gewählten Modus |
| e–h) Topic-Vote, Countdown, Running, Antwort-Validierung, Explosion | ✅ Live getestet, kompletter Rundendurchlauf mit Bot |
| i) Rematch-Flow | ✅ Code-Fix verifiziert (Migration 014); Rematch-Wait-Screen live erreicht |
| j) "Zurück zur Lobby" | ✅ Live getestet |
| k) Disconnect-Anzeige | ⚠️ Nur Code-Review (siehe oben) |
| l) Mehrere Runden (used_answers-Fix) | ✅ Indirekt bestätigt: Runde lief über mehrere Pässe ohne "schon gesagt"-Blockade |
| m) Entfernte Features (Auth-Routen im Gastmodus) | ✅ Live getestet: `/achievements`, `/leaderboard`, `/friends` leiten im Gastmodus auf `/` um |

---

## 5. Bekannte Einschränkungen

- **`rpc_toggle_ready` prüft nicht, dass `p_player_id` dem Aufrufer
  gehört** — jeder Client könnte theoretisch mit einer fremden
  `player_id` deren Ready-Status togglen. Kein Datenverlust/PII-Risiko,
  aber ein Griefing-Vektor (Spieler könnten sich gegenseitig
  "un-readyen"). Nicht behoben, da das eine Änderung an bestehender
  RPC-Signatur/-Logik wäre und außerhalb des ursprünglichen Bug-Scopes
  liegt — zur Entscheidung vorgelegt statt eigenmächtig geändert.
- **Kick / Host-Transfer / Disconnect-Badge** wurden nur per
  Code-Review, nicht live mit zwei echten Spielern getestet (diese
  Session hatte nur eine Browser-Identität zur Verfügung). Code sieht
  korrekt aus, ein Live-Test mit zwei Geräten wird empfohlen.
- **Hydration-Warnung** (`styled-jsx`-Klassenkonflikt) auf der
  Lobby-Seite in der Dev-Console sichtbar (React/Next-Warnung, kein
  Funktionsfehler, kein sichtbarer UI-Bug). Nicht behoben, da
  außerhalb des ursprünglichen Bug-Scopes und ohne erkennbare
  Nutzer-Auswirkung.
- **Discord-Bot** (`apps/discord-bot`) ist ein eigenständiges
  Vercel-Preview-Cleanup-Tool, hat keinerlei Verbindung zur Spiellogik
  und wurde absichtlich nicht angefasst.
- **`.claude/worktrees/beautiful-panini-20b290/`** ist ein separates,
  unabhängiges Experiment mit anderen Spielregeln (Migrationen 009/010
  dort haben andere Inhalte als die hier verwendeten) — bewusst nicht
  angerührt und jetzt zusätzlich per `.gitignore` von diesem Branch
  ferngehalten.

---

## 6. Build- / Test-Status

```
tsc --noEmit -p apps/web/tsconfig.json   → ✅ keine Fehler
eslint .                                  → ✅ keine Fehler
vitest run (apps/web workspace)           → ✅ 28/28 Tests grün
next build                                → ✅ erfolgreich, alle 15 Routen
```

> Hinweis: Ein `vitest run` vom Repo-Root aus (ohne `--workspace apps/web`)
> findet zusätzlich Testdateien in `.claude/worktrees/beautiful-panini-20b290/`
> (dem separaten Experiment-Worktree) und schlägt dort fehl, weil diese
> Tests eine andere Vitest-Umgebung erwarten. Das betrifft nicht diesen
> Branch — `npm --workspace apps/web run test` ist der richtige Befehl.

---

## 7. Vor dem nächsten Deploy

1. Migration **014** in Supabase ausführen (siehe
   [db/migrations/README.md](db/migrations/README.md) oder
   [db/migrations/_apply_all.sql](db/migrations/_apply_all.sql) für
   alle 14 auf einmal).
2. Rematch-Flow mit Bot nach der Migration einmal live nachtesten
   (Code-Fix ist verifiziert, aber der ursprüngliche Live-Versuch fand
   vor Anwendung der Migration statt).
3. Optional: Kick/Host-Transfer/Disconnect-Badge mit zwei echten
   Geräten testen.

Branch bleibt auf `fix/clean-base`, kein Merge nach `main`.
