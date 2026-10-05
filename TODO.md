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
- [ ] Vorzeitiges Match-Ende, wenn ein Spieler uneinholbar vorne liegt
- [ ] Host-Kick während der Runde: Richtung der Weitergabe korrekt berücksichtigen
- [ ] Song-Bekanntheit prüfen (Ziel: ≥ 85 % kennen jeden Titel) – Vorschau-Audit ist erledigt (Migration 069), aber ob jeder Titel bekannt ist, kann nur ein Mensch beurteilen (v. a. Deutschrap/Shisha Club)
- [ ] Teleport- und Reverse-Modus (derzeit „Kommt bald“)

## Technik
- [ ] Uhr-Abweichung beim Voting-Countdown (einmal 25 s statt 10 s angezeigt) reproduzieren
- [ ] Hydration-Warnung beim Lade-Spinner (nur Dev-Modus)

## Erledigt
- [x] Bots unterschiedlich stark (Anfänger/Mittel/Profi, Auswahl in der Lobby)
- [x] Runden pro Match (1/3/5) mit Zwischenstand und Gesamtwertung
- [x] Server-Bots (unabhängig vom Host-Browser)
- [x] Faires Themen-Voting (2 Playlists + Zufallskarte) und 6 Playlists
- [x] Tisch-Redesign, Ausscheide-Pop-ups, Vorschau-Linie nur für Halter und Ausgeschiedene
- [x] Endseite aufgeräumt, UI-Theme „Kumpir Pop“
