## 🧾 RELAY Commit‑Konvention (v1)

Einfache Commit‑Konvention auf Deutsch.  
Ziel: klare Commits, kein Chaos.

---

### 🧱 Format
typ(bereich): beschreibung

Beispiel:
feat(lobby): lobby erstellen

---

### 🏷️ Commit‑Typen

🧹 **chore** – Setup & Organisation  
Beispiel:  
chore: initiales projekt setup

✨ **feat** – Neue Funktion  
Beispiel:  
feat(host): lobby erstellen

🧠 **core** – Spielkern / Spiellogik  
Beispiel:  
core(game): rundenlogik hinzufügen

🐛 **fix** – Fehler beheben  
Beispiel:  
fix(lobby): ungültige lobby codes abfangen

♻️ **refactor** – Code umstrukturieren  
Beispiel:  
refactor(db): lobby abfragen vereinfachen

📝 **docs** – Dokumentation  
Beispiel:  
docs: commit konvention ergänzen

🎨 **style** – Optik / Formatierung  
Beispiel:  
style(ui): abstände anpassen

---

### 🧭 Bereiche (optional)
setup · db · host · join · lobby · players · game · ui · realtime

---

### 📌 Regeln
- Deutsch
- Präsens
- Kurz & klar
- 1 Commit = 1 Thema
- Keine Emojis im Commit‑Text
