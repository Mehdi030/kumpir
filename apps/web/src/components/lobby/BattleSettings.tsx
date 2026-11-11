"use client";

import { useState } from "react";
import { useI18n } from "@/lib/i18n";
import { BATTLE_CRITERIA, criterionInfo, type BattleCriterion } from "@/lib/battle";

/**
 * Einstellung für „Hit oder Flop“ (Migration 143): nach welchem Prinzip entscheidet die Jury?
 * Der Host wählt, alle anderen sehen es. Änderungen gehen sofort an den Server.
 */
export function BattleSettings({
    criterion,
    canEdit,
    onSave,
    onError,
}: {
    criterion: BattleCriterion;
    canEdit: boolean;
    onSave: (next: BattleCriterion) => Promise<string | null>;
    onError: (msg: string) => void;
}) {
    const { tr } = useI18n();
    const [pending, setPending] = useState<BattleCriterion | null>(null);
    const cur = pending ?? criterion;
    const info = criterionInfo(cur);

    const pick = async (next: BattleCriterion) => {
        if (!canEdit || next === cur) return;
        setPending(next);
        const err = await onSave(next);
        setPending(null);
        if (err) onError(err);
    };

    return (
        <div className="lobbyPl bsBox">
            <div className="lobbyPlHead" style={{ cursor: "default" }}>
                <span>🔥 {tr("Hit oder Flop – Prinzip der Jury")}</span>
                <span className="lobbyPlCount">
                    {info.icon} {tr(info.label)}
                </span>
            </div>
            <div className="lobbyPlBody">
                <div className="bsPills" role="radiogroup" aria-label={tr("Prinzip der Jury")}>
                    {BATTLE_CRITERIA.map((c) => (
                        <button key={c.key} type="button" role="radio" aria-checked={cur === c.key} className={`bsPill ${cur === c.key ? "on" : ""}`} disabled={!canEdit} onClick={() => void pick(c.key)}>
                            <span aria-hidden>{c.icon}</span> {tr(c.label)}
                        </button>
                    ))}
                </div>
                <div className="lobbyPlHint">
                    {tr(info.hint)} · {canEdit ? tr("Mindestens 3 Spieler: eine Jury und zwei, die gegeneinander antreten – reihum.") : tr("Nur der Host ändert die Einstellungen.")}
                </div>
            </div>
            <style>{`
        .bsPills{ display: flex; flex-wrap: wrap; gap: 6px; }
        .bsPill{ display: inline-flex; align-items: center; gap: 6px; padding: 7px 13px; border-radius: 999px; font: inherit; font-weight: 800; font-size: 13.5px; color: #fff; cursor: pointer;
          background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.22); transition: background .15s ease, transform .15s ease; }
        .bsPill:hover:not(:disabled){ background: rgba(255,255,255,.16); transform: translateY(-1px); }
        .bsPill.on{ background: #ffd23f; color: #2a1200; border-color: #fff; }
        .bsPill:disabled{ cursor: default; opacity: .8; }
        .bsPill.on:disabled{ opacity: 1; }
      `}</style>
        </div>
    );
}
