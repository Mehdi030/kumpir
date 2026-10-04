# KUMPIR – ToDo

Reihenfolge = Priorität. Erledigtes wandert nach unten.

## Als Nächstes
- [ ] **Account-System mit Login** (startet direkt nach der UI-Überarbeitung)
  - Login / Registrierung (E-Mail + Passwort, optional Username) sauber durchziehen: Auth wieder produktiv aktivieren (`NEXT_PUBLIC_AUTH_DISABLED`)
  - Profil (Username, Avatar), Passwort-Reset, E-Mail-Bestätigung
  - Spielstände an den Account binden: Saison-Punkte, Siege, Achievements, Freunde (Tabellen/Seiten existieren bereits)
  - Gast → Account: laufende Gast-Identität beim Registrieren übernehmen
  - Login-Prompt am Spielende („Speichere deine Punkte“)

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
