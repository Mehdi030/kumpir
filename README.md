## 🧾 Commit‑Konvention (RELAY)

Wir nutzen eine einfache, einheitliche Commit‑Konvention auf Deutsch.  
🎯 Ziel ist ein klarer, gut lesbarer Projektverlauf.

---

### 🧱 Format
```text
typ(bereich): kurze beschreibung
🏷️ Commit‑Typen
🧹 chore – Setup & Organisation
Projektstruktur, Konfiguration, Tooling
Beispiel:
chore: initiales projekt setup

✨ feat – Neue Funktionen
Neue Seiten, neue Features, neue Möglichkeiten
Beispiele:
feat(host): lobby erstellen
feat(join): lobby per code beitreten

🧠 core – Spielkern / Spiellogik
Alles, was das eigentliche Spiel betrifft
Beispiele:
core(game): grundlegende rundenlogik
core(timer): explodierenden timer hinzufügen

🐛 fix – Fehlerbehebungen
Bugfixes und unerwartetes Verhalten
Beispiele:
fix(lobby): ungültige lobby codes abfangen
fix(players): reconnect korrekt behandeln

🧭 Bereiche (optional, aber empfohlen)
setup

db

host

join

lobby

players

game

ui

realtime

📌 Regeln
🇩🇪 Deutsch verwenden

⏱️ Präsens („hinzufügen“, nicht „hinzugefügt“)

✂️ Kurz & konkret

🧩 1 Commit = 1 Gedanke

🚫 Keine Emojis im Commit‑Text

🚫 Keine Sammel‑Commits

🧠 Faustregel
⚙️ Setup? → chore

✨ Neue Funktion? → feat

🎮 Spielmechanik? → core

🐞 Fehler? → fix