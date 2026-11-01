# Song-Algorithmus – Vorschlag (Stand 2026-11-01)

**Wie es jetzt läuft:** Pro Frage wird ein zufälliger, noch nicht gespielter Song der gewählten Playlist genommen (`_quiz_candidates`,
`ORDER BY random()`). Zu jedem Song zählt die Datenbank mit, wie oft er gespielt und erkannt wurde (`song_pool.plays/hits`), daraus
folgt eine Schwierigkeit (`_song_difficulty`) – die Auswahl nutzt sie bisher nicht. Pool: 576 aktive Songs
(Deutschrap aktuell 346, Nostalgie 89, Asphalt 69, Top 50 50, ICON 22).

## Drei Bausteine (einzeln einführbar)

1. **Gewichtete Auswahl statt Zufall**
   - Songs, die selten gespielt wurden, bekommen mehr Gewicht (`1 / (1 + plays/10)`), damit nicht dieselben 60 Songs ständig kommen.
   - Mix aus leicht und schwer: je Runde möglichst ein Drittel leicht (Erkennungsquote > 70 %), ein Drittel mittel, ein Drittel schwer.
   - Nie zweimal denselben Künstler hintereinander.
2. **Songs raus / rein (Pflege)**
   - Raus (Archiv): Song nach mindestens 30 Spielen mit Erkennungsquote unter 8 % (zu schwer) oder über 97 % (zu leicht), oder
     wenn die Vorschau nicht mehr abspielbar ist.
   - Rein: Kandidatenliste im Admin-Panel (Künstler aus deinen Playlists, deren beliebteste Songs noch fehlen) – du tippst „übernehmen“.
     Nur sehr bekannte Künstler (so wie du es festgelegt hast, keine Nonames).
   - Archivierte Songs dürfen nach 60 Tagen eine zweite Chance bekommen.
3. **Playlists unterscheidbarer machen**
   - Ziel je Playlist ein erkennbarer Stil/Zeitraum (z. B. Asphalt = Straße, Nostalgie = bis 2015, ICON = Klassiker),
     damit die Auswahl vor dem Spiel einen echten Unterschied macht.

## Was ich von dir brauche
- Die Fragen 1.1–1.4 in `docs/FRAGEN.md` (woher neue Songs, automatisch oder mit Freigabe, Zielgröße, Archiv-Chance).
- Ob die Gewichtung (Baustein 1) schon vorher ohne Admin-Teil kommen soll – das ist klein und ändert nur die Reihenfolge der Songs.
