"use client";

import { useI18n } from "@/lib/i18n";

/** Kleines Zusatz-Schild unter der Zündschnur (z. B. Nachspielzeit, Finale). */
export type StageNote = { key: string; text: string; title?: string; tone?: "duel" | "overtime" };

/**
 * Große Leiste oben im Spiel (Wunsch Mehdi 2026-10-14, nochmal aufgeräumt):
 *  - links: welche Runde (groß)
 *  - Mitte: die Zündschnur als vier Pakete – sie brennen nacheinander ab, man sieht nur ungefähr, wie viel Zeit bleibt
 *  - rechts: wie viele Spieler noch im Spiel sind (groß, springt bei jedem Ausscheiden)
 * Wer dran ist, steht am Tisch ("Am Zug"-Schild); Playlist, Zug und Tempo stehen nicht mehr hier.
 */
const PACKS = 4;

export function StageBar({
    holderIsMe,
    heat,
    fuseActive,
    goal,
    round,
    roundTotal,
    alive,
    total,
    notes = [],
}: {
    holderIsMe: boolean;
    /** 0 = Zündschnur voll, 1 = gleich knallt es */
    heat: number;
    fuseActive: boolean;
    /** Ziel des Modus in einem Satz (steht unter der Zündschnur) */
    goal?: string;
    /** Runde des Matches (1…roundTotal) */
    round: number;
    roundTotal: number;
    alive: number;
    total: number;
    notes?: StageNote[];
}) {
    const { tr } = useI18n();
    const h = Math.max(0, Math.min(1, heat));
    const left = fuseActive ? 1 - h : 1;
    // Nur grob: 4 Pakete, jedes steht für ein Viertel der Zeit
    const packs = fuseActive ? Math.max(1, Math.min(PACKS, Math.ceil(left * PACKS - 0.001))) : PACKS;
    const stage = packs <= 1 ? "crit" : packs === 2 ? "hot" : packs === 3 ? "warm" : "calm";

    return (
        <div className={`stageBar ${stage} ${holderIsMe ? "mine" : ""}`} role="group" aria-label={tr("Spielstand")}>
            <div className="sbBig sbRound" title={tr("Runde des Matches")}>
                <span className="sbLabel">{tr("Runde")}</span>
                <span className="sbNum">
                    {round}
                    <small>/{Math.max(1, roundTotal)}</small>
                </span>
            </div>

            <div className="sbFuse">
                <div className="sbPacks" aria-hidden>
                    {Array.from({ length: PACKS }, (_, i) => {
                        const on = i < packs;
                        const burning = fuseActive && on && i === packs - 1;
                        return (
                            <span key={i} className={`sbPack ${on ? "on" : "gone"} ${burning ? "burning" : ""}`}>
                                {burning ? (
                                    <span className="sbSpark">
                                        <i />
                                        <i />
                                        <i />
                                        <i />
                                    </span>
                                ) : null}
                            </span>
                        );
                    })}
                </div>
                <span className="sbFuseFoot">
                    <span className="sbFuseLabel">
                        {!fuseActive ? tr("Zündschnur") : stage === "crit" ? tr("Gleich knallt's!") : stage === "hot" ? tr("Es wird heiß!") : tr("Zündschnur brennt")}
                    </span>
                    {notes.map((n) => (
                        <span key={n.key} className={`sbNote ${n.tone ?? ""}`} title={n.title}>
                            {n.text}
                        </span>
                    ))}
                    {goal ? <span className="sbGoal">🎯 {goal}</span> : null}
                </span>
            </div>

            <div className="sbBig sbAlive" title={tr("{n} von {total} Spielern noch im Spiel", { n: alive, total })}>
                <span className="sbLabel">{tr("Im Spiel")}</span>
                <span className="sbNum" key={alive}>
                    <span aria-hidden className="sbPeople">
                        👥
                    </span>
                    {alive}
                    <small>/{total}</small>
                </span>
            </div>

            <style>{`
        .stageBar{ position: fixed; top: 12px; left: 50%; transform: translateX(-50%); z-index: 55; width: min(900px, calc(100vw - 250px));
          display: grid; grid-template-columns: auto minmax(200px, 1fr) auto; align-items: center; gap: 22px; padding: 7px 22px;
          border-radius: 24px; background: linear-gradient(180deg, rgba(28,24,40,.88), rgba(14,12,24,.88)); border: 1px solid rgba(255,255,255,.14);
          box-shadow: 0 16px 44px rgba(0,0,0,.42), inset 0 1px 0 rgba(255,255,255,.08); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
          transition: border-color .4s ease, box-shadow .4s ease; }
        .stageBar.hot{ border-color: rgba(255,140,60,.55); }
        .stageBar.crit{ border-color: rgba(255,70,50,.85); box-shadow: 0 16px 44px rgba(0,0,0,.42), 0 0 34px rgba(255,60,40,.35); animation: sbShake .35s linear infinite; }
        .stageBar.mine{ background: linear-gradient(180deg, rgba(70,30,14,.9), rgba(36,14,8,.9)); }
        @keyframes sbShake{ 0%,100%{ transform: translateX(-50%); } 25%{ transform: translateX(calc(-50% - 1.5px)); } 75%{ transform: translateX(calc(-50% + 1.5px)); } }

        .sbBig{ display: grid; justify-items: center; gap: 0; line-height: 1; min-width: 96px; }
        .sbLabel{ font-size: 11px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; color: rgba(255,255,255,.6); white-space: nowrap; }
        .sbNum{ font-family: var(--font-display); font-size: clamp(34px, 4vw, 46px); font-weight: 900; line-height: 1.02; white-space: nowrap; color: #fff; text-shadow: 0 3px 14px rgba(0,0,0,.45); }
        .sbNum small{ font-size: .5em; font-weight: 900; opacity: .6; margin-left: 2px; }
        .sbAlive .sbNum{ color: #ffd23f; animation: sbPop .5s cubic-bezier(.2,1.6,.4,1); }
        .sbAlive .sbLabel{ color: #ffe08a; }
        .sbPeople{ font-size: .55em; margin-right: 8px; vertical-align: .12em; }
        @keyframes sbPop{ 0%{ transform: scale(1.5); } 100%{ transform: scale(1); } }

        .sbFuse{ display: grid; gap: 8px; min-width: 0; }
        .sbPacks{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
        .sbPack{ position: relative; height: 20px; border-radius: 8px; transition: background .5s ease, opacity .5s ease, transform .4s ease, box-shadow .4s ease; }
        .sbPack.on{ background: repeating-linear-gradient(-45deg, #c98a3c 0 7px, #a86a28 7px 14px); box-shadow: inset 0 2px 0 rgba(255,255,255,.22), 0 2px 6px rgba(0,0,0,.35); }
        .stageBar.warm .sbPack.on{ background: repeating-linear-gradient(-45deg, #e09a3a 0 7px, #c4761f 7px 14px); }
        .stageBar.hot .sbPack.on{ background: repeating-linear-gradient(-45deg, #f07a2a 0 7px, #d35418 7px 14px); }
        .stageBar.crit .sbPack.on{ background: repeating-linear-gradient(-45deg, #ff4a3a 0 7px, #d02018 7px 14px); }
        .sbPack.gone{ background: rgba(255,255,255,.06); border: 1.5px dashed rgba(255,255,255,.18); opacity: .8; transform: scale(.94); }
        .sbPack.burning{ animation: sbBurn .5s ease-in-out infinite alternate; }
        @keyframes sbBurn{ from{ filter: brightness(1); } to{ filter: brightness(1.35); } }
        .sbSpark{ position: absolute; right: -3px; top: 50%; width: 0; height: 0; }
        .sbSpark::before{ content: ""; position: absolute; left: -12px; top: -12px; width: 24px; height: 24px; border-radius: 50%;
          background: radial-gradient(circle, #fff6c2 0, #ffd23f 35%, rgba(255,120,40,.6) 60%, transparent 72%); animation: sbGlow .3s ease-in-out infinite alternate; }
        .sbSpark i{ position: absolute; left: -2px; top: -2px; width: 4px; height: 4px; border-radius: 50%; background: #ffd23f; animation: sbFly .6s linear infinite; }
        .sbSpark i:nth-child(1){ --x: -12px; --y: -16px; }
        .sbSpark i:nth-child(2){ --x: 10px; --y: -18px; animation-delay: .15s; }
        .sbSpark i:nth-child(3){ --x: -6px; --y: 14px; animation-delay: .3s; background: #ff8a3c; }
        .sbSpark i:nth-child(4){ --x: 14px; --y: 12px; animation-delay: .45s; }
        @keyframes sbFly{ from{ opacity: 1; transform: translate(0,0) scale(1); } to{ opacity: 0; transform: translate(var(--x), var(--y)) scale(.3); } }
        @keyframes sbGlow{ from{ transform: scale(.85); } to{ transform: scale(1.2); } }
        .sbFuseFoot{ display: flex; align-items: baseline; justify-content: center; gap: 4px 12px; flex-wrap: wrap; text-align: center; }
        .sbGoal{ font-size: 11.5px; font-weight: 850; color: #ffe08a; opacity: .95; }
        .sbFuseLabel{ font-size: 11px; font-weight: 900; letter-spacing: 1px; text-transform: uppercase; opacity: .7; }
        .stageBar.hot .sbFuseLabel{ color: #ffb37a; opacity: 1; }
        .stageBar.crit .sbFuseLabel{ color: #ff8a7a; opacity: 1; }
        .sbNote{ font-size: 11px; font-weight: 900; padding: 1px 9px; border-radius: 999px; background: rgba(255,255,255,.12); }
        .sbNote.duel{ background: rgba(150,20,20,.55); color: #ffc2b8; }
        .sbNote.overtime{ background: rgba(180,90,10,.55); color: #ffd9a8; }

        @media (max-width: 760px){
          .stageBar{ top: 60px; width: calc(100vw - 16px); grid-template-columns: 1fr 1fr; gap: 6px 10px; padding: 8px 12px; border-radius: 18px; }
          .sbRound{ grid-column: 1; grid-row: 1; justify-items: start; }
          .sbAlive{ grid-column: 2; grid-row: 1; justify-items: end; }
          .sbFuse{ grid-column: 1 / -1; grid-row: 2; }
          .sbNum{ font-size: 34px; }
          .sbPack{ height: 16px; }
        }
        @media (prefers-reduced-motion: reduce){ .stageBar, .sbPack.burning, .sbAlive .sbNum, .sbSpark::before, .sbSpark i{ animation: none !important; } }
      `}</style>
        </div>
    );
}

