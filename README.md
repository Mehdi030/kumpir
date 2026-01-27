# 🎮 KUMPIR

KUMPIR ist ein browserbasiertes Partyspiel nach dem Prinzip der „heißen Kartoffel“.
Eine Lobby, mehrere Spieler, ein unsichtbarer Timer – wer die Kartoffel beim Explodieren hält, verliert die Runde.

Fokus: **einfach erklärt, gemeinsam gespielt, schnell gestartet**.

---

## 🧠 Projektstruktur

Das Projekt ist als **Monorepo** aufgebaut.

- `apps/web` → Web-Spiel (Next.js / TypeScript / Supabase)
- `apps/logic` → Spiellogik & Content-Service (Python, separat)
- `main` → gemeinsamer, stabiler Stand

**Wichtig:**  
Web und Logic sind **klar getrennt** und werden nicht vermischt.

---

## 👥 Team & Zuständigkeiten

- **Medo** – Web / Game Lead  
  → arbeitet ausschließlich in `apps/web`

- **Sero** – Logic / Balance  
  → arbeitet ausschließlich in `apps/logic`

Jeder arbeitet auf **seinem eigenen Branch**, `main` wird nur zum Zusammenführen genutzt.

---

## 🌿 Git-Workflow (kurz & verbindlich)

### Branches
- `main` → gemeinsame Wahrheit (nie direkt bearbeiten)
- `web` → Web-Entwicklung
- `logic` → Logic-Entwicklung

### Grundregeln
- **Nie auf `main` arbeiten**
- **Vor dem Arbeiten:** `git pull`
- **Vor dem Merge in `main`:** `git pull` auf `main`
- Jeder bleibt in seinem Ordner (`apps/web` bzw. `apps/logic`)

---

## 🧾 Commit-Konvention

Wir nutzen eine **einfache, deutschsprachige Commit-Konvention**, um den Verlauf übersichtlich zu halten.

### Format
typ(bereich): beschreibung

shell
Code kopieren

### Beispiel
feat(host): lobby erstellen

markdown
Code kopieren

### Commit-Typen
- **chore** – Setup & Organisation
- **feat** – Neue Funktion
- **core** – Spielkern / Spiellogik
- **fix** – Fehlerbehebung
- **refactor** – Code umstrukturieren
- **docs** – Dokumentation
- **style** – Optik / Formatierung

### Bereiche (optional)
`setup · db · host · join · lobby · players · game · ui · realtime`

### Regeln
- Deutsch
- Präsens
- Kurz & klar
- 1 Commit = 1 Thema
- Keine Emojis im Commit-Text

---

## 🚀 Ziel des Projekts

Zuerst ein **stabiles Basisspiel**.  
Danach optionale Modi, Genres und Erweiterungen.

Kein Overengineering, kein Chaos – **Spaß zuerst**.





