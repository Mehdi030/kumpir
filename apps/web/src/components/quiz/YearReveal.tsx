"use client";

import { useMemo } from "react";
import { useI18n } from "@/lib/i18n";
import { pts, type RevealResult } from "@/components/quiz/useQuiz";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";

type Tie = { players: string[]; picks: Record<string, number>; winners: string[] };
type P = { player_id: string; name: string; song_points?: number; avatar_config?: unknown };

/** Jahres-Punkte wie auf dem Server (Migration 118): genau 5 · ±1 3 · ±2 2 · ±3 bis ±5 1 · weiter weg 0 */
export const yearPoints = (dist: number) => (dist === 0 ? 5 : dist === 1 ? 3 : dist === 2 ? 2 : dist <= 5 ? 1 : 0);

/**
 * Auswertung beim Jahr raten (Wunsch Mehdi 2026-11-11, vorher „zu verwirrend“):
 * Eine Tabelle mit je einer Zeile pro Spieler: Tipp → Abstand in Jahren → Punkte für das Jahr → (Monats-Entscheid) → Punkte gesamt in dieser Runde → neuer Stand.
 * Darüber steht in einem Satz, wer die meisten Punkte holt und warum; beim Gleichstand erklärt ein Kasten den Monats-Entscheid.
 */