/** Herzschlag am Bildschirmrand, wenn es knapp wird – immer schneller, für alle sichtbar (für den Halter stärker). */
export function HeartbeatEdge({ heat, strong }: { heat: number; strong: boolean }) {
    const h = Math.max(0, Math.min(1, heat));
    if (h < 0.66) return null;
    // in Stufen, damit die Animation nicht bei jedem Rendern neu startet
    const lvl = Math.round(((h - 0.66) / 0.34) * 4) / 4;
    const dur = (1.1 - lvl * 0.6).toFixed(2);
    return (
        <div className={`hbEdge ${strong ? "strong" : ""}`} style={{ ["--dur" as string]: `${dur}s`, ["--lvl" as string]: lvl }} aria-hidden>
            <style>{`
        .hbEdge{ position: fixed; inset: 0; z-index: 4; pointer-events: none; animation: hbBeat var(--dur) ease-in-out infinite; }
        @keyframes hbBeat{
          0%, 100%{ box-shadow: inset 0 0 0 0 rgba(255,50,40,0); }
          15%{ box-shadow: inset 0 0 calc(40px + var(--lvl) * 50px) calc(4px + var(--lvl) * 6px) rgba(255,50,40,.38); }
          30%{ box-shadow: inset 0 0 calc(20px + var(--lvl) * 20px) 0 rgba(255,50,40,.12); }
          45%{ box-shadow: inset 0 0 calc(34px + var(--lvl) * 40px) calc(2px + var(--lvl) * 4px) rgba(255,50,40,.3); }
        }
        .hbEdge:not(.strong){ opacity: .55; }
        @media (prefers-reduced-motion: reduce){ .hbEdge{ animation: none; box-shadow: inset 0 0 40px 2px rgba(255,50,40,.25); } }
      `}</style>
        </div>
    );
}
