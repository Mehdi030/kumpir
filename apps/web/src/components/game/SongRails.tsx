"use client";

import { useI18n } from "@/lib/i18n";

const MAX_WIDE = 9;
const MAX_NARROW = 2;

/**
 * Songs dieser Runde (Wunsch Mehdi 2026-10-14): links in Rot die NICHT erratenen (Kumpir explodiert, Song getauscht),
 * rechts gesammelt die erratenen. Neueste oben. Breiter Bildschirm: zwei Spalten links und rechts neben dem Tisch.
 * Schmal (Handy/kleines Fenster): zwei kleine Spalten unter der Antwort-Karte, nur die letzten drei.
 */
export function SongRails({ missed, guessed }: { missed: string[]; guessed: string[] }) {
    const { tr } = useI18n();
    return (
        <div className={`songRails ${missed.length + guessed.length === 0 ? "allEmpty" : ""}`} aria-label={tr("Songs dieser Runde")}>
            <Rail kind="missed" title={`❌ ${tr("Nicht erraten")}`} songs={missed} empty={tr("Noch keiner")} more={(n) => tr("+{n} weitere", { n })} />
            <Rail kind="guessed" title={`✅ ${tr("Erraten")}`} songs={guessed} empty={tr("Noch keiner")} more={(n) => tr("+{n} weitere", { n })} />
            <style>{`
        .songRails{ width: min(920px, 100%); display: grid; grid-template-columns: 1fr 1fr; gap: 10px; text-align: left; pointer-events: none; margin-top: 4px; }
        .srRail{ min-width: 0; display: grid; align-content: start; gap: 6px; }
        .srHead{ display: flex; align-items: baseline; justify-content: space-between; gap: 8px; padding: 0 4px; font-size: 12px; font-weight: 900; letter-spacing: .6px; text-transform: uppercase; }
        .srHead b{ font-family: var(--font-display); font-size: 20px; line-height: 1; }
        .srRail.missed .srHead{ color: #ff9d94; }
        .srRail.guessed .srHead{ color: #8be8b0; justify-content: space-between; }
        .srList{ display: grid; gap: 6px; }
        .srChip{ font-size: 13px; font-weight: 800; line-height: 1.2; padding: 7px 11px; border-radius: 12px; border: 1px solid; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; word-break: break-word;
          backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); animation: srIn .45s cubic-bezier(.16,1,.3,1); }
        .srRail.missed .srChip{ background: rgba(120,18,14,.5); border-color: rgba(255,92,80,.6); color: #ffd6d1; }
        .srRail.missed .srChip.newest{ background: rgba(170,26,20,.62); border-color: #ff6a5c; color: #fff; box-shadow: 0 0 16px rgba(255,70,60,.3); }
        .srRail.guessed .srChip{ background: rgba(14,86,52,.5); border-color: rgba(80,220,140,.5); color: #d4f8e2; }
        .srRail.guessed .srChip.newest{ background: rgba(20,120,70,.6); border-color: #5fe39a; color: #fff; box-shadow: 0 0 16px rgba(70,230,140,.28); }
        .srChip.more{ background: rgba(255,255,255,.08) !important; border-color: rgba(255,255,255,.16) !important; color: rgba(255,255,255,.7) !important; box-shadow: none !important; text-align: center; }
        .srEmpty{ font-size: 12.5px; font-weight: 700; opacity: .45; padding: 4px 6px; }
        @keyframes srIn{ from{ opacity: 0; transform: translateY(-8px) scale(.96); } }

        /* breit: je eine Spalte links und rechts neben dem Tisch */
        @media (min-width: 1000px) and (min-height: 620px){
          .songRails{ position: fixed; left: 0; right: 0; top: 132px; bottom: 14px; width: auto; margin: 0; z-index: 2; display: block; }
          .srRail{ position: absolute; top: 0; bottom: 0; width: clamp(150px, calc((100vw - 660px) / 2 - 24px), 300px); overflow: hidden; }
          .srRail.missed{ left: 18px; }
          .srRail.guessed{ right: 18px; }
          .srChip{ font-size: 14px; }
        }
        @media (max-width: 999px), (max-height: 619px){
          .songRails.allEmpty{ display: none; }
          .srList > :nth-child(n+${MAX_NARROW + 1}){ display: none; }
          .srChip{ font-size: 12.5px; padding: 5px 9px; }
        }
        @media (prefers-reduced-motion: reduce){ .srChip{ animation: none; } }
      `}</style>
        </div>
    );
}

function Rail({ kind, title, songs, empty, more }: { kind: "missed" | "guessed"; title: string; songs: string[]; empty: string; more: (n: number) => string }) {
    // neueste zuerst; die Liste wächst nur nach hinten, daher bleibt der Index von hinten gezählt als stabiler Schlüssel
    const shown = songs.slice(-MAX_WIDE).reverse();
    const hidden = songs.length - shown.length;
    return (
        <section className={`srRail ${kind}`}>
            <div className="srHead">
                <span>{title}</span>
                <b>{songs.length}</b>
            </div>
            <div className="srList">
                {shown.length === 0 ? <span className="srEmpty">{empty}</span> : null}
                {shown.map((a, i) => (
                    <span key={`${songs.length - 1 - i}:${a}`} className={`srChip ${i === 0 ? "newest" : ""}`}>
                        {a}
                    </span>
                ))}
                {hidden > 0 ? <span className="srChip more">{more(hidden)}</span> : null}
            </div>
        </section>
    );
}
