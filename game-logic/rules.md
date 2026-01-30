# 🥔 Kumpir – Spielregeln (`rules.md`)

Dieses Dokument beschreibt die **Spielregeln von Kumpir** in klarer, verständlicher Sprache.  
Es ist die **logische Grundlage** für Simulationen, Balancing und spätere technische Umsetzung.

---

## 🎯 Ziel des Spiels

Kumpir ist ein Party-Spiel, bei dem eine „heiße Kartoffel“ zwischen Spielern weitergegeben wird.  
Ziel ist es, **die Kartoffel rechtzeitig weiterzugeben**, bevor sie explodiert.

👉 Der Spieler, bei dem die Kartoffel explodiert, **verliert die Runde**.

---

## 👥 Spieler & Lobby

- Eine Runde besteht aus **mindestens 2 Spielern**
- Die maximale Spieleranzahl wird über die Lobby festgelegt
- Alle Spieler befinden sich in **einer gemeinsamen Lobby**
- Jeder Spieler ist genau **einmal aktiv** in der Runde

---

## ▶️ Start einer Runde

Eine Runde startet, wenn:
- alle Spieler bereit sind
- die Lobby den Status **„started“** erreicht

Beim Start:
- die Kartoffel wird **zufällig einem Spieler zugewiesen**
- ein **unsichtbarer Countdown** beginnt

---

## 🥔 Die Kartoffel

- Es gibt **genau eine Kartoffel** pro Runde
- Die Kartoffel kann immer nur **bei einem Spieler gleichzeitig** sein
- Ein Spieler mit Kartoffel gilt als **„aktiv“**

---

## 🔄 Übergabe der Kartoffel (Pass)

- Ein Spieler mit Kartoffel kann sie **an den nächsten Spieler weitergeben**
- Die Richtung ist standardmäßig **vorwärts** (im Uhrzeigersinn)
- Eine Übergabe ist nur möglich, wenn:
    - der Spieler aktiv ist
    - die Runde läuft

Optional:
- Übergaben können ein **Cooldown** haben
- Es kann eine **Mindestzeit** geben, bevor die Kartoffel explodieren darf

---

## 💥 Explosion

- Die Kartoffel explodiert **nach Ablauf des Countdowns**
- Die Explosion trifft **den Spieler, der die Kartoffel gerade hält**
- Nach der Explosion:
    - endet die Runde
    - der Verlierer steht fest

---

## 🔁 Spielmodi (optional)

### 🔄 Reverse-Modus
- Die Übergaberichtung kehrt sich um
- Reverse kann:
    - zufällig
    - zeitgesteuert
    - oder durch ein Event ausgelöst werden

### 🧩 Teleport-Modus
- Die Kartoffel springt zufällig zu einem anderen Spieler
- Der aktuelle Spieler verliert die Kartoffel sofort
- Teleport darf **nicht** auf denselben Spieler zurückspringen

---

## 🚨 Sonderfälle (Edge Cases)

### ❌ Spieler verlässt die Runde
- Verlässt ein Spieler ohne Kartoffel die Runde:
    - das Spiel läuft normal weiter
- Verlässt ein Spieler **mit Kartoffel** die Runde:
    - die Kartoffel wird sofort neu zugewiesen

### ⏸️ Spielunterbrechung
- Wenn zu wenige Spieler verbleiben:
    - wird die Runde beendet
- Das Spiel darf **nicht in einem undefinierten Zustand bleiben**

---

## ⚖️ Fairness-Regeln

Das Spiel gilt als fair, wenn:
- kein Spieler systematisch benachteiligt ist
- Explosionen nicht direkt nach Übergaben stattfinden
- alle Spieler vergleichbare Reaktionszeiten haben

Diese Regeln sind Grundlage für:
- Simulationen
- Parameter-Optimierung
- spätere Anpassungen

---

## 🧠 Zweck dieses Dokuments

Dieses Dokument dient als:
- gemeinsame Referenz für das Team
- Grundlage für Python-Simulationen
- Entscheidungshilfe bei Regeländerungen

Technische Details gehören **nicht** hier rein.

---

## 🧩 Kurz gesagt

`rules.md` beschreibt:
- **was im Spiel passiert**
- **wann es passiert**
- **was erlaubt ist**
- **was vermieden werden soll**

ohne technische Umsetzung 🎮
