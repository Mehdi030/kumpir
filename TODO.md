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

## Spiel (Fund der Simulation, nach Wichtigkeit)
- [ ] **Jeder Austritt bricht das ganze Spiel ab:** Wenn irgendein Spieler die Lobby verlässt (auch mitten in der Runde, in der Themenwahl, im Zwischenstand oder auf der Endseite), setzt ein Trigger die Lobby für ALLE auf „waiting“ zurück – Match, Runde und Ergebnisse sind weg. Soll: nur der Gehende wird entfernt, das Spiel läuft weiter (bei <2 Lebenden regulär beenden)
- [ ] Verlässt der Host mitten im Spiel, wird ein Bot zum Host (und nicht der nächste Mensch)
- [ ] `rpc_reconcile_lobby` beendet das Spiel bei ≤1 Lebenden direkt („finished“) statt über `_finish_round`: kein Rundenergebnis, keine Saison-Punkte, und ein Mehr-Runden-Match endet vorzeitig; außerdem alte feste Zündschnur (`round_seconds`)
- [ ] Bot-Balance: Profi gewinnt in der Simulation ~41 % gegen Mittel ~6 % und Anfänger ~3 % (bei 2 Profis + 2 Mittel + 2 Anfängern) – Abstand verkleinern, z. B. Profi-Treffer 0,97 → 0,9
- [ ] Song-Schwierigkeit (★) ist praktisch immer „mittel“: erst ab 5 Spielen pro Song wird sie berechnet (aktuell Ø 0,8) und Bot-Treffer verfälschen die Statistik – Bots aus `plays/hits` ausnehmen, Startwerte pro Song festlegen
- [ ] Alt-Funktionen aufräumen: 3× `rpc_create_lobby`, 3× `rpc_start_game`, `start_game`, `set_ready` u. a. (für Clients gesperrt seit Migration 071, aber noch vorhanden)
- [ ] Vorzeitiges Match-Ende, wenn ein Spieler uneinholbar vorne liegt
- [ ] Host-Kick während der Runde: Richtung der Weitergabe korrekt berücksichtigen
- [ ] Song-Bekanntheit prüfen (Ziel: ≥ 85 % kennen jeden Titel) – Vorschau-Audit ist erledigt (Migration 069), aber ob jeder Titel bekannt ist, kann nur ein Mensch beurteilen (v. a. Deutschrap/Shisha Club)
- [ ] Teleport- und Reverse-Modus (derzeit „Kommt bald“)

## Technik
- [ ] Uhr-Abweichung beim Voting-Countdown (einmal 25 s statt 10 s angezeigt) reproduzieren
- [ ] Hydration-Warnung beim Lade-Spinner (nur Dev-Modus)

## Erledigt
- [x] Sicherheitslücke geschlossen: Fremde konnten per API die Kumpir weitergeben, Spieler eliminieren/kicken und Lobbys verlassen lassen (Migration 071)
- [x] Regression behoben: Combo/Rache-Pass/Richtung wurden pro Runde nicht mehr zurückgesetzt (Migration 072)
- [x] Bots unterschiedlich stark (Anfänger/Mittel/Profi, Auswahl in der Lobby)
- [x] Runden pro Match (1/3/5) mit Zwischenstand und Gesamtwertung
- [x] Server-Bots (unabhängig vom Host-Browser)
- [x] Faires Themen-Voting (2 Playlists + Zufallskarte) und 6 Playlists
- [x] Tisch-Redesign, Ausscheide-Pop-ups, Vorschau-Linie nur für Halter und Ausgeschiedene
- [x] Endseite aufgeräumt, UI-Theme „Kumpir Pop“
