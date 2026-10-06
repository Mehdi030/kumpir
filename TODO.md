# KUMPIR – ToDo

Reihenfolge = Priorität. Erledigtes wandert nach unten.

## Als Nächstes
- [ ] **Account-System mit Login** (Grundlage steht, Ausbau läuft)
  - [x] Login (E-Mail oder Username), Registrierung mit Username-Check, E-Mail-Bestätigung, Passwort-Reset – bestanden schon, Auth ist aktiv
  - [x] Konto-Seite `/profile` (Stats, Saison-Punkte, Passwort ändern, Abmelden), Konto-Link auf der Startseite
  - [x] Username wird beim Hosten/Beitreten vorbelegt; Endseite zeigt „gespeichert“ bzw. „Konto erstellen“
  - [x] Profil-Seite und Header mit einer Test-Sitzung gerendert (Desktop/Handy) – echter Login mit echten Daten steht noch aus
  - [ ] Registrierung und Mail-Versand einmal mit einem echten Postfach durchtesten (Mail-Texte auf Deutsch, Absender)
  - [ ] Gast → Konto: Spielstand der laufenden Gast-Identität beim Registrieren übernehmen
  - [ ] Avatar/Farbe im Profil wählen, Konto löschen (DSGVO), Username ändern
  - [ ] Optional: Login mit Google/Apple

## Spiel
- [ ] **Balance Duell/Tempo:** In großen Lobbys ist die Duell-Zündschnur zu kurz (Blitz, 12 Spieler: Ø 4,4 s ohne Bonus; Überlebenschance eines normalen Spielers sinkt von 72 % auf 34 %). Vorschlag: Mindest-Zündschnur 6 s, Tempo-Boden 60 % statt 45 % (Simulation: db/scripts/simulate-humans.mjs)
- [ ] Balance Rache-Pass: jeder Ausgeschiedene darf einmal drehen – mehrere Tote können die Kartoffel gezielt auf einen Spieler lenken. Vorschlag: höchstens 1 Drehung pro Zündschnur-Phase oder 10 s Abklingzeit
- [ ] Balance Raten: Falschantwort kostet nur 1 s Sperre, unbegrenzt viele Versuche (Durchprobieren von Interpreten). Vorschlag: Sperre steigt (1 s, 2 s, 3 s) oder -0,5 s Zündschnur je Fehlversuch
- [ ] Balance Fähigkeitsgefälle: bei 2 guten + 2 normalen + 2 schwachen Spielern gewinnt ein guter Spieler ~92 % der Matches, ein schwacher nie. Vorschlag: Aufholmechanik (z. B. +1 Joker für den Letzten der Zwischenwertung)
- [ ] Balance Punkte: Clutch-Pässe machen nur 1–5 % der Punkte aus (praktisch egal) – Wert erhöhen (25) oder streichen
- [ ] Vorzeitiges Match-Ende, wenn ein Spieler uneinholbar vorne liegt
- [ ] Song-Bekanntheit prüfen (Ziel: ≥ 85 % kennen jeden Titel) – Vorschau-Audit ist erledigt (Migration 069), aber ob jeder Titel bekannt ist, kann nur ein Mensch beurteilen (v. a. Deutschrap/Shisha Club)
- [ ] Teleport- und Reverse-Modus (derzeit „Kommt bald“)

## Technik
- [ ] Uhr-Abweichung beim Voting-Countdown (einmal 25 s statt 10 s angezeigt) reproduzieren
- [ ] Hydration-Warnung beim Lade-Spinner (nur Dev-Modus)

## Erledigt
- [x] Austritt bricht das Spiel nicht mehr ab (Spieler wird wie eliminiert, Host-Nachfolge = Mensch, Ergebnisse bleiben) – Migration 073
- [x] Rundenende bei <=1 Lebenden läuft immer über _finish_round; Host-Kick und Austritt beachten die Richtung
- [x] Bot-Balance angeglichen (Profi ~32 % statt ~41 % in der Simulation, Anfänger ~8 %)
- [x] Song-Schwierigkeit geglättet, nur Menschen zählen für die Statistik
- [x] Tote Alt-Funktionen entfernt (rpc_create_lobby-Altformen, rpc_start_game, set_ready ...)
- [x] Sicherheitslücke geschlossen: Fremde konnten per API die Kumpir weitergeben, Spieler eliminieren/kicken und Lobbys verlassen lassen (Migration 071)
- [x] Regression behoben: Combo/Rache-Pass/Richtung wurden pro Runde nicht mehr zurückgesetzt (Migration 072)
- [x] Bots unterschiedlich stark (Anfänger/Mittel/Profi, Auswahl in der Lobby)
- [x] Runden pro Match (1/3/5) mit Zwischenstand und Gesamtwertung
- [x] Server-Bots (unabhängig vom Host-Browser)
- [x] Faires Themen-Voting (2 Playlists + Zufallskarte) und 6 Playlists
- [x] Tisch-Redesign, Ausscheide-Pop-ups, Vorschau-Linie nur für Halter und Ausgeschiedene
- [x] Endseite aufgeräumt, UI-Theme „Kumpir Pop“
