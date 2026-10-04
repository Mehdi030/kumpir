# KUMPIR – ToDo

Reihenfolge = Priorität. Erledigtes wandert nach unten.

## Als Nächstes
- [ ] **Account-System mit Login** (Grundlage steht, Ausbau läuft)
  - [x] Login (E-Mail oder Username), Registrierung mit Username-Check, E-Mail-Bestätigung, Passwort-Reset – bestanden schon, Auth ist aktiv
  - [x] Konto-Seite `/profile` (Stats, Saison-Punkte, Passwort ändern, Abmelden), Konto-Link auf der Startseite
  - [x] Username wird beim Hosten/Beitreten vorbelegt; Endseite zeigt „gespeichert“ bzw. „Konto erstellen“
  - [ ] Registrierung und Mail-Versand einmal mit einem echten Postfach durchtesten (Mail-Texte auf Deutsch, Absender)
  - [ ] Gast → Konto: Spielstand der laufenden Gast-Identität beim Registrieren übernehmen
  - [ ] Avatar/Farbe im Profil wählen, Konto löschen (DSGVO), Username ändern
  - [ ] Optional: Login mit Google/Apple

## Spiel
- [ ] Bots unterschiedlich stark (Anfänger / Profi), damit ein Sieg nicht zufällig ist
- [ ] Vorzeitiges Match-Ende, wenn ein Spieler uneinholbar vorne liegt
- [ ] Host-Kick während der Runde: Richtung der Weitergabe korrekt berücksichtigen
- [ ] Song-Bekanntheit prüfen (Ziel: ≥ 85 % kennen jeden Titel) – unbekannte Titel aus Deutschrap/Shisha Club ersetzen
- [ ] Teleport- und Reverse-Modus (derzeit „Kommt bald“)

## Technik
- [ ] Uhr-Abweichung beim Voting-Countdown (einmal 25 s statt 10 s angezeigt) reproduzieren
- [ ] Hydration-Warnung beim Lade-Spinner (nur Dev-Modus)

## Erledigt
- [x] Runden pro Match (1/3/5) mit Zwischenstand und Gesamtwertung
- [x] Server-Bots (unabhängig vom Host-Browser)
- [x] Faires Themen-Voting (2 Playlists + Zufallskarte) und 6 Playlists
- [x] Tisch-Redesign, Ausscheide-Pop-ups, Vorschau-Linie nur für Halter und Ausgeschiedene
- [x] Endseite aufgeräumt, UI-Theme „Kumpir Pop“
