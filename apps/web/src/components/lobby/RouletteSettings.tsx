"use client";

import { useState } from "react";
import { Collapse } from "@/components/ui/Collapse";
import { useI18n } from "@/lib/i18n";
import { LETTERS_CATS, LETTERS_SECS, catIcon, type LettersCfg } from "@/lib/rouletteCats";

/**
 * Roulette-Einstellungen in der Lobby (Migration 130): Anzahl Kategorien, Zeit je Kategorie und welche Kategorien drankommen dürfen.
 * Der Host ändert sie, alle anderen sehen sie. Änderungen gehen sofort an den Server (der prüft, ob genug Kategorien übrig bleiben).
 */
export function RouletteSettings({
    cfg,
    categories,
    canEdit,
    onSave,
    onError,
}: {
    cfg: LettersCfg;
    categories: string[];
    canEdit: boolean;
    onSave: (next: LettersCfg) => Promise<string | null>;
    onError: (msg: string) => void;
}) {
    const { tr } = useI18n();
    const [open, setOpen] = useState(true);
    const [pending, setPending] = useState<LettersCfg | null>(null);
    const cur = pending ?? cfg;
    const active = categories.filter((c) => !cur.off.includes(c));
    const need = cur.cats + 2;

    const change = async (next: LettersCfg) => {
        if (!canEdit) return;
        const left = categories.filter((c) => !next.off.includes(c)).length;
        if (categories.length && left < next.cats + 2) {
            onError(tr("Es müssen mindestens {n} Kategorien erlaubt bleiben.", { n: next.cats + 2 }));
            return;
        }
        setPending(next);
        const err = await onSave(next);
        setPending(null);
        if (err) onError(err);
    };

    return (
        <div className="lobbyPl rsBox">
            <button type="button" className="lobbyPlHead" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
                <span>🎰 {tr("Roulette-Einstellungen")}</span>
                <span className="lobbyPlCount">
                    {tr("{n} Kategorien", { n: cur.cats })} · {cur.secs} s
                </span>
                <span aria-hidden className={`lobbyPlArrow ${open ? "open" : ""}`}>▾</span>
            </button>
            <Collapse open={open}>
                <div className="lobbyPlBody">
                    <div className="rsRow">
                        <b>{tr("Kategorien pro Spiel")}</b>
                        <div className="rsPills" role="radiogroup" aria-label={tr("Kategorien pro Spiel")}>
                            {LETTERS_CATS.map((n) => (
                                <button key={n} type="button" role="radio" aria-checked={cur.cats === n} className={`rsPill ${cur.cats === n ? "on" : ""}`} disabled={!canEdit} onClick={() => void change({ ...cur, cats: n })}>
                                    {n}
                                </button>
                            ))}
                        </div>
                    </div>
                    <div className="rsRow">
                        <b>{tr("Zeit pro Kategorie")}</b>
                        <div className="rsPills" role="radiogroup" aria-label={tr("Zeit pro Kategorie")}>
                            {LETTERS_SECS.map((n) => (
                                <button key={n} type="button" role="radio" aria-checked={cur.secs === n} className={`rsPill ${cur.secs === n ? "on" : ""}`} disabled={!canEdit} onClick={() => void change({ ...cur, secs: n })}>
                                    {n} s
                                </button>
                            ))}
                        </div>
                    </div>
                    <div className="rsRow col">
                        <b>
                            {tr("Erlaubte Kategorien")} <small>{tr("{n} von {total} aktiv", { n: active.length, total: categories.length })}</small>
                        </b>
                        <div className="rsCats">
                            {categories.map((c) => {
                                const on = !cur.off.includes(c);
                                return (
                                    <button
                                        key={c}
                                        type="button"
                                        role="switch"
                                        aria-checked={on}
                                        className={`rsCat ${on ? "on" : ""}`}
                                        disabled={!canEdit}
                                        onClick={() => void change({ ...cur, off: on ? [...cur.off, c] : cur.off.filter((x) => x !== c) })}
                                    >
                                        <span aria-hidden>{catIcon(c)}</span> {c}
                                    </button>
                                );
                            })}
                        </div>
                    </div>
                    <div className="lobbyPlHint">
                        {canEdit ? tr("Antippen = erlauben / rausnehmen · mindestens {n} Kategorien müssen erlaubt bleiben", { n: need }) : tr("Nur der Host ändert die Einstellungen.")}
                    </div>
                </div>
            </Collapse>
            <style>{`
        .rsRow{ display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
        .rsRow.col{ display: grid; justify-content: stretch; }
        .rsRow b{ font-size: 13.5px; font-weight: 900; }
        .rsRow b small{ font-weight: 800; opacity: .65; margin-left: 6px; }
        .rsPills{ display: flex; gap: 6px; flex-wrap: wrap; }
        .rsPill{ min-width: 44px; padding: 7px 13px; border-radius: 999px; font: inherit; font-weight: 900; font-size: 14px; color: #fff; cursor: pointer;
          background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.22); transition: background .15s ease, transform .15s ease; }
        .rsPill:hover:not(:disabled){ background: rgba(255,255,255,.16); transform: translateY(-1px); }
        .rsPill.on{ background: #ffd23f; color: #2a1200; border-color: #fff; }
        .rsPill:disabled{ cursor: default; opacity: .75; }
        .rsPill.on:disabled{ opacity: 1; }
        .rsCats{ display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
        .rsCat{ display: inline-flex; align-items: center; gap: 6px; padding: 6px 11px; border-radius: 999px; font: inherit; font-weight: 800; font-size: 13px; color: #fff; cursor: pointer;
          background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.14); opacity: .5; text-decoration: line-through; transition: opacity .15s ease, background .15s ease; }
        .rsCat.on{ background: rgba(60,200,120,.18); border-color: rgba(100,230,150,.55); opacity: 1; text-decoration: none; }
        .rsCat:disabled{ cursor: default; }
      `}</style>
        </div>
    );
}
