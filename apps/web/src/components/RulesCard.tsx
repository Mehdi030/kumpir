"use client";

import React from "react";

type Props = {
    /** Beim Hosten eingeklappt lassen, in der Wartelobby aufgeklappt. */
    defaultOpen?: boolean;
    /** "outside": schlanker Streifen außerhalb der Karte (z. B. unter dem Host-Formular). */
    variant?: "inline" | "outside";
};

const RULES: { icon: string; text: string }[] = [
    { icon: "🎧", text: "Ein Song läuft: Titel tippen (1 Punkt) oder den Interpreten (½ Punkt) und die Kumpir weitergeben." },
    { icon: "🔥", text: "Wer sie beim Knall hält, fliegt raus – die Zündschnur wird jede Runde kürzer." },
    { icon: "⏱️", text: "Richtige Antworten, schwere Songs und Treffer in Folge geben Bonuszeit." },
    { icon: "🏆", text: "Wer zuletzt übrig bleibt, gewinnt. Bei mehreren Runden zählt die Summe." },
];

export function RulesCard({ defaultOpen = true, variant = "inline" }: Props) {
    return (
        <details className={`rulesCard ${variant === "outside" ? "rulesOutside" : ""}`} open={defaultOpen}>
            <summary>📖 So wird gespielt</summary>
            <ul className="rulesList">
                {RULES.map((r) => (
                    <li key={r.text}>
                        <span className="rIcon" aria-hidden>{r.icon}</span>
                        <span>{r.text}</span>
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
        .rulesOutside{
          margin: 2px auto 0;
          width: min(100%, 560px);
          padding: 8px 14px;
          background: rgba(20,8,4,.38);
          border: 1px solid var(--glass-line);
          backdrop-filter: blur(6px);
        }
        .rulesCard summary{
          cursor: pointer;
          font-weight: 950;
          font-size: 15px;
          list-style: none;
          user-select: none;
        }
        .rulesOutside summary{ font-size: 13.5px; text-align: center; }
        .rulesCard summary::-webkit-details-marker{ display:none; }
        .rulesList{ margin: 10px 0 0; padding: 0; list-style: none; display: grid; gap: 8px; }
        .rulesList li{ display: grid; grid-template-columns: 28px 1fr; gap: 8px; font-size: 13px; line-height: 1.4; opacity: .95; }
        .rulesList .rIcon{ font-size: 20px; line-height: 1.2; }
      `}</style>
        </details>
    );
}
