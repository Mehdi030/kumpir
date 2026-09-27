# 🎮 Kumpir – Game Logic (`game-logic/`)

Willkommen im Bereich **Game Logic** 👋
Dieser Ordner ist der Ort, an dem Spielregeln, Fairness und Balance von **Kumpir** in Klartext festgehalten werden.

Hier wird **nicht** die Website gebaut und **keine Datenbank verändert** –
sondern das Spiel als System beschrieben.

---

## 🧩 Einordnung im Gesamtprojekt

Das Kumpir-Projekt besteht grob aus drei Ebenen:

1. 🎨 **Frontend (`apps/web`)**
   → Das, was Spieler sehen (UI, Lobby, Buttons)

2. 🧩 **Backend & Daten (`db/`)**
   → Lobbys, Spieler, Spielstatus, Timer (siehe `db/README.md`)

3. ⚙️ **Game Logic (`game-logic/`) ← dieser Ordner**
   → Regeln & Content, unabhängig vom Code beschrieben

---

## 📁 Ordnerstruktur

```txt
game-logic/
├─ README.md              # diese Datei
├─ rules.md               # Spielregeln in Klartext
└─ content/
   └─ questions_de.json   # Kategorien & Fragen für das Spiel
```

Hinweis: Ein Python-Simulator für automatisierte Balance-Tests war hier
ursprünglich geplant (`simulator/simulate.py`, `game_params.json`,
`reports/balance_v1.md`). Er wurde nie gebaut — die Dateien waren leere
Platzhalter. Sie wurden entfernt, um nicht existierenden Code zu
dokumentieren. Die tatsächlichen Balance-Werte (Rundenzeiten, Modi-Chancen
etc.) leben direkt im Code (`apps/web/src/lib/gameConfig.ts` und
`db/functions.sql` → `calc_explode_seconds`). Falls ein Simulator später
gebraucht wird, kann dieser Abschnitt neu geschrieben werden, sobald
tatsächlich Code dafür existiert.

---

## 📝 `rules.md` – Spielregeln verstehen & formulieren

In `rules.md` werden die Spielregeln **in normaler Sprache** beschrieben:

- 🔄 Ablauf einer Runde
- 🥔 Übergabe der Kartoffel
- 💥 Explosion
- 🚨 Sonderfälle (z.B. Disconnects)
- 🔁 Spielmodi (Reverse, Teleport, etc.)

Ziel ist ein **klares Regelwerk**, das jeder im Team versteht.

---

## 📚 `content/questions_de.json` – Kategorien & Fragen

Enthält die Themen-Kategorien, aus denen `db/migrations/002_categories_seed.sql`
den `topic_pool` befüllt (siehe dortigen Kommentar für den Zusammenhang).

---

## 🧩 Kurz gesagt

`game-logic/` ist die **Regel-Dokumentation** von Kumpir — kein Code, keine
Datenbank, nur Klartext, auf den sich Frontend und Backend beziehen.
