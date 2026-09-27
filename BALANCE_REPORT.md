# BALANCE-REPORT — Kumpir Spielmechanik-Audit

Stand: 2026-09-27 · Branch: `fix/clean-base`

## Methodik

Statt 5 komplette Matches blind durchzuspielen, habe ich die Mechanik zuerst
mathematisch durchgerechnet (Explosions-Timer-Formel, Mehrheits-Voting-
Formel, Pass-Reihenfolge pro Modus) und daraus gezielt die Szenarien
live nachgestellt, die am ehesten etwas kaputt machen. Ein 3-Spieler-Match
(ich + 2 Bots, Modus Original, Speed Blitz) hat dabei auf Anhieb **zwei
schwere, voneinander unabhängige Bugs** live reproduziert — beide sind
strukturell und unabhängig von der Spieleranzahl reproduzierbar, treffen
aber gerade bei wenigen Spielern besonders hart. Die restliche Analyse
(Tabelle unten) ist eine Kombination aus dieser Live-Verifikation und
Nachrechnen der exakten Formeln aus `calc_explode_seconds` und
`rpc_vote_answer` für 3–7 Spieler.

---

## 🔴 Kritischer Fund #1: Spiel friert für immer ein, sobald ein Bot hält

**Live reproduziert**, siehe unten für den genauen Ablauf.

