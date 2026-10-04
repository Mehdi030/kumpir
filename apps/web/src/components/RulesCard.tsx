"use client";

import React from "react";

type Props = {
    /** Beim Hosten eingeklappt lassen, in der Wartelobby aufgeklappt. */
    defaultOpen?: boolean;
};

const RULES: { icon: string; title: string; text: string }[] = [
    { icon: "🎧", title: "Song erkennen", text: "Ein Song läuft. Nenne den Titel (1 Punkt) oder als Notlösung den Interpreten (½ Punkt), um die Kumpir weiterzugeben." },
    { icon: "🔥", title: "Die Schnur brennt", text: "Wer die Kumpir hat, wenn die Zündschnur durch ist, fliegt raus. Mit jeder Runde wird die Schnur kürzer." },
    { icon: "⏱️", title: "Gute Antworten geben Zeit", text: "Titel gibt mehr Bonuszeit als Interpret. Schwere Songs und Treffer in Folge (Combo) geben extra." },
    { icon: "⚔️", title: "Finale = Duell", text: "Bei 2 Spielern ist die Schnur noch kürzer und es gibt keine Bonuszeit mehr." },
    { icon: "🃏", title: "Joker", text: "Einmal pro Runde den Song tauschen (−2 s). Ausgeschieden? Einmal die Richtung drehen." },
    { icon: "🏆", title: "Wertung", text: "Wer zuletzt übrig bleibt, gewinnt den Runde. Punkte = Platz + Song-Treffer + Clutch. Bei mehreren Rundenn zählt die Summe." },
];

export function RulesCard({ defaultOpen = true }: Props) {
    return (
        <details className="rulesCard" open={defaultOpen}>
            <summary>📖 So wird gespielt</summary>
            <ul className="rulesList">
                {RULES.map((r) => (
                    <li key={r.title}>
                        <span className="rIcon" aria-hidden>{r.icon}</span>
                        <span>
                            <b>{r.title}.</b> {r.text}
                        </span>
                    </li>
                ))}
            </ul>

            <style>{`
        .rulesCard{
          margin-top: 14px;
          border-radius: 18px;
          background: rgba(0,0,0,.18);
          border: 1px solid rgba(255,255,255,.12);
          padding: 12px 16px;
        }
        .rulesCard summary{
          cursor: pointer;
          font-weight: 950;
          font-size: 15px;
          list-style: none;
          user-select: none;
        }
        .rulesCard summary::-webkit-details-marker{ display:none; }
        .rulesList{ margin: 10px 0 0; padding: 0; list-style: none; display: grid; gap: 8px; }
        .rulesList li{ display: grid; grid-template-columns: 28px 1fr; gap: 8px; font-size: 13px; line-height: 1.4; opacity: .95; }
        .rulesList .rIcon{ font-size: 20px; line-height: 1.2; }
      `}</style>
        </details>
    );
}
