"use client";

import { fmtNum, useI18n } from "@/lib/i18n";
import { PlayerAvatar, type AvatarConfig } from "@/components/game/PlayerAvatar";

export type PassStatsRow = {
    id: string;
    name: string;
    place: number;
    points: number;
    /** schnellste / langsamste Abgabe in ms (null = nie abgegeben) */
    fastestMs: number | null;
    slowestMs: number | null;
    isMe?: boolean;
    out?: boolean;
    avatarConfig?: AvatarConfig | null;
    /** Song-Treffer im Match (Migration 109): Titel + Künstler / nur Titel */
    both?: number;
    titlesOnly?: number;
};

const MEDAL = ["🥇", "🥈", "🥉"];

function fmt(ms: number | null): string {
    if (ms == null || !Number.isFinite(ms)) return "–";
    return `${fmtNum(ms / 1000)} s`;
}

/**
 * Ergebnis-Tabelle nach jeder Runde und am Ende (Wunsch Mehdi 2026-10-12):
 * Platz, Spieler, Punkte, schnellste und langsamste Abgabe. Die schnellste Abgabe ALLER Spieler ist grün
 * markiert (⚡), die langsamste rot (🐢) – so sieht man auf einen Blick, wer wie schnell weitergegeben hat.
 */
export function PassStatsTable({ rows, title, pointsLabel }: { rows: PassStatsRow[]; title?: string; pointsLabel?: string }) {
    const { tr } = useI18n();
    const sorted = [...rows].sort((a, b) => a.place - b.place);
    const withFast = sorted.filter((r) => r.fastestMs != null);
    const withSlow = sorted.filter((r) => r.slowestMs != null);
    const best = withFast.length ? Math.min(...withFast.map((r) => r.fastestMs!)) : null;
    const worst = withSlow.length ? Math.max(...withSlow.map((r) => r.slowestMs!)) : null;
    // Nur eine einzige Abgabe insgesamt -> nicht gleichzeitig "schnellste" und "langsamste" markieren
    const oneOnly = withFast.length === 1 && best === worst;
    const songs = rows.some((r) => r.both != null || r.titlesOnly != null);
    const maxBoth = Math.max(0, ...rows.map((r) => r.both ?? 0));

    return (
        <section className="pstCard" aria-label={title ?? tr("Ergebnis")}>
            {title ? <h2 className="pstTitle">{title}</h2> : null}
            <div className={`pstTable ${songs ? "songs" : ""}`} role="table">
                <div className="pstRow pstHead" role="row">
                    <span>#</span>
                    <span>{tr("Spieler")}</span>
                    <span className="r">{pointsLabel ?? tr("Punkte")}</span>
                    {songs ? (
                        <>
                            <span className="r" title={tr("Titel + Künstler erkannt")}>
                                🎯
                            </span>
                            <span className="r" title={tr("Nur Titel erkannt")}>
                                🎵
                            </span>
                        </>
                    ) : null}
                    <span className="r" title={tr("Schnellste Abgabe")}>⚡ {tr("Schnellste")}</span>
                    <span className="r" title={tr("Langsamste Abgabe")}>🐢 {tr("Langsamste")}</span>
                </div>
                {sorted.map((r) => {
                    const isBest = best != null && r.fastestMs === best;
                    const isWorst = !oneOnly && worst != null && r.slowestMs === worst;
                    return (
                        <div key={r.id} className={`pstRow ${r.isMe ? "me" : ""} ${r.place === 1 ? "first" : ""}`} role="row">
                            <span className="pstPlace">{MEDAL[r.place - 1] ?? r.place}</span>
                            <span className="pstName">
                                <PlayerAvatar seed={r.name} config={r.avatarConfig} mood={r.out ? "out" : "normal"} size={30} className="pstAvatar" />
                                <span className="pstNameText" title={r.name}>
                                    {r.name}
                                    {r.isMe ? <em> ({tr("du")})</em> : null}
                                </span>
                            </span>
                            <span className="r pstPts">{r.points}</span>
                            {songs ? (
                                <>
                                    <span className={`r pstSong ${maxBoth > 0 && r.both === maxBoth ? "top" : ""}`}>{r.both ?? 0}</span>
                                    <span className="r pstSong">{r.titlesOnly ?? 0}</span>
                                </>
                            ) : null}
                            <span className={`r pstTime ${isBest ? "best" : ""}`}>{fmt(r.fastestMs)}</span>
                            <span className={`r pstTime ${isWorst ? "worst" : ""}`}>{fmt(r.slowestMs)}</span>
                        </div>
                    );
                })}
            </div>
            <div className="pstLegend">
                <span className="best">⚡ {tr("schnellste Abgabe von allen")}</span>
                <span className="worst">🐢 {tr("langsamste Abgabe von allen")}</span>
                {songs ? <span>🎯 {tr("Titel + Künstler")} · 🎵 {tr("nur Titel")}</span> : null}
            </div>
            <style>{`
        .pstCard{ border-radius: 22px; padding: 14px; background: rgba(30,8,8,.42); border: 1px solid rgba(255,255,255,.16); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); box-shadow: 0 18px 50px rgba(0,0,0,.28); text-align: left; }
        .pstTitle{ margin: 0 0 8px; font-size: 16px; font-weight: 800; }
        .pstTable{ display: grid; gap: 5px; }
        .pstRow{ display: grid; grid-template-columns: 30px minmax(0,1fr) 62px 86px 92px; gap: 8px; align-items: center; padding: 6px 10px; border-radius: 12px; background: rgba(255,255,255,.07); font-weight: 600; font-size: 14.5px; }
        .pstTable.songs .pstRow{ grid-template-columns: 30px minmax(0,1fr) 62px 36px 36px 86px 92px; }
        .pstSong{ font-weight: 800; font-variant-numeric: tabular-nums; opacity: .9; }
        .pstSong.top{ color: #ffe08a; opacity: 1; }
        .pstHead{ background: none; padding-top: 0; padding-bottom: 0; font-size: 10.5px; font-weight: 800; letter-spacing: .8px; text-transform: uppercase; opacity: .65; }
        .pstRow.first{ background: rgba(255,214,10,.14); border: 1px solid rgba(255,214,10,.38); }
        .pstRow.me{ box-shadow: inset 0 0 0 2px rgba(34,211,238,.6); }
        .pstRow .r{ text-align: right; }
        .pstPlace{ font-size: 17px; text-align: center; }
        .pstName{ display: flex; align-items: center; gap: 8px; min-width: 0; }
        .pstAvatar{ width: 30px; height: 30px; flex: none; border-radius: 50%; background: rgba(255,255,255,.1); }
        .pstNameText{ font-weight: 800; line-height: 1.15; overflow-wrap: anywhere; }
        .pstNameText em{ font-style: normal; font-weight: 700; opacity: .7; font-size: 12px; }
        .pstPts{ font-weight: 800; color: #ffe08a; }
        .pstTime{ font-variant-numeric: tabular-nums; border-radius: 999px; padding: 2px 8px; justify-self: end; }
        .pstTime.best{ background: rgba(52,211,153,.22); color: #a7f3d0; font-weight: 900; box-shadow: inset 0 0 0 1.5px rgba(52,211,153,.75); }
        .pstTime.best::before{ content: "⚡ "; }
        .pstTime.worst{ background: rgba(255,90,70,.2); color: #fecaca; font-weight: 900; box-shadow: inset 0 0 0 1.5px rgba(255,90,70,.75); }
        .pstTime.worst::before{ content: "🐢 "; }
        .pstLegend{ display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; margin-top: 8px; font-size: 11.5px; font-weight: 700; opacity: .8; }
        .pstLegend .best{ color: #a7f3d0; }
        .pstLegend .worst{ color: #fecaca; }
        @media (max-width: 560px){
          .pstRow{ grid-template-columns: 24px minmax(0,1fr) 44px 64px 70px; gap: 5px; padding: 5px 7px; font-size: 13px; }
          .pstTable.songs .pstRow{ grid-template-columns: 22px minmax(0,1fr) 40px 26px 26px 58px 62px; gap: 4px; }
          .pstHead{ font-size: 9px; letter-spacing: .3px; }
          .pstAvatar{ width: 24px; height: 24px; }
          .pstTime{ padding: 1px 5px; }
          .pstTime.best::before, .pstTime.worst::before{ content: ""; }
        }
      `}</style>
        </section>
    );
}
