"use client";

import { fmtNum, useI18n } from "@/lib/i18n";
import { useMemo } from "react";
import { PlayerAvatar, type AvatarConfig } from "@/components/game/PlayerAvatar";


export type SummaryPlayer = {
    id: string;
    name: string;
    /** schnellste / langsamste Abgabe dieser Runde in ms (null = nie abgegeben) */
    fastestMs: number | null;
    slowestMs: number | null;
    out?: boolean;
    avatarConfig?: AvatarConfig | null;
};

export type SeriesRow = {
    set_index: number;
    player_id: string;
    name: string;
    place: number;
    arena_points: number;
    song_points: number;
    is_bot?: boolean;
    fastest_ms?: number | null;
    slowest_ms?: number | null;
};

const MEDAL = ["🥇", "🥈", "🥉"];

function fmt(ms: number | null): string {
    if (ms == null || !Number.isFinite(ms)) return "–";
    return `${fmtNum(ms / 1000)} s`;
}

/**
 * Zwischenstand nach einer Runde als EINE Tabelle (Wunsch Mehdi 2026-10-12):
 * Platz gesamt, Spieler, Punkte jeder Runde (Farbe = Platz in der Runde, aktuelle Runde hervorgehoben),
 * Gesamt, schnellste und langsamste Abgabe dieser Runde (beste/schlechteste von allen markiert).
 */