export function YearReveal({
    players,
    results,
    trueYear,
    trueMonth,
    tie,
    mePlayerId,
    monthName,
}: {
    players: P[];
    results: RevealResult[];
    trueYear: number;
    trueMonth: number | null;
    tie: Tie | null;
    mePlayerId: string | null;
    monthName: (m: number, long?: boolean) => string;
}) {
    const { tr } = useI18n();

    const rows = useMemo(() => {
        const all = players.map((p) => {
            const r = results.find((x) => x.playerId === p.player_id);
            const guess = r?.answer != null ? Number(r.answer) : null;
            const dist = guess != null ? Math.abs(guess - trueYear) : null;
            const yearPts = dist != null ? yearPoints(dist) : 0;
            const inTie = !!tie?.players.includes(p.player_id);
            const month = inTie ? tie!.picks[p.player_id] ?? null : null;
            const monthWin = !!tie?.winners.includes(p.player_id);
            const monthPts = monthWin ? 1 : 0;
            const gain = yearPts + monthPts;
            const total = Number(p.song_points ?? 0);
            return { id: p.player_id, name: p.name, avatar: p.avatar_config, guess, dist, yearPts, inTie, month, monthDist: month != null && trueMonth != null ? Math.abs(month - trueMonth) : null, monthWin, monthPts, gain, total, before: total - gain };
        });
        return all.sort((a, b) => b.gain - a.gain || (a.dist ?? 99) - (b.dist ?? 99) || a.name.localeCompare(b.name));
    }, [players, results, trueYear, trueMonth, tie]);

    const top = rows.length ? rows[0].gain : 0;
    const leaders = top > 0 ? rows.filter((r) => r.gain === top) : [];
    const tieRows = rows.filter((r) => r.inTie);
    const tieDist = tieRows.length ? tieRows[0].dist : null;

    return (
        <div className="yrWrap">
            <div className="yrHead">
                {leaders.length === 0
                    ? tr("Diesmal hat keiner Punkte geholt.")
                    : leaders.length === 1
                      ? tr("🏆 {name} holt die meisten Punkte: +{n}", { name: leaders[0].name, n: pts(top) })
                      : tr("🏆 {names} holen gleich viel: je +{n}", { names: leaders.map((l) => l.name).join(" & "), n: pts(top) })}
            </div>

            {tie && tieRows.length > 1 ? (
                <div className="yrTie">
                    <b>⚖️ {tr("Monats-Entscheid")}</b>
                    <span>
                        {tr("{names} lagen beim Jahr gleich weit weg ({d}).", { names: tieRows.map((r) => r.name).join(" & "), d: tieDist === 0 ? tr("genau richtig") : `±${tieDist}` })}{" "}
                        {trueMonth != null ? tr("Der Song erschien im {m} – wer den Monat näher trifft, bekommt +1.", { m: monthName(trueMonth, true) }) : null}
                    </span>
                    <div className="yrMonths">
                        {tieRows.map((r) => (
                            <div key={r.id} className={`yrMonth ${r.monthWin ? "win" : ""}`}>
                                <span className="yrMonthName">{r.name}</span>
                                <span className="yrMonthPick">{r.month != null ? monthName(r.month, true) : "–"}</span>
                                <span className="yrMonthDist">{r.monthDist == null ? "" : r.monthDist === 0 ? tr("🎯 genau richtig") : r.monthDist === 1 ? tr("1 Monat daneben") : tr("{n} Monate daneben", { n: r.monthDist })}</span>
                                <span className="yrMonthRes">{r.monthWin ? "🏅 +1" : "±0"}</span>
                            </div>
                        ))}
                    </div>
                </div>
            ) : null}

            <div className="yrTable" role="table" aria-label={tr("Auswertung")}>
                <div className="yrRow yrTh" role="row">
                    <span>{tr("Spieler")}</span>
                    <span>{tr("Tipp")}</span>
                    <span>{tr("Abstand")}</span>
                    <span>{tr("Punkte")}</span>
                    <span>{tr("Stand")}</span>
                </div>
                {rows.map((r, i) => (
                    <div key={r.id} className={`yrRow ${r.id === mePlayerId ? "me" : ""} ${r.gain === top && top > 0 ? "lead" : ""}`} role="row" style={{ animationDelay: `${i * 70}ms` }}>
                        <span className="yrName">
                            <PlayerAvatar seed={r.name} config={r.avatar as never} size={26} />
                            <b title={r.name}>{r.name}</b>
                            {r.gain === top && top > 0 ? <i title={tr("meiste Punkte")}>🏅</i> : null}
                        </span>
                        <span className="yrGuess">{r.guess ?? "–"}</span>
                        <span className={`yrDist ${r.dist === 0 ? "exact" : ""}`}>{r.dist == null ? tr("kein Tipp") : r.dist === 0 ? tr("🎯 genau") : r.dist === 1 ? tr("1 Jahr daneben") : tr("{n} Jahre daneben", { n: r.dist })}</span>
                        <span className="yrPts">
                            <b>{r.gain > 0 ? `+${pts(r.gain)}` : "±0"}</b>
                            {r.monthPts > 0 ? <small>{tr("{y} Jahr + 1 Monat", { y: r.yearPts })}</small> : r.dist != null ? <small>{tr("Jahr: {y}", { y: r.yearPts })}</small> : null}
                        </span>
                        <span className="yrTotal">
                            <b>{pts(r.total)}</b>
                            {r.gain > 0 ? <small>{pts(r.before)} → {pts(r.total)}</small> : null}
                        </span>
                    </div>
                ))}
            </div>

            <div className="yrRule">{tr("Punkte fürs Jahr: genau 5 · ±1 Jahr 3 · ±2 Jahre 2 · bis ±5 Jahre 1. Bei Gleichstand entscheidet der Monat (+1).")}</div>
            <style>{`
        .yrWrap{ display: grid; gap: 8px; width: min(620px, 100%); margin: 6px auto 0; text-align: left; }
        .yrHead{ text-align: center; padding: 8px 16px; border-radius: 999px; background: rgba(255,214,10,.18); border: 1px solid rgba(255,224,138,.6); font-weight: 900; font-size: 15px; justify-self: center; max-width: 100%; }
        .yrTie{ display: grid; gap: 6px; padding: 10px 12px; border-radius: 16px; background: rgba(130,100,255,.16); border: 1px solid rgba(180,160,255,.55); font-size: 13px; font-weight: 700; }
        .yrTie b{ font-size: 12px; letter-spacing: .8px; text-transform: uppercase; }
        .yrMonths{ display: grid; gap: 5px; }
        .yrMonth{ display: grid; grid-template-columns: minmax(70px, 1fr) auto auto auto; gap: 10px; align-items: center; padding: 6px 10px; border-radius: 12px; background: rgba(255,255,255,.08); }
        .yrMonth.win{ background: rgba(255,214,10,.2); border: 1px solid rgba(255,224,138,.6); }
        .yrMonthName{ font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .yrMonthPick{ font-weight: 800; }
        .yrMonthDist{ opacity: .9; font-size: 12.5px; }
        .yrMonthRes{ font-weight: 950; color: #ffe08a; min-width: 48px; text-align: right; }
        .yrTable{ display: grid; gap: 5px; }
        .yrRow{ display: grid; grid-template-columns: minmax(96px, 1.5fr) 52px minmax(70px, 1fr) minmax(70px, .9fr) minmax(64px, .8fr); gap: 8px; align-items: center; padding: 7px 10px; border-radius: 14px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.1); animation: yrIn .45s cubic-bezier(.16,1,.3,1) both; }
        .yrRow.yrTh{ background: none; border: 0; padding-top: 0; padding-bottom: 0; font-size: 10.5px; font-weight: 800; letter-spacing: .8px; text-transform: uppercase; opacity: .85; animation: none; }
        .yrRow.me{ border-color: rgba(34,211,238,.7); background: rgba(34,211,238,.12); }
        .yrRow.lead{ background: rgba(255,214,10,.16); border-color: rgba(255,224,138,.65); }
        @keyframes yrIn{ from{ opacity: 0; transform: translateY(8px); } }
        .yrName{ display: flex; align-items: center; gap: 7px; min-width: 0; }
        .yrName b{ overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
        .yrName i{ font-style: normal; }
        .yrGuess{ font-weight: 900; font-size: 16px; font-variant-numeric: tabular-nums; }
        .yrDist{ font-size: 12.5px; font-weight: 800; opacity: .95; }
        .yrDist.exact{ color: #8dffb8; }
        .yrPts, .yrTotal{ display: grid; line-height: 1.15; }
        .yrPts b{ font-size: 17px; font-weight: 950; color: #ffe08a; }
        .yrTotal b{ font-size: 15px; font-weight: 900; }
        .yrPts small, .yrTotal small{ font-size: 10.5px; font-weight: 700; opacity: .85; }
        .yrRule{ text-align: center; font-size: 11.5px; font-weight: 700; opacity: .8; }
        @media (max-width: 560px){
          .yrRow{ grid-template-columns: minmax(80px, 1.3fr) 44px minmax(56px, 1fr) minmax(54px, .8fr) minmax(48px, .7fr); gap: 5px; padding: 6px 7px; }
          .yrDist{ font-size: 11px; } .yrName b{ font-size: 12.5px; }
          .yrMonth{ grid-template-columns: 1fr auto auto; } .yrMonthDist{ grid-column: 1 / -1; }
        }
        @media (prefers-reduced-motion: reduce){ .yrRow{ animation: none; } }
      `}</style>
        </div>
    );
}
