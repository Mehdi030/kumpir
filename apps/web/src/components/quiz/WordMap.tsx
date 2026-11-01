"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import type { QuizPlayer } from "@/components/quiz/useQuiz";
import { BASE_ROWS, MAP_COL_W, type Appeal, type Word } from "@/components/quiz/rouletteShared";

/** kleiner Zufallsgenerator (stabil für denselben Startwert) */
function rng(seed: number) {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

/** Platz des k-ten Wortes auf der Karte: quer verteilt (zuerst die 35 Felder in zufälliger Reihenfolge, danach weitere Zeilen) */
function slotOf(k: number, seed: number, cols: number): { x: number; y: number } {
    const B = cols * BASE_ROWS;
    let row: number;
    let col: number;
    if (k < B) {
        // gleichmäßig verteilt: jedes neue Wort kommt in das freie Feld, das am weitesten von den bisherigen entfernt ist (aus 6 Zufallskandidaten)
        const r = rng(seed);
        const free = Array.from({ length: B }, (_, i) => i);
        const perm: number[] = [];
        while (free.length) {
            let best = -1;
            let bestD = -1;
            for (let c = 0; c < Math.min(6, free.length); c++) {
                const cand = free[Math.floor(r() * free.length)]!;
                const cx = cand % cols;
                const cy = Math.floor(cand / cols);
                let d = 99;
                for (const o of perm) d = Math.min(d, Math.hypot((o % cols) - cx, (Math.floor(o / cols) - cy) * 0.8));
                if (d > bestD) {
                    bestD = d;
                    best = cand;
                }
            }
            perm.push(best);
            free.splice(free.indexOf(best), 1);
        }
        const cell = perm[k]!;
        row = Math.floor(cell / cols);
        col = cell % cols;
    } else {
        const extra = k - B;
        row = BASE_ROWS + Math.floor(extra / cols);
        const order = Array.from({ length: cols }, (_, i) => i);
        const r = rng(seed + row * 131);
        for (let i = order.length - 1; i > 0; i--) {
            const j = Math.floor(r() * (i + 1));
            [order[i], order[j]] = [order[j]!, order[i]!];
        }
        col = order[extra % cols]!;
    }
    const j = rng(seed * 7 + k * 977);
    return { x: 10 + ((col + 0.5) / cols) * 80 + (j() - 0.5) * 5, y: row + 0.5 + (j() - 0.5) * 0.26 };
}

/** Wörter-Karte: jedes Wort steht fest an seinem Platz im Raum; bei der Auflösung färben sie sich (richtig: grün + größer, falsch: rot + kleiner) */
export function WordMap({
    words,
    seed,
    colored,
    crowded,
    players,
    label,
    tag,
    showAuthors = false,
    appeals = [],
    appealOpen = false,
    mePlayerId = null,
    onAppeal,
    onAppealVote,
}: {
    words: Word[];
    seed: number;
    colored: boolean;
    crowded: boolean;
    players: QuizPlayer[];
    label: string;
    tag?: string;
    showAuthors?: boolean;
    appeals?: Appeal[];
    appealOpen?: boolean;
    mePlayerId?: string | null;
    onAppeal?: (text: string) => void;
    onAppealVote?: (owner: string, text: string, yes: boolean) => void;
}) {
    const { tr } = useI18n();
    const appealOf = useMemo(() => new Map(appeals.map((a) => [`${a.o}|${a.t.toLowerCase()}`, a])), [appeals]);
    // Spaltenzahl nach der Breite der Karte (breit = mehr Spalten, Handy = 2), Zeilen wachsen mit der Wortzahl
    const boxRef = useRef<HTMLDivElement | null>(null);
    const [boxW, setBoxW] = useState(() => (typeof window === "undefined" ? 900 : Math.min(980, window.innerWidth - 28)));
    useEffect(() => {
        const el = boxRef.current;
        if (!el || typeof ResizeObserver === "undefined") return;
        const ro = new ResizeObserver((entries) => setBoxW(Math.round(entries[0]?.contentRect.width ?? 0) || 900));
        ro.observe(el);
        return () => ro.disconnect();
    }, []);
    const cols = Math.max(2, Math.min(5, Math.floor(boxW / MAP_COL_W)));
    const rows = Math.max(BASE_ROWS, Math.ceil(words.length / cols) + 1);
    const pos = useMemo(() => words.map((_, k) => slotOf(k, seed, cols)), [words, seed, cols]);
    const byId = useMemo(() => new Map(players.map((p) => [p.player_id, p])), [players]);
    return (
        <div ref={boxRef} className="lrMap" style={{ height: `calc(var(--rh) * ${rows})` }} role="group" aria-label={label}>
            {tag ? <span className="lrBoardTag">{tag}</span> : null}
            {words.length === 0 ? <div className="lrMapEmpty">{label}</div> : null}
            {words.map((w, i) => {
                const p = byId.get(w.pid);
                const ap = w.kind === "bad" ? appealOf.get(w.key) : undefined;
                const pending = !!ap && ap.s === "open" && appealOpen;
                const appealable = showAuthors && colored && appealOpen && w.kind === "bad" && w.mine && !ap && !!onAppeal;
                const iVotedYes = !!mePlayerId && !!ap?.y.includes(mePlayerId);
                const iVotedNo = !!mePlayerId && !!ap?.n.includes(mePlayerId);
                const canVote = pending && !w.mine && !!mePlayerId && !!onAppealVote;
                return (
                    <span
                        key={`${w.key}:${w.kind}`}
                        className={`lrW ${w.kind} ${w.mine ? "mine" : ""} ${colored ? "go" : ""} ${crowded ? "tiny" : ""} ${appealable ? "appealable" : ""} ${pending ? "pending" : ""}`}
                        style={{ left: `${pos[i]!.x}%`, top: `calc(var(--rh) * ${pos[i]!.y})`, ["--i" as string]: i % 24 }}
                        title={appealable ? tr("Einspruch einlegen") : p?.name}
                        role={appealable ? "button" : undefined}
                        tabIndex={appealable ? 0 : undefined}
                        onClick={appealable ? () => onAppeal?.(w.text) : undefined}
                        onKeyDown={
                            appealable
                                ? (e) => {
                                      if (e.key === "Enter" || e.key === " ") {
                                          e.preventDefault();
                                          onAppeal?.(w.text);
                                      }
                                  }
                                : undefined
                        }
                    >
                        {showAuthors && p ? <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={crowded ? 16 : 20} /> : null}
                        <span>{w.text}</span>
                        {showAuthors && colored && w.kind === "ok" ? <em aria-hidden>✓</em> : null}
                        {showAuthors && colored && w.kind === "bad" && !pending ? <em aria-hidden>{appealable ? "⚖️" : ap?.s === "rejected" ? "✗ ⚖️" : "✗"}</em> : null}
                        {pending ? (
                            <span className="lrVotesBox">
                                <em aria-hidden>⚖️</em>
                                {canVote ? (
                                    <>
                                        <button type="button" className={`lrThumb ${iVotedYes ? "on" : ""}`} onClick={() => onAppealVote?.(w.pid, w.text, true)} aria-label={tr("Gilt")}>
                                            👍 {ap!.y.length}
                                        </button>
                                        <button type="button" className={`lrThumb ${iVotedNo ? "on" : ""}`} onClick={() => onAppealVote?.(w.pid, w.text, false)} aria-label={tr("Gilt nicht")}>
                                            👎 {ap!.n.length}
                                        </button>
                                    </>
                                ) : (
                                    <small>
                                        👍 {ap!.y.length} 👎 {ap!.n.length}
                                    </small>
                                )}
                            </span>
                        ) : null}
                    </span>
                );
            })}
        </div>
    );
}