export function SummaryTable({
    players,
    seriesRows,
    currentSet,
    totalSets,
    mePlayerId = null,
}: {
    players: SummaryPlayer[];
    seriesRows: SeriesRow[];
    currentSet: number;
    totalSets: number;
    mePlayerId?: string | null;
}) {
    const { tr } = useI18n();
    const sets = Array.from({ length: Math.max(1, Math.min(currentSet, totalSets)) }, (_, i) => i + 1);

    const rows = useMemo(() => {
        const info = new Map(players.map((p) => [p.id, p]));
        const byPlayer = new Map<string, { id: string; name: string; sets: Map<number, SeriesRow>; total: number; wins: number; placeSum: number; n: number }>();
        for (const r of seriesRows) {
            const e = byPlayer.get(r.player_id) ?? { id: r.player_id, name: r.name, sets: new Map(), total: 0, wins: 0, placeSum: 0, n: 0 };
            e.sets.set(r.set_index, r);
            e.total += r.arena_points;
            if (r.place === 1) e.wins += 1;
            e.placeSum += r.place;
            e.n += 1;
            byPlayer.set(r.player_id, e);
        }
        // Spieler ohne Serien-Eintrag (sollte nicht vorkommen) trotzdem zeigen
        for (const p of players) if (!byPlayer.has(p.id)) byPlayer.set(p.id, { id: p.id, name: p.name, sets: new Map(), total: 0, wins: 0, placeSum: 0, n: 0 });
        // Zeiten dieser Runde: gespeichertes Rundenergebnis (series_results) hat Vorrang vor dem Live-Stand
        const num = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : Number(v));
        return [...byPlayer.values()]
            .map((e) => {
                const live = info.get(e.id) ?? null;
                const saved = e.sets.get(currentSet);
                const fastestMs = saved ? num(saved.fastest_ms) : (live?.fastestMs ?? null);
                const slowestMs = saved ? num(saved.slowest_ms) : (live?.slowestMs ?? null);
                return { ...e, p: { ...(live ?? ({ id: e.id, name: e.name } as SummaryPlayer)), fastestMs, slowestMs } as SummaryPlayer, avgPlace: e.n ? e.placeSum / e.n : 99 };
            })
            .sort((a, b) => b.total - a.total || b.wins - a.wins || a.avgPlace - b.avgPlace);
    }, [players, seriesRows, currentSet]);

    const fast = rows.map((r) => r.p?.fastestMs).filter((v): v is number => v != null);
    const slow = rows.map((r) => r.p?.slowestMs).filter((v): v is number => v != null);
    const best = fast.length ? Math.min(...fast) : null;
    const worst = slow.length ? Math.max(...slow) : null;
    const oneOnly = fast.length === 1 && best === worst;

    return (
        <section className="sumCard" aria-label={tr("Zwischenstand")}>
            <div className="sumScroll">
                <table className="sumTable">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th className="l">{tr("Spieler")}</th>
                            {sets.map((i) => (
                                <th key={i} className={i === currentSet ? "cur" : ""}>
                                    R{i}
                                </th>
                            ))}
                            <th>{tr("Gesamt")}</th>
                            <th title={tr("Schnellste Abgabe in dieser Runde")}>⚡ {tr("Schnellste")}</th>
                            <th title={tr("Langsamste Abgabe in dieser Runde")}>🐢 {tr("Langsamste")}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r, idx) => {
                            const f = r.p?.fastestMs ?? null;
                            const s = r.p?.slowestMs ?? null;
                            return (
                                <tr key={r.id} className={`${r.id === mePlayerId ? "me" : ""} ${idx === 0 ? "first" : ""}`}>
                                    <td className="pl">{MEDAL[idx] ?? idx + 1}</td>
                                    <td className="l">
                                        <span className="sumName">
                                            <PlayerAvatar seed={r.name} config={r.p?.avatarConfig ?? null} mood={r.p?.out ? "out" : "normal"} size={30} className="sumAvatar" />
                                            <span className="sumNameText" title={r.name}>
                                                {r.name}
                                                {r.id === mePlayerId ? <em> ({tr("du")})</em> : null}
                                            </span>
                                        </span>
                                    </td>
                                    {sets.map((i) => {
                                        const x = r.sets.get(i);
                                        return (
                                            <td key={i} className={i === currentSet ? "cur" : ""}>
                                                {x ? (
                                                    <span className={`sumChip p${Math.min(x.place, 4)}`} title={tr("Runde {i}: Platz {p}", { i, p: x.place })}>
                                                        {x.arena_points}
                                                    </span>
                                                ) : (
                                                    "–"
                                                )}
                                            </td>
                                        );
                                    })}
                                    <td className="tot">{r.total}</td>
                                    <td>
                                        <span className={`sumTime ${best != null && f === best ? "best" : ""}`}>{fmt(f)}</span>
                                    </td>
                                    <td>
                                        <span className={`sumTime ${!oneOnly && worst != null && s === worst ? "worst" : ""}`}>{fmt(s)}</span>
                                    </td>
                                </tr>
                            );
                        })}
                    </tbody>
                </table>
            </div>
            <div className="sumHint">
                {tr("Farbe = Platz in der Runde · Rang = Summe aller Runden")} · <span className="b">⚡ {tr("schnellste")}</span> /{" "}
                <span className="w">🐢 {tr("langsamste")}</span> {tr("Abgabe dieser Runde")}
            </div>
            <style>{`
        .sumCard{ border-radius: 22px; padding: 14px; background: rgba(30,8,8,.42); border: 1px solid rgba(255,255,255,.16); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); box-shadow: 0 18px 50px rgba(0,0,0,.28); text-align: left; }
        .sumScroll{ overflow-x: auto; }
        .sumTable{ width: 100%; border-collapse: separate; border-spacing: 0 5px; font-size: 14.5px; }
        .sumTable th{ font-size: 10.5px; font-weight: 800; letter-spacing: .8px; text-transform: uppercase; opacity: .7; padding: 0 8px 2px; text-align: center; white-space: nowrap; }
        .sumTable th.l, .sumTable td.l{ text-align: left; }
        .sumTable th.cur{ color: #ffe08a; opacity: 1; }
        .sumTable td{ padding: 6px 8px; text-align: center; background: rgba(255,255,255,.07); white-space: nowrap; font-weight: 700; }
        .sumTable td:first-child{ border-radius: 12px 0 0 12px; }
        .sumTable td:last-child{ border-radius: 0 12px 12px 0; }
        .sumTable td.cur{ background: rgba(255,224,138,.10); }
        .sumTable tr.first td{ background: rgba(255,214,10,.16); }
        .sumTable tr.me td{ box-shadow: inset 0 2px 0 rgba(34,211,238,.6), inset 0 -2px 0 rgba(34,211,238,.6); }
        .sumTable td.pl{ font-size: 17px; width: 34px; }
        .sumName{ display: flex; align-items: center; gap: 8px; min-width: 0; }
        .sumAvatar{ width: 30px; height: 30px; flex: none; border-radius: 50%; background: rgba(255,255,255,.1); }
        .sumNameText{ font-weight: 800; white-space: normal; overflow-wrap: anywhere; line-height: 1.15; max-width: 200px; }
        .sumNameText em{ font-style: normal; font-weight: 700; opacity: .7; font-size: 12px; }
        .sumTable td.tot{ font-size: 18px; font-weight: 900; color: #ffe08a; }
        .sumChip{ display:inline-block; min-width: 30px; padding: 2px 8px; border-radius: 999px; font-size: 13px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.14); }
        .sumChip.p1{ background: rgba(255,214,10,.22); border-color: rgba(255,214,10,.55); }
        .sumChip.p2{ background: rgba(200,210,225,.18); border-color: rgba(220,230,245,.45); }
        .sumChip.p3{ background: rgba(205,127,50,.22); border-color: rgba(205,127,50,.5); }
        .sumTime{ font-variant-numeric: tabular-nums; border-radius: 999px; padding: 2px 8px; }
        .sumTime.best{ background: rgba(52,211,153,.22); color: #a7f3d0; font-weight: 900; box-shadow: inset 0 0 0 1.5px rgba(52,211,153,.75); }
        .sumTime.worst{ background: rgba(255,90,70,.2); color: #fecaca; font-weight: 900; box-shadow: inset 0 0 0 1.5px rgba(255,90,70,.75); }
        .sumHint{ margin-top: 6px; font-size: 11.5px; font-weight: 700; opacity: .75; text-align: center; }
        .sumHint .b{ color: #a7f3d0; } .sumHint .w{ color: #fecaca; }
        @media (max-width: 560px){
          .sumTable{ font-size: 13px; }
          .sumTable td{ padding: 5px 5px; }
          .sumTable th{ padding: 0 4px 2px; font-size: 9px; letter-spacing: .3px; }
          .sumAvatar{ width: 24px; height: 24px; }
          .sumNameText{ max-width: 110px; }
        }
      `}</style>
        </section>
    );
}
