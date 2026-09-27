# 🎮 KUMPIR

KUMPIR ist ein browserbasiertes Partyspiel nach dem Prinzip der „heißen Kartoffel".
Eine Lobby, mehrere Spieler, ein unsichtbarer Timer – wer die Kartoffel beim Explodieren hält, verliert die Runde.

Fokus: **einfach erklärt, gemeinsam gespielt, schnell gestartet**.

---

## 🧠 Projektstruktur

Monorepo, npm workspaces.

- `apps/web` → Web-Spiel (Next.js 16 + React 19 + Supabase + TypeScript)
- `apps/discord-bot` → Discord-Bot für Preview-Notifications
- `game-logic/` → Spielregeln in Klartext & Content (`questions_de.json`) — siehe `game-logic/README.md`

**Web und Logic sind klar getrennt** und werden nicht vermischt.

---

## 🚀 Schnellstart

```bash
# Einmalig: Dependencies installieren
npm install

# Erstes Setup: legt .env.local an und startet Dev-Server
cd apps/web
npm run play
```

Die `play`-Befehl fragt nach deinen Supabase-Werten (URL + Anon Key), schreibt `apps/web/.env.local` und startet anschließend `next dev`. Du brauchst die Werte nur einmal — sie liegen unter Supabase → Project Settings → API.

**Schon eingerichtet?** Einfach `npm run dev` (root) oder `npm --workspace apps/web run dev`.

---

## 🧪 Tests, Lint, Build

```bash
cd apps/web

npm test          # Vitest, alle Unit-Tests
npm run lint      # ESLint
npm run build     # Next-Production-Build
npx tsc --noEmit  # TypeScript strict check
```

CI läuft auf jedem Push/PR (siehe `.github/workflows/ci.yml`) und checkt alle vier.

---

## 👥 Team & Zuständigkeiten

- **Medo** – Web / Game Lead → arbeitet in `apps/web`
- **Sero** – Logic / Balance → arbeitet in `game-logic`

Jeder bleibt in seinem Ordner, `main` ist die gemeinsame Wahrheit.

---

## 🌿 Git-Workflow

### Branches
- `main` → gemeinsame Wahrheit (nie direkt bearbeiten)
- `web` → Web-Entwicklung (Vercel-Preview hängt hier dran)
- `logic` → Logic-Entwicklung

### Grundregeln
- **Nie auf `main` arbeiten**
- **Vor dem Arbeiten:** `git pull`
- **Vor dem Merge in `main`:** `git pull` auf `main`
- Jeder bleibt in seinem Workspace (`apps/web` bzw. `game-logic/`)

---

## 🧾 Commit-Konvention

Deutsche, einfache Konvention für einen sauberen Verlauf.

### Format
```
typ(bereich): beschreibung
```

### Beispiel
```
feat(host): lobby erstellen
fix(setup): play-Script auf Windows fixen
```

### Commit-Typen
- **chore** – Setup & Organisation
- **feat** – Neue Funktion
- **fix** – Fehlerbehebung
- **refactor** – Code umstrukturieren
- **docs** – Dokumentation
- **style** – Optik / Formatierung
- **test** – Tests

### Bereiche (optional)
`setup · db · host · join · lobby · players · game · ui · realtime · auth`

### Regeln
- Deutsch, Präsens, kurz & klar
- 1 Commit = 1 Thema
- Keine Emojis im Commit-Text

---

## 🔐 Auth-Modus

Aktuell läuft das Spiel im **Gast-Modus** (`NEXT_PUBLIC_AUTH_DISABLED=1` in `.env.local`).

- Spielen ohne Account — Identität liegt nur in `localStorage` (`kumpir_player_id`)
- Login/Register/Verified-Routen werden vom Proxy (`src/proxy.ts`, Next.js 16 Middleware-Konvention) auf `/` umgeleitet
- `/achievements`, `/leaderboard`, `/friends` sind Auth-only und daher im Gast-Modus bewusst unverlinkt (kein Nav-Eintrag zeigt hin) **und** werden vom Proxy ebenfalls auf `/` umgeleitet, falls jemand die URL direkt aufruft — die Seiten/DB-Objekte bleiben erhalten, nur unerreichbar
- Für die spätere Etappe 3 (Achievements, Leaderboards, Freundeslisten) wird Auth wieder aktiviert

---

## 🚀 Ziel des Projekts

Erst ein **stabiles Basisspiel**.
Danach Modi, Achievements, soziale Features.

Kein Overengineering, kein Chaos – **Spaß zuerst**.
