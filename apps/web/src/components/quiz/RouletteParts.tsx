"use client";

import { useEffect, useMemo, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { serverNow } from "@/lib/serverClock";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { playFx } from "@/lib/gameFx";
import type { QuizPlayer } from "@/components/quiz/useQuiz";
import { CAT_ICON } from "@/lib/rouletteCats";
import { ITEM } from "@/components/quiz/letterRouletteStyles";
import { LETTERS, REPEATS, SPIN_MS, type CatInfo } from "@/components/quiz/rouletteShared";

/** Fester Farbton je Kategorie (damit jede Karte ihre eigene Farbe hat) */
export function hueOf(name: string): number {
    let h = 0;
    for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) % 360;
    return h;
}

/** Zeit-Ring wie bei der Buzzer-Arena: der Ring läuft leer, in der Mitte steht die Restzeit */
export function TimerRing({ left, ratio, hot, label }: { left: number; ratio: number; hot: boolean; label: string }) {
    const R = 27;
    const C = 2 * Math.PI * R;
    return (
        <div className={`lrRing ${hot ? "hot" : ""}`} role="timer" aria-label={label}>
            <svg viewBox="0 0 64 64" aria-hidden>
                <circle cx="32" cy="32" r={R} className="lrRingBg" />
                <circle cx="32" cy="32" r={R} className="lrRingFg" strokeDasharray={C} strokeDashoffset={C * (1 - Math.max(0, Math.min(1, ratio)))} transform="rotate(-90 32 32)" />
            </svg>
            <span className="lrRingNum">{Math.ceil(left)}</span>
        </div>
    );
}

/**
 * Pulte der Spieler unten (wie in der Buzzer-Arena): Figur auf einem Block, der mit den Punkten wächst. Dazu Zeichen: wer schon
 * gewählt hat (Abstimmung), wer fertig ist bzw. noch tippt (Eingabe) und +Punkte der Kategorie bei der Auflösung.
 */
export function Podia({ players, mePlayerId, state, doneSet, votedSet, gains, gainKey, compact }: { players: QuizPlayer[]; mePlayerId: string | null; state: string | null | undefined; doneSet: Set<string>; votedSet: Set<string>; gains: Map<string, number> | null; gainKey: number; compact: boolean }) {
    const { tr } = useI18n();
    const [view, setView] = useState(() => (typeof window === "undefined" ? { w: 1024, h: 780 } : { w: window.innerWidth, h: window.innerHeight }));
    useEffect(() => {
        const on = () => setView({ w: window.innerWidth, h: window.innerHeight });
        window.addEventListener("resize", on);
        return () => window.removeEventListener("resize", on);
    }, []);
    const phone = view.w < 640;
    const narrow = players.length > 8;
    const H = compact ? (phone ? 40 : Math.max(44, Math.min(90, Math.round(view.h * 0.09)))) : phone ? 60 : Math.max(70, Math.min(150, Math.round(view.h * 0.13)));
    const BASE = phone || narrow ? 50 : 60;
    const scores = players.map((p) => Number(p.song_points ?? 0));
    const top = Math.max(10, ...scores);
    return (
        <section className="lrPodia" style={{ ["--H" as string]: `${H}px`, ["--base" as string]: `${BASE}px` }} aria-label={tr("Punktestand")}>
            {players.map((p) => {
                const score = Number(p.song_points ?? 0);
                const h = BASE + Math.min(1, score / top) * H;
                const done = state === "question" && (p.is_bot || doneSet.has(p.player_id));
                const typing = state === "question" && !done && p.player_id !== mePlayerId;
                const voted = (state === "spin" || state === "vote") && votedSet.has(p.player_id);
                const gain = gains?.get(p.player_id);
                return (
                    <div key={p.player_id} className={`lrPod ${p.player_id === mePlayerId ? "me" : ""} ${done ? "done" : ""}`}>
                        {gain !== undefined && gain > 0 ? (
                            <span className="lrGain" key={`${gainKey}:${p.player_id}`}>
                                +{gain}
                            </span>
                        ) : null}
                        {voted ? <span className="lrBadge vote">🗳️</span> : null}
                        {done ? <span className="lrBadge ok">✓</span> : null}
                        {typing ? <span className="lrBadge type">⌨️</span> : null}
                        <div className="lrFigure">
                            <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={narrow || phone ? 40 : 56} />
                        </div>
                        <div className="lrBlock" style={{ height: `${h}px` }}>
                            <span className="lrName" title={p.name}>
                                {p.name}
                            </span>
                            <span className="lrScore">{score}</span>
                        </div>
                    </div>
                );
            })}
        </section>
    );
}

/**
 * Spielautomat mit Walze (jede Runde NEU, deshalb mit key=quiz_seq aufgerufen): läuft von A durch bis zum gezogenen Buchstaben,
 * tickt mit und blitzt beim Stehenbleiben auf. Wer später dazukommt, sieht gleich den Stand nach der Server-Uhr.
 */
