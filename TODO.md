# KUMPIR – ToDo

Reihenfolge = Priorität. Erledigtes wandert nach unten.

## Als Nächstes
- [x] **Sicherheit (Migrationen 080–082, Okt. 2026)**: Angriffstest `node db/scripts/security-attack.mjs` (120 Angriffe: SQL-Injection, fremde Konten/Lobbys übernehmen, interne Funktionen aufrufen, Spam, eingeschleustes HTML …) → alle blockiert. Next.js 16.3.8 (0 bekannte Lücken), Sicherheits-Header (CSP, X-Frame-Options, HSTS), sichere Weiterleitung nach Login, Login verrät nicht mehr, ob ein Benutzername existiert
  - Admins werden nie ausgesperrt: keine Rate-Limits für Admins, letzter Admin kann nicht entfernt/gesperrt werden. **Notfall vom Laptop:** `node db/scripts/restore-admin.mjs mehdi` (macht wieder zum aktiven Admin, hebt Sperren auf; `--reset-mail` schickt zusätzlich eine Passwort-Reset-Mail)
  - Neue DB-Funktionen sind ab jetzt standardmäßig gesperrt → in der Migration ausdrücklich `GRANT EXECUTE … TO anon, authenticated` (Spiel) bzw. `TO authenticated` (Konto) setzen und den Angriffstest erneut laufen lassen
- [x] **Statistik-Test mit Konto „Claude“**: `node db/scripts/play-claude.mjs --reset` spielt 5 Matches gegen Bots über die echten Schnittstellen (unterschiedliche Bots/Tempo/Playlist/Eingaben) und vergleicht danach die Profil-Statistik mit den Eingaben. Zugangsdaten in `db/.env.local`
- [ ] **Konto-Verlauf & Analyse (Migration 076) mit echten Spielern prüfen**: 2 echte Konten ein Match spielen lassen, danach Profil (Verlauf, Musik, Gegner, Rückblick) und /admin/stats (Songs, Balance, Weg der Spieler) ansehen. DB-Test: `node db/scripts/test-account-history.mjs`
  - [x] A Match-Verlauf, B Musik-Statistik pro Playlist, C Gegner-Bilanz, D Musik-/Match-Achievements, E Monats-Rückblick (teilbar), F Matches/Runden getrennt, G Song-Bekanntheit, H Balance aus echten Zügen, I Weg der Spieler (anonym)
  - [ ] Nach 2–4 Wochen echter Spiele: Song-Liste (rot markierte Songs austauschen) und Balance-Punkte unten mit echten Zahlen entscheiden
- [x] **Admin-Panel** `/admin` (Migration 078): Rollen Admin/Supporter, Nutzer sperren/entsperren, Namen/Avatar zurücksetzen, Passwort-Reset-Mail, Rollen vergeben (Admin), Löschanträge (Spieler beantragt → Zugang sofort zu → Admin löscht endgültig oder lehnt ab), Lobbys schließen, Songs archivieren (Admin), Protokoll aller Aktionen. DB-Test: `node db/scripts/test-admin-panel.mjs`
  - [ ] Mit echtem Admin-Konto einmal durchklicken (Nutzer sperren/entsperren, Löschantrag ablehnen)
