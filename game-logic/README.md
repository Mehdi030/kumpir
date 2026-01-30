# 🎮 Kumpir – Game Logic (`game-logic/`)

Willkommen im Bereich **Game Logic** 👋  
Dieser Ordner ist der Ort, an dem Spielregeln, Fairness und Balance von **Kumpir** logisch entwickelt, getestet und verbessert werden.

Hier wird **nicht** die Website gebaut und **keine Datenbank verändert** –  
sondern das Spiel als System verstanden, simuliert und optimiert.

---

## 🧠 Ziel dieses Bereichs

Der Zweck von `game-logic/` ist es:

- ⚖️ Spielregeln klar zu definieren
- 🔍 Fairness & Balance zu überprüfen
- 🧪 Spielabläufe zu simulieren
- 📊 Entscheidungen daten- und logikbasiert vorzubereiten

Alles, was hier entsteht, wird **später gezielt** ins eigentliche Spiel übernommen.

---

## 🧩 Einordnung im Gesamtprojekt

Das Kumpir-Projekt besteht grob aus drei Ebenen:

1. 🎨 **Frontend (`apps/…`)**  
   → Das, was Spieler sehen (UI, Lobby, Buttons)

2. 🧩 **Backend & Daten (`supabase/…`)**  
   → Lobbys, Spieler, Spielstatus, Timer

3. ⚙️ **Game Logic (`game-logic/`) ← dieser Ordner**  
   → Regeln, Simulationen, Analyse, Vorbereitung

Dieser Ordner ist **bewusst getrennt**, damit Logik unabhängig vom laufenden Spiel entwickelt werden kann.

---

## 📁 Ordnerstruktur

```txt
game-logic/
├─ README.md              # diese Datei
├─ rules.md               # Spielregeln in Klartext
├─ game_params.json       # zentrale Spielparameter
│
├─ simulator/
│  └─ simulate.py         # Python-Simulation von Spielrunden
│
├─ content/
│  └─ questions_de.json   # Kategorien & Fragen für das Spiel
│
├─ reports/
│  └─ balance_v1.md       # Auswertungen & Empfehlungen
```

---

## 🧑‍💡 Deine Rolle in diesem Bereich

Du arbeitest hier als **Game-Logic & Analysis Contributor**.

Dein Fokus liegt auf Fragen wie:
- ⚖️ Fühlt sich das Spiel fair an?
- 👥 Haben alle Spieler vergleichbare Chancen?
- 🎛️ Welche Parameter verbessern den Spielfluss?
- 😕 Wo entstehen frustrierende Spielsituationen?

Du arbeitest **technisch mit Python**, aber **schrittweise und geführt**.

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

## ⚙️ `game_params.json` – Zentrale Spielparameter

Diese Datei enthält alle wichtigen Werte, die das Spiel steuern, z.B.:

- ⏱️ Rundenzeit
- 👥 maximale Spieleranzahl
- 💣 Mindestzeit bis Explosion
- 🧩 aktivierte Spielmodi

```json
{
  "round_seconds": 40,
  "min_explode_after_receive_seconds": 3,
  "max_players": 8,
  "modes": {
    "reverse": true,
    "teleport": false
  }
}
```

Diese Parameter werden:
- hier analysiert & getestet
- später ins echte Spiel übernommen

---

## 🧪 `simulator/` – Spielabläufe mit Python simulieren

Im Ordner `simulator/` wird mit Python ein **logischer Spielsimulator** gebaut.

Ziel:
- viele Spielrunden automatisch durchspielen
- Muster & Ungleichgewichte erkennen
- fundierte Empfehlungen ableiten

---

## 📊 `reports/` – Ergebnisse & Empfehlungen

Hier werden Ergebnisse dokumentiert:

- Gewinner-/Verlierer-Verteilungen
- auffällige Spielsituationen
- Vorschläge für bessere Parameter

---

## 🐍 Warum Python?

Python wird hier genutzt als:
- Analyse-Tool
- Simulations-Werkzeug
- Logik-Sprache

Nicht als:
- Frontend-Technologie
- Backend-Ersatz
- Produktionscode

---

## 🔄 Wie Ergebnisse ins Spiel kommen

Simulation → Report → Entscheidung → Umsetzung im Spiel

---

## 🚀 Wie du startest

1. `rules.md` lesen & ergänzen
2. `game_params.json` verstehen
3. erstes Python-Skript im `simulator/` bauen
4. Simulationen durchführen
5. Ergebnisse dokumentieren

---

## 🧩 Kurz gesagt

`game-logic/` ist die **Denk- und Test-Schicht** von Kumpir.

Hier wird das Spiel verstanden, getestet und verbessert –  
bevor Änderungen ins Live-System kommen 🎮
