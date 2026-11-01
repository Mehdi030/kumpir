"use client";

import { useCallback, useEffect, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { serverNow } from "@/lib/serverClock";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { ConfettiBurst } from "@/components/quiz/ConfettiBurst";
import { playDrumRoll, playFanfare, playRankHit } from "@/lib/gameFx";
import type { QuizPlayer } from "@/components/quiz/useQuiz";
import { INTRO_S, PLACE_S, ROLL_S } from "@/components/quiz/rouletteShared";

/**
 * Wertungs-Show: der Bildschirm wird frei (gleicher Hintergrund), Trommelwirbel, dann kommt der Letzte, danach Platz für Platz nach
 * oben – je höher, desto mehr Konfetti und Effekte; Platz 1 mit Fanfare und Konfetti-Feuerwerk. Der Takt kommt von der Server-Uhr,
 * wer später dazukommt, sieht gleich den passenden Platz. "Überspringen" zeigt sofort die fertige Liste (nur bei mir).
 */
export function RankShow({ title, subtitle, rows, startMs, players, mePlayerId, ptsLabel }: { title: string; subtitle: string; rows: { playerId: string; name: string; points: number }[]; startMs: number; players: QuizPlayer[]; mePlayerId: string | null; ptsLabel: string }) {
    const { tr } = useI18n();
    const [skipped, setSkipped] = useState(false);
    const [burst, setBurst] = useState<{ id: number; level: number; winner: boolean } | null>(null);
    const n = rows.length;
    const hitAt = useCallback((i: number) => INTRO_S + PLACE_S * i, []);
    const [, beat] = useState(0);
    useEffect(() => {
        const t = window.setInterval(() => beat((x) => x + 1), 120);
        return () => window.clearInterval(t);
    }, []);

    useEffect(() => {
        if (skipped || n === 0) return;
        const timers: number[] = [];
        const t0 = (serverNow() - startMs) / 1000;
        for (let i = 0; i < n; i++) {
            const level = n > 1 ? i / (n - 1) : 1;
            const win = i === n - 1;
            const at = hitAt(i) - t0;
            if (at > -0.1) {
                timers.push(
                    window.setTimeout(() => {
                        setBurst({ id: i + 1, level, winner: win });
                        playRankHit(level);
                        if (win) {
                            playFanfare();
                            window.setTimeout(() => setBurst({ id: 100 + i, level: 1, winner: true }), 650);
                        }
                    }, Math.max(0, at) * 1000)
                );
            }
            const rollAt = hitAt(i) - ROLL_S - t0;
            if (rollAt > -0.3 && hitAt(i) - t0 > 0.3) {
                const cancelHolder: { c: (() => void) | null } = { c: null };
                timers.push(
                    window.setTimeout(() => {
                        cancelHolder.c = playDrumRoll(Math.min(ROLL_S * 1000, (hitAt(i) - (serverNow() - startMs) / 1000) * 1000));
                    }, Math.max(0, rollAt) * 1000)
                );
            }
        }
        return () => timers.forEach((x) => window.clearTimeout(x));
    }, [skipped, n, startMs, hitAt]);

    const t = (serverNow() - startMs) / 1000;
    const cur = t < hitAt(0) ? -1 : Math.min(n - 1, Math.floor((t - hitAt(0)) / PLACE_S));
    const finished = skipped || t >= hitAt(n - 1) + PLACE_S + 1.5;
    const level = (i: number) => (n > 1 ? i / (n - 1) : 1);
    const row = cur >= 0 ? rows[cur] : null;
    const p = row ? players.find((x) => x.player_id === row.playerId) : null;
    const lv = cur >= 0 ? level(cur) : 0;
    const win = cur === n - 1;

    return (
        <div className={`lrShow ${win ? "win" : ""}`} role="dialog" aria-label={title}>
            {burst && !skipped ? <ConfettiBurst key={burst.id} level={burst.level} winner={burst.winner} /> : null}
            {!finished ? (
                <button type="button" className="btn btnSecondary btnSmall lrSkip" onClick={() => setSkipped(true)}>
                    {tr("Überspringen")} ⏭
                </button>
            ) : null}
            <div className="lrShowHead">
                <small>{subtitle}</small>
                <h2>🥁 {title}</h2>
            </div>

            {finished ? (
                <ol className="lrFinal">
                    {[...rows].reverse().map((r, i) => {
                        const pl = players.find((x) => x.player_id === r.playerId);
                        return (
                            <li key={r.playerId} className={`${i === 0 ? "first" : ""} ${r.playerId === mePlayerId ? "me" : ""}`} style={{ ["--i" as string]: i }}>
                                <span className="lrPlace">{i + 1}</span>
                                {pl ? <PlayerAvatar seed={pl.name} config={pl.avatar_config ?? null} size={i === 0 ? 52 : 40} /> : null}
                                <b>
                                    {r.name}
                                    {i === 0 ? " 👑" : ""}
                                </b>
                                <span className="lrFinalPts">
                                    {r.points} <small>{ptsLabel}</small>
                                </span>
                            </li>
                        );
                    })}
                </ol>
            ) : (
                <>
                    <div className="lrStage">
                        {row ? (
                            <div key={cur} className={`lrBig ${win ? "winner" : ""}`} style={{ ["--lv" as string]: lv }}>
                                <div className="lrBigPlace">
                                    {tr("Platz")} {n - cur}
                                </div>
                                <div className="lrBigAvatar" style={{ width: 90 + 80 * lv, height: 90 + 80 * lv }}>
                                    {p ? <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={80 + 80 * lv} /> : null}
                                    {win ? <span className="lrCrown">👑</span> : null}
                                </div>
                                <div className="lrBigName">{row.name}</div>
                                <div className="lrBigPts">
                                    {row.points} <small>{ptsLabel}</small>
                                </div>
                            </div>
                        ) : (
                            <div className="lrRollTitle">{tr("Gleich wissen wir es …")}</div>
                        )}
                    </div>
                    <ol className="lrSoFar" aria-hidden>
                        {rows
                            .slice(0, Math.max(0, cur))
                            .map((r, i) => (
                                <li key={r.playerId}>
                                    <span>{n - i}.</span> {r.name} <b>{r.points}</b>
                                </li>
                            ))
                            .reverse()}
                    </ol>
                </>
            )}
        </div>
    );
}