- [x] **Playlists auswählbar** (Standard alle, rausnehmen beim Hosten/in den Lobby-Einstellungen/im Profil; Solo beachtet die Auswahl)
- [x] **Deutschrap aktuell** (Migration 079): 240 Songs der letzten 4 Jahre, Rapper-Liste in `db/scripts/data/deutschrap-rapper.json`, neu bauen mit `node db/scripts/build-deutschrap.mjs db/migrations/079_deutschrap_aktuell.sql`. Lücken: Capital Bra, Bonez MC, Haftbefehl, Kollegah, Farid Bang, Kalazh44 haben keine passenden iTunes-Vorschauen für neue Songs (0 Songs). Nach ein paar Spielen unbekannte Songs im Admin-Panel → Songs archivieren
- [x] Musik startet zuverlässig (gemeinsamer Player, Freischaltung beim ersten Tipp, automatisches Nachholen) – auf echtem iPhone/Android noch gegenprüfen
- [ ] **Account-System mit Login** (Grundlage steht, Ausbau läuft)
  - [x] Login (E-Mail oder Username), Registrierung mit Username-Check, E-Mail-Bestätigung, Passwort-Reset – bestanden schon, Auth ist aktiv
  - [x] Konto-Seite `/profile` (Stats, Saison-Punkte, Passwort ändern, Abmelden), Konto-Link auf der Startseite
  - [x] Username wird beim Hosten/Beitreten vorbelegt; Endseite zeigt „gespeichert“ bzw. „Konto erstellen“
  - [x] Profil-Seite und Header mit einer Test-Sitzung gerendert (Desktop/Handy) – echter Login mit echten Daten steht noch aus
  - [ ] Registrierung und Mail-Versand einmal mit einem echten Postfach durchtesten (Mail-Texte auf Deutsch, Absender)
  - [ ] Gast → Konto: Spielstand der laufenden Gast-Identität beim Registrieren übernehmen
  - [x] Konto-Einstellungen (Migration 077): Avatar (Emoji + Farbe), Spielername, Benutzername ändern, E-Mail ändern, Passwort ändern, Konto löschen; Sprache/Ton/Solo-Gegner/Host-Standards werden im Konto gespeichert und gelten auf allen Geräten. DB-Test: `node db/scripts/test-account-settings.mjs`
  - [x] Login robuster: Passwort-vergessen-Prüfung repariert (lehnte jede Adresse mit „s“ ab), fehlendes Profil (Konto „medo“) nachgetragen, Bestätigungsmail erneut senden, verständliche Meldungen bei abgelaufenem/auf anderem Gerät geöffnetem Link, Passwort einblenden
  - [x] Login war in der Produktion komplett abgeschaltet (Vercel: veraltetes NEXT_PUBLIC_AUTH_DISABLED=1) – Schalter heißt jetzt NEXT_PUBLIC_GUEST_ONLY, Login ist überall an. Alte Variable kann in Vercel gelöscht werden
  - [x] Sicherheit: Profile nur noch über geprüfte Funktionen änderbar (vorher konnte sich jeder Eingeloggte selbst zum Admin machen)
  - [ ] Echter Login-Test mit eigenem Konto: anmelden (E-Mail + Benutzername), Einstellungen ändern, auf zweitem Gerät prüfen, ob Sprache/Ton/Name mitkommen
  - [ ] Supabase-Dashboard: Mail-Texte auf Deutsch, Weiterleitungs-Liste enthält https://kumpir-web.vercel.app/** (sonst landen Mail-Links auf der falschen Seite)
  - [ ] Optional: Login mit Google/Apple

## Ideen aus der Gesamtanalyse (Außenstehende gewinnen)
- [x] 1. „Solo gegen Bots“ mit einem Tipp auf der Startseite (heute: 7 Klicks bis zum ersten Spiel)
- [x] 2. Einladen: WhatsApp-/Teilen-Knopf (Web Share), QR-Code in der Lobby
- [x] 3. Link-Vorschau (Open Graph, Vorschaubild, „Du wurdest eingeladen · Code …“), robots.txt, sitemap
- [ ] 4. Kurzes Tutorial in der ersten Runde (3 Hinweise zum Einblenden) + Ton beim ersten Klick freischalten
- [x] 5. Bild-Gewicht: HGLogo.png 2,4 MB → WebP 131 KB, echte App-Icons 192/512 px, eigenes favicon.ico statt Vercel-Dreieck
- [ ] 6. Schrift/JS: Inter entfernt (erledigt). Offen: Supabase/Auth nicht auf jeder Seite laden (Startseite ~244 KB JS gzip)
- [x] 7. Zuschauen statt „Lobby gesperrt“ für Nachzügler (mit „Jetzt mitspielen“ nach dem Match), Wiedereinstieg über den Einladungslink für eigene Mitspieler
- [ ] 8. Ergebnis teilen (Bild-Karte) erledigt. Offen: Revanche-Anreiz
- [ ] 9. Handy-Feinschliff: dvh mit vh-Rückfall erledigt. Offen: Tastatur-Verhalten, größere Tisch-Darstellung
- [x] 10. Barrierefreiheit: Tastatur-Fokus (nur Knöpfe/Links, Textfelder behalten eigene Optik), dunklere Glas-Karten. Kontrast nur geschätzt, nicht gemessen
- [ ] 11. Englisch: Schalter + Start, Solo, Beitreten, Einladen, Endbildschirm, Ergebnis-Bild. Offen: Host-, Lobby-, Spielseite, Fehlermeldungen. Standard bleibt Deutsch
- [x] 12. PWA-Hinweis + Offline-Seite (Service Worker auf jeder Seite, nur Produktion). Auf echtem Handy noch nicht getestet
- [ ] Wiedereinstieg, wenn der Server einen Spieler nach Verbindungsabbruch schon entfernt hat (Spiellogik – bewusst nicht angefasst)

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
