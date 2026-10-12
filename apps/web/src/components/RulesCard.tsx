"use client";

import React, { useId, useState } from "react";
import { Collapse } from "@/components/ui/Collapse";
import { tk, useI18n } from "@/lib/i18n";

type Props = {
    /** Beim Hosten eingeklappt lassen, in der Wartelobby aufgeklappt. */
    defaultOpen?: boolean;
    /** "outside": schlanker Streifen außerhalb der Karte (z. B. unter dem Host-Formular). */
    variant?: "inline" | "outside";
};

const RULES: { icon: string; text: string }[] = [
    { icon: "🎧", text: tk("Ein Song läuft: Titel (1 Punkt), Künstler (½) oder beides zusammen (1,5 Punkte) tippen und die Kumpir weitergeben. Feature-Partner zählen auch.") },
    { icon: "🔥", text: tk("Wer sie beim Knall hält, fliegt raus – die Zündschnur wird jede Runde kürzer.") },
    { icon: "⏱️", text: tk("Richtige Antworten, schwere Songs und Treffer in Folge geben Bonuszeit.") },
    { icon: "🛡️", text: tk("Schutzzeit: Wer die Kumpir bekommt, hat immer mindestens 6–9 Sekunden – auch wenn sie in letzter Sekunde kam.") },
    { icon: "⚡", text: tk("Schnell abgeben lohnt sich: unter 5 Sekunden gibt es +5 Punkte.") },
    { icon: "🏆", text: tk("Wer zuletzt übrig bleibt, gewinnt. Bei mehreren Runden zählt die Summe.") },
];

/** "So wird gespielt": rollt beim Antippen auf (Collapse) statt sofort aufzuspringen. */
export function RulesCard({ defaultOpen = true, variant = "inline" }: Props) {
    const { tr } = useI18n();
    const [open, setOpen] = useState(defaultOpen);
    const id = useId();
    return (
        <section className={`rulesCard ${variant === "outside" ? "rulesOutside" : ""} ${open ? "isOpen" : ""}`}>
            <button type="button" className="rulesHead" aria-expanded={open} aria-controls={id} onClick={() => setOpen((v) => !v)}>
                <span>📖 {tr("So wird gespielt")}</span>
                <span className="rulesChevron" aria-hidden>
                    ▾
                </span>
            </button>
            <Collapse open={open} id={id}>
                <ul className="rulesList">
                    {RULES.map((r, i) => (
                        <li key={r.text} className="rollItem" style={{ ["--i" as string]: i }}>
                            <span className="rIcon" aria-hidden>
                                {r.icon}
                            </span>
                            <span>{tr(r.text)}</span>
                        </li>
                    ))}
                </ul>
            </Collapse>

            <style>{`
        .rulesCard{
          margin-top: 14px;
          border-radius: 18px;
          background: rgba(0,0,0,.18);
          border: 1px solid rgba(255,255,255,.12);
          padding: 12px 16px;
          transition: background .3s ease, border-color .3s ease;
        }
        .rulesCard.isOpen{ background: rgba(0,0,0,.24); border-color: rgba(255,255,255,.18); }
        .rulesOutside{
          margin: 2px auto 0;
          width: min(100%, 560px);
          padding: 8px 14px;
          background: rgba(20,8,4,.38);
          border: 1px solid var(--glass-line);
          backdrop-filter: blur(6px);
        }
        .rulesHead{
          display: flex; width: 100%; align-items: center; justify-content: space-between; gap: 10px;
          padding: 0; border: 0; background: none; color: inherit; font: inherit;
          cursor: pointer; font-weight: 950; font-size: 15px; user-select: none; text-align: left;
        }
        .rulesOutside .rulesHead{ font-size: 13.5px; justify-content: center; }
        .rulesChevron{ display: inline-block; transition: transform .45s cubic-bezier(.22,1,.36,1); opacity: .8; }
        .rulesCard.isOpen .rulesChevron{ transform: rotate(180deg); }
        .rulesList{ margin: 0; padding: 10px 0 2px; list-style: none; display: grid; gap: 8px; }
        .rulesList li{ display: grid; grid-template-columns: 28px 1fr; gap: 8px; font-size: 13px; line-height: 1.4; }
        .rulesList .rIcon{ font-size: 20px; line-height: 1.2; }
      `}</style>
        </section>
    );
}