`rpc_tick_game` (die Funktion, die eine abgelaufene Explosion tatsächlich
auslöst) wird **ausschließlich vom Browser des aktuellen Halters**
aufgerufen — [`game/[code]/page.tsx:624-628`](apps/web/src/app/game/%5Bcode%5D/page.tsx#L624-L628):

```ts
if (iAmHolderNow) {
    const explodeMs = Date.parse(nextLobby.explode_at);
    const due = !Number.isNaN(explodeMs) && Date.now() >= explodeMs - 150;
    if (meAlive && due) void rpcTickGame(code);
}
```

Ein Bot hat aber **keinen eigenen Browser** — für ihn ruft niemand jemals
`rpc_tick_game` auf. Sobald ein Bot hält und sein Pass-Versuch aus
irgendeinem Grund nicht rechtzeitig durchgeht, tickt die Explosions-Uhr
im UI zwar auf "🔴 KRITISCH", aber **niemand erklärt sie serverseitig für
abgelaufen** — die Runde friert für immer ein. Sobald nur noch Bots übrig
sind (z.B. weil alle Menschen schon raus sind), gibt es **niemanden mehr,
der das Spiel jemals beenden könnte.**

**Live-Ablauf (Lobby `ZTHP`, 3 Spieler: Mehdi + Bot Anna + Bot Ben, Blitz-Speed):**
1. Ich halte zuerst, sage "Titanic", Pass wird angenommen.
2. Direkt danach zeigt die UI mich als "Du schaust zu." — das heißt laut
   Code (`iAmEliminated`-Flag) nicht "du bist nicht dran", sondern
   **"du bist raus"**. Ein Debug-Log hat bestätigt: `is_alive: false` für
   mich, obwohl ich gerade erfolgreich gepasst hatte.
3. Bot Anna hält jetzt, Bot Ben ist "danach" — beides Bots, kein Mensch
   mehr im Spiel.
4. 45+ Sekunden und ein kompletter Seiten-Reload später: Bot Anna hält
   immer noch, Status "🔴 KRITISCH", **keine Explosion, keine Elimination,
   keine Fortschritt** — obwohl Blitz-Speed bei 3 Spielern maximal ~17s
   Rundendauer erlaubt (`calc_explode_seconds`).

**Ursache von Schritt 2 (Bonus-Fund #2, ebenfalls live beobachtet):**
Der Poll-Loop jedes Clients prüft `explode_at` alle 650ms (weil Realtime
in meiner Testumgebung down war, siehe unten) — inklusive **des eigenen
Clients, während man gerade eine gültige Antwort tippt und abschickt**.
Bei Blitz-Speed (9–16.7s Rundendauer bei 3 Spielern) reicht die Zeit zum
Lesen, Tippen und Abschicken einer Antwort knapp — wenn `explode_at`
in der Millisekunde erreicht wird, in der man gerade seinen
`rpc_attempt_pass` abschickt, kann man sich **selbst explodieren, obwohl
man rechtzeitig geantwortet hat**. Das erklärt, warum mein "erfolgreicher"
Pass in Wirklichkeit eine Elimination war, die zufällig zum selben
nächsten Halter geführt hat (bei Original-Modus ist "nächster Sitzplatz"
sowohl das Pass-Ziel als auch das Elimination-Reassignment-Ziel — beide
Fälle sehen im UI identisch aus).

**Warum das kein Einzelfall meiner Testumgebung ist:** Die
WebSocket-Verbindung zu Supabase Realtime schlug in meiner Browser-Pane
fehl (`ERR_NAME_NOT_RESOLVED`), wodurch der Client auf den 650ms-Polling-
Fallback zurückfiel. Genau dieser Fallback ist es, der das Renn-Fenster
für Fund #2 öffnet — bei stabilem Realtime ist das Fenster kleiner, aber
nicht null (Netzwerk-Jitter, kurzzeitige Tab-Drosselung, langsames Handy
etc. reichen ebenfalls). Fund #1 (Bot hält = Spiel friert ein) ist davon
komplett unabhängig und tritt **immer** ein, sobald der aktuelle Halter
kein aktiver menschlicher Client mehr ist.

**Empfohlener Fix (robust, ändert keine Spielregeln/Balance):**
Die `iAmHolderNow`-Bedingung in der Tick-Prüfung entfernen bzw. auf
"jeder lebende, verbundene Spieler prüft mit" erweitern. `rpc_tick_game`
ist bereits idempotent (`FOR UPDATE` + `if v_now < v_explode_at then
return`) — mehrere gleichzeitige Aufrufer sind unschädlich, es gewinnt
einfach der erste. Das macht den ohnehin vorhandenen Timer nur
zuverlässig, ohne Tempo/Schwierigkeit zu verändern. **Ich würde diesen
Fix umsetzen, sobald du grünes Licht gibst** (er berührt
`game/[code]/page.tsx`, das laut ursprünglichem Auftrag nicht ohne
Rückfrage an der Spiellogik geändert werden sollte).

---

## 🟠 Fund #2: Mehrheits-Voting verlangt bei genau 3 lebenden Spielern Einstimmigkeit

Aus `rpc_vote_answer`: `v_needed := (v_alive / 2) + 1`, wobei `v_alive`
= lebende Spieler **außer** dem Halter.

| Lebende Spieler (N) | Voter (v_alive) | Needed | Anteil |
|---|---|---|---|
| 2 | 1 | 1 | 100 % (normal — 1v1-Duell) |
| **3** | **2** | **2** | **100 % — EINSTIMMIG** |
| 4 | 3 | 2 | 67 % |
| 5 | 4 | 3 | 75 % |
| 6 | 5 | 3 | 60 % |
| 7 | 6 | 4 | 67 % |
| 8 | 7 | 4 | 57 % |

Bei genau 3 lebenden Spielern braucht ein Pass **beide** übrigen Spieler
als Zustimmung — nicht nur eine Mehrheit. Es gibt **keinerlei Timeout**
für einen hängenden `pass_attempt` (kein Cron, kein Fallback — im Code
existiert zwar der Status `'timeout'` im TypeScript-Typ, er wird aber
nirgends je gesetzt). Das bedeutet:

- **Ein einzelner ablehnender oder einfach nicht abstimmender Spieler
  blockiert bei N=3 JEDEN Pass komplett und dauerhaft.** Der Halter kann
  nicht mal eine neue Antwort versuchen (`rpc_attempt_pass` blockt mit
  `attempt_already_open`, solange der alte Versuch offen ist) — er kann
  nur noch auf die Explosion warten.
- Kombiniert mit Fund #1: Sobald diese Blockade auftritt und der Halter
  dadurch explodiert (oder — schlimmer — der Halter ein Bot ist), friert
  das Spiel komplett ein.
- **Jedes Match, egal mit wie vielen Spielern gestartet, durchläuft
  zwangsläufig diese Einstimmigkeits-Phase bei N=3**, kurz vor dem
  Finale — das ist strukturell der fragilste Moment in JEDEM Match, nicht
  nur in 3-Spieler-Lobbies.
- **Exploit:** Ein einzelner Spieler kann durch konsequentes Ablehnen
  (oder Disconnect/AFK) gezielt entscheiden, wer bei N=3 explodiert —
  ohne dass die anderen etwas dagegen tun können.

**Empfehlung (Balance-Änderung, zur Entscheidung vorgelegt statt
umgesetzt):** Bei kleinen `v_alive` (1–2) entweder (a) eine reine
Mehrheit der tatsächlich abgegebenen Stimmen statt aller möglichen Voter
verlangen, oder (b) einen Timeout einbauen, der einen hängenden Versuch
nach z.B. 8–10s anhand der bis dahin abgegebenen Stimmen entscheidet
(oder im Zweifel zugunsten des Halters auflöst, statt ihn explodieren zu
lassen).

---

## 🟡 Fund #3: "Reverse"-Modus ist deterministisch, nicht "gelegentlich"

Die Modus-Beschreibung auf der Host-Seite sagt: *"Die Richtung wechselt
gelegentlich. Mehr Chaos, mehr Lacher."* Der Code
(`rpc_pass_potato` + `rpc_tick_game`) flippt `pass_direction` aber
**bei jedem einzelnen erfolgreichen Pass UND bei jeder Elimination** —
also nicht "gelegentlich", sondern strikt alternierend und komplett
vorhersagbar (kein `random()` beteiligt). Kein Sicherheits-Bug, aber ein
Diskrepanz zwischen Beschreibung und tatsächlichem Verhalten, die das
Modus schwächer/berechenbarer macht als beworben.

**Empfehlung:** Entweder Text anpassen ("wechselt bei jedem Pass") oder
Logik auf echte Zufälligkeit umstellen (z.B. 25–35% Flip-Chance pro
Pass) — beides eine Design-Entscheidung, keine reine Bugfix.

## 🟡 Fund #4: "Teleport" verliert sein Chaos genau im Finale

`rpc_pass_potato`s Teleport-Zweig wählt zufällig unter allen lebenden
Spielern außer dem Halter. Bei genau 2 lebenden Spielern (jedes Match
endet dort) gibt es nur noch einen möglichen Empfänger — Teleport
verhält sich in der spannendsten Phase des Matches exakt wie Original.
Kein Bug, aber erwähnenswert für die "Fühlt sich das Modus konsistent
an?"-Frage.

## 🟡 Fund #5: `used_answers` kann Bots in langen Matches/Practice-Mode "verhungern" lassen

`used_answers` wird korrekt einmal pro Match geleert (Migration 010),
sammelt sich aber über **alle** Pässe des kompletten Matches (nicht pro
Eliminations-Runde). Bots kennen pro Kategorie nur 8–12 feste Antworten
(`apps/web/src/lib/botAnswers.ts`). Bei vielen Spielern/Pässen in einem
einzigen, langen Timer-Fenster (z.B. Calm-Speed + 7-8 Spieler) kann der
Bot-Antwortpool einer schwachen Kategorie (z.B. "Elektronik-Marken", 9
Einträge) **innerhalb eines einzigen Matches** aufgebraucht sein — Bots
greifen dann auf `BOT_FALLBACK` (`"Keine Ahnung", "Pizza", "Auto", ...`)
zurück, was andere Bots wahrscheinlich ablehnen (das simuliert zwar
"Schwierigkeit", trifft aber nur Practice-Mode, da echte Menschen nicht
auf eine feste Wortliste beschränkt sind).

**Einschätzung:** Kein Bug für echte Multiplayer-Spiele (Menschen sind
kreativ), aber ein reales Problem für Practice-Mode mit vielen Bots bei
sparsamen Kategorien — verstärkt Fund #2/#1, weil abgelehnte
Fallback-Antworten die Pass-Versuche der Bots häufiger in die
Ablehnungs-Zone treiben.

## 🔵 Bekannt, weiterhin offen: `rpc_toggle_ready` ohne Self-Check

Bereits in [TESTREPORT.md](TESTREPORT.md) vermerkt: Jeder Client kann
mit einer beliebigen `p_player_id` togglen, nicht nur der eigenen. Passt
hier rein, weil es genau die Art "Fairness-Lücke" ist, nach der gefragt
wurde — weiterhin nicht behoben, da Rückfrage nötig (ändert eine
bestehende RPC-Signatur/Semantik).

---

## Bewertungs-Tabelle: Spielbarkeit nach Spieleranzahl

| Spieler | Bewertung | Begründung |
|---|---|---|
| **3** | ⚠️ **Fragil** | Startet SOFORT in der Einstimmigkeits-Zone (Fund #2). Kürzestes Match (nur 2 Eliminationen bis zum Sieger) — wenig Zeit, die Mechanik überhaupt zu genießen, bevor die fragile Phase greift. Practice-Mode mit 2 Bots: hohes Risiko für Fund #1 (Freeze), sobald der einzige Mensch früh rausfliegt. |
| **4** | 🙂 **Mittel** | Ein "gesunder" Mehrheits-Schritt (67% bei N=4) bevor die Einstimmigkeits-Phase bei N=3 erreicht wird. Gleiches Endgame-Risiko wie oben, aber mit etwas mehr Vorlauf. |
| **5** | 🙂 **Gut** | Zwei gesunde Mehrheits-Stufen (75%, 67%) vor der fragilen Phase. Guter Kompromiss aus Spannung und Robustheit — solange Fund #1/#2 nicht zuschlagen. |
| **6** | ✅ **Gut** | Drei Stufen mit angenehmen 57–75%-Mehrheiten. Fühlt sich am ausgewogensten an von allen getesteten Größen — Voting-Mehrheiten liegen durchgehend in einem fairen Bereich, bis auf die immer gleiche Endphase. |
| **7** | ✅ **Gut, mit Vorbehalt** | Mehr Runden mit fairen Mehrheiten (57–75%) als jede kleinere Lobby. ABER: mehr Spieler = mehr Pässe pro Zeitfenster = höheres Risiko für Fund #5 (Antwortpool-Erschöpfung) in Practice-Mode, besonders bei Calm-Speed. |

**Gemeinsamer Nenner für ALLE Größen:** Jedes Match endet zwangsläufig in
derselben fragilen N=3→N=2-Sequenz (Fund #2), und jedes Mal, wenn der
aktuelle Halter kein aktiver Mensch mehr ist — Bot oder Disconnect —
droht Fund #1 (permanenter Freeze). Das sind die zwei Themen, die die
Spielerfahrung unabhängig von der gewählten Lobby-Größe am stärksten
beeinträchtigen; die Spieleranzahl selbst ist innerhalb von 3–7 gut
balanciert (Voting-Mehrheiten zwischen 57–75% fühlen sich durchgehend
fair an).

## Priorisierte Empfehlung

1. **[Kritisch, robust, kein Balance-Eingriff]** Fund #1 fixen: Tick-Check
   nicht mehr an `iAmHolderNow` binden, sondern an jeden lebenden,
   verbundenen Client. → Sag Bescheid, dann setze ich das um.
2. **[Hoch, Balance-Entscheidung]** Fund #2: Timeout oder
   Voting-Formel-Anpassung für kleine `v_alive`. → Deine Entscheidung,
   welche Variante.
3. **[Niedrig, Cosmetic/Design]** Fund #3/#4: Beschreibung anpassen oder
   Logik — deine Präferenz.
4. **[Niedrig, bereits bekannt]** `rpc_toggle_ready` Self-Check ergänzen.