export function SlotReel({ letter, startedAt }: { letter: string; startedAt: string | null }) {
    const [go, setGo] = useState(false);
    const start = startedAt ? Date.parse(startedAt) : null;
    const [now, setNow] = useState(() => serverNow());
    const [t0] = useState(() => (start !== null ? Math.max(0, serverNow() - start) : 0));
    const elapsed = start !== null ? Math.max(0, now - start) : 0;
    useEffect(() => {
        const t = window.setTimeout(() => setGo(true), 60);
        return () => window.clearTimeout(t);
    }, []);
    const target = (REPEATS - 2) * LETTERS.length + Math.max(0, LETTERS.indexOf(letter));
    const strip = useMemo(() => Array.from({ length: REPEATS * LETTERS.length }, (_, i) => LETTERS[i % LETTERS.length]!), []);
    const landed = elapsed > SPIN_MS;
    const transform = go || landed ? `translateX(${-(target + 0.5) * ITEM}px)` : `translateX(${-0.5 * ITEM}px)`;
    const transition = go && !landed ? `transform ${Math.max(300, SPIN_MS - t0)}ms cubic-bezier(.12,.72,.14,1)` : "none";
    useEffect(() => {
        if (t0 > 800) return;
        const timers: number[] = [];
        let t = 0;
        for (let i = 0; i < 18; i++) {
            t += 120 + i * i * 14;
            if (t > SPIN_MS - 300) break;
            timers.push(window.setTimeout(() => playFx("tick"), t));
        }
        timers.push(window.setTimeout(() => playFx("voteWin"), SPIN_MS));
        return () => timers.forEach((x) => window.clearTimeout(x));
    }, [t0]);
    // Takt, damit sich der Zustand "gelandet" nach SPIN_MS ändert
    useEffect(() => {
        const id = window.setInterval(() => setNow(serverNow()), 250);
        return () => window.clearInterval(id);
    }, []);
    return (
        <div className={`lrCab ${landed ? "landed" : ""}`}>
            <div className="lrLamps top" aria-hidden>
                {Array.from({ length: 18 }, (_, k) => (
                    <i key={k} style={{ ["--k" as string]: k }} />
                ))}
            </div>
            <div className="lrReelWrap">
                <div className="lrPointer" aria-hidden>
                    ▼
                </div>
                <div className="lrWin" aria-hidden />
                <div className="lrReel" style={{ transform, transition }}>
                    {strip.map((c, i) => (
                        <span key={i} className={`lrCell ${landed && i === target ? "hit" : ""}`}>
                            {c}
                        </span>
                    ))}
                </div>
                <div className="lrPointerB" aria-hidden>
                    ▲
                </div>
            </div>
            <div className="lrLamps bottom" aria-hidden>
                {Array.from({ length: 18 }, (_, k) => (
                    <i key={k} style={{ ["--k" as string]: 17 - k }} />
                ))}
            </div>
        </div>
    );
}

// Die drei Themen fliegen nacheinander herein (Zeitpunkte in ms nach Rundenstart), damit man sie kennenlernt, bevor man wählt
const INTRO_AT = [1100, 1700, 2300];

/** Drei Kategorien zur Abstimmung: fliegen mit Ton nacheinander herein; erst wenn eine Karte da ist, kann man sie wählen */
export function VoteCards({ cands, tally, myVote, canVote, onVote, votedCount, humans, intro = null }: { cands: CatInfo[]; tally: number[]; myVote: number | null; canVote: boolean; onVote: (c: number) => void; votedCount: number; humans: number; intro?: string | null }) {
    const { tr } = useI18n();
    const [t0] = useState(() => (intro ? Math.max(0, serverNow() - Date.parse(intro)) : 99999));
    const [shown, setShown] = useState(() => INTRO_AT.filter((at) => at <= t0).length);
    useEffect(() => {
        const timers = INTRO_AT.map((at, i) => (at > t0 ? window.setTimeout(() => {
            setShown(i + 1);
            playFx("vote");
        }, at - t0) : 0));
        return () => timers.forEach((x) => x && window.clearTimeout(x));
    }, [t0]);
    return (
        <div className="lrVotes">
            <div className="lrVoteHint">
                {canVote && shown >= 3 ? tr("Stimme für eine Kategorie – die Mehrheit entscheidet (Taste 1, 2 oder 3)") : tr("Die Themen kommen herein …")}
                <b>
                    {votedCount}/{humans}
                </b>
            </div>
            <div className="lrVoteGrid" role="radiogroup" aria-label={tr("Kategorie wählen")}>
                {cands.map((c, i) => {
                    const mineV = myVote === i + 1;
                    const cnt = Number(tally[i] ?? 0);
                    const here = i < shown;
                    return (
                        <button
                            key={c.id}
                            type="button"
                            role="radio"
                            aria-checked={mineV}
                            aria-hidden={!here}
                            tabIndex={here ? 0 : -1}
                            className={`lrVoteCard ${here ? "in" : "pre"} ${mineV ? "on" : ""}`}
                            style={{ ["--h" as string]: hueOf(c.name), ["--n" as string]: i }}
                            disabled={!canVote || !here}
                            onClick={() => onVote(i + 1)}
                        >
                            <span className="lrVoteNo">{i + 1}</span>
                            {mineV ? <span className="lrVoteCheck" aria-hidden>✓</span> : null}
                            <span className="lrVoteIcon" aria-hidden>
                                {CAT_ICON[c.name] ?? "🎯"}
                            </span>
                            <b className="lrVoteName">{c.name}</b>
                            {c.lvl ? (
                                <span className={`lrLvl l${c.lvl}`} title={tr("Etwa {n} bekannte Begriffe mit diesem Buchstaben", { n: c.n ?? 0 })}>
                                    <i aria-hidden>{"●".repeat(c.lvl)}</i>
                                    {c.lvl === 1 ? tr("leicht") : c.lvl === 2 ? tr("mittel") : tr("schwer")}
                                </span>
                            ) : null}
                            <span className="lrVoteDots" aria-label={`${cnt}`}>
                                {Array.from({ length: cnt }, (_, k) => (
                                    <i key={k} />
                                ))}
                                {cnt === 0 ? <em>–</em> : null}
                            </span>
                        </button>
                    );
                })}
            </div>
        </div>
    );
}

