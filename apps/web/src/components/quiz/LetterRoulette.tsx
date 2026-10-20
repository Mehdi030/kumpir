"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { gameModeInfo } from "@/lib/gameModes";
import { serverNow } from "@/lib/serverClock";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { AudioControl } from "@/components/AudioControl";
import { ConfettiBurst } from "@/components/quiz/ConfettiBurst";
import { playDrumRoll, playFanfare, playFx, playRankHit } from "@/lib/gameFx";
import { useQuiz, type QuizLobby, type QuizPlayer } from "@/components/quiz/useQuiz";
import { CAT_ICON } from "@/lib/rouletteCats";
import { ITEM, STYLES } from "@/components/quiz/letterRouletteStyles";

const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
const REPEATS = 7; // Walze = 7x A–Z, der Zielbuchstabe liegt in der vorletzten Wiederholung
const SPIN_MS = 5600;

// Wörter-Karte: feste Spalten, y in Zeilen (so bleibt jedes Wort an seinem Platz, auch wenn weitere dazukommen)
const MAP_COL_W = 235; // so breit darf eine Spalte der Wörter-Karte mindestens sein (px) – daraus folgt die Spaltenzahl
const BASE_ROWS = 7; // Zeilenhöhe steht im CSS (--rh), damit sie auf dem Handy kleiner sein kann

// Wertungs-Show: Wörter-Karte 7 s (13 s, wenn Menschen rote Wörter haben – Zeit für Einsprüche; steht in quiz_reveal.mapSecs), dann je Platz 2,2 s (Trommelwirbel 0,9 s + Treffer), Sieger +1,5 s – muss zur Datenbank passen (Migration 128)
const MAP_S_DEFAULT = 7;
const INTRO_S = 1;
const PLACE_S = 2.2;
const ROLL_S = 0.9;
const showSeconds = (n: number) => INTRO_S + PLACE_S * n + 1.5;

type CatInfo = { id: string; name: string };
type ValidItem = { t: string; l: string };
type ResultRow = { playerId: string; name: string; points: number; valid: ValidItem[]; bad: string[]; dup: string[] };
type Word = { key: string; text: string; pid: string; kind: "plain" | "ok" | "bad" | "dup"; mine: boolean };
type Appeal = { o: string; t: string; y: string[]; n: string[]; s: "open" | "accepted" | "rejected" };

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

/**
 * ROULETTE – Buchstabe + drei Kategorien (Migration 127/128).
 * Ablauf: Die Walze läuft von A bis Z und bleibt bei einem Buchstaben stehen; währenddessen stimmen alle über eine von drei
 * Kategorien ab (Mehrheit). Pro Kategorie 45 s: Begriffe tippen, sie schweben als Wörter-Karte im Raum (jeder sieht nur die
 * eigenen). Auflösung: alle Wörter aller Spieler – richtige grün und größer, falsche rot und kleiner – dann die Wertungs-Show
 * von unten nach oben mit Trommelwirbel, Konfetti und Melodie. Nach jeder Kategorie wieder eine Abstimmung mit drei neuen.
 */
export function LetterRoulette({ lobby, players, mePlayerId, onToast }: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (m: string, ms?: number) => void }) {
    const { tr } = useI18n();
    const q = useQuiz({ lobby, mePlayerId, onToast });
    const info = gameModeInfo("letters");
    const state = lobby.quiz_state;
    const opts = lobby.quiz_options ?? {};
    const letter = String(opts.letter ?? "A").toUpperCase();
    const cands = useMemo(() => ((opts.cands as CatInfo[] | undefined) ?? []).slice(0, 3), [opts.cands]);
    const tally = useMemo(() => ((opts.tally as number[] | undefined) ?? [0, 0, 0]).slice(0, 3), [opts.tally]);
    const cat = (opts.cat as CatInfo | undefined) ?? null;
    const idx = Math.max(0, lobby.quiz_index);
    const total = Math.max(1, lobby.quiz_total || 3); // Anzahl Kategorien (Host-Einstellung)
    const me = players.find((p) => p.player_id === mePlayerId) ?? null;
    const reveal = lobby.quiz_reveal as { letter?: string; category?: string; index?: number; last?: boolean; mapSecs?: number; results?: ResultRow[] } | null;
    const MAP_S = Number(reveal?.mapSecs ?? MAP_S_DEFAULT);
    const rows = useMemo(() => reveal?.results ?? [], [reveal]);
    const humans = players.filter((p) => !p.is_bot).length;

    // Takt (für Show und Stufen), 250 ms
    const [, setBeat] = useState(0);
    useEffect(() => {
        const t = window.setInterval(() => setBeat((n) => n + 1), 250);
        return () => window.clearInterval(t);
    }, []);

    // ---------------- Walze ----------------
    const elapsed = lobby.quiz_started_at ? Math.max(0, serverNow() - Date.parse(lobby.quiz_started_at)) : 0;
    const [go, setGo] = useState(false);
    useEffect(() => {
        if (state !== "spin") return;
        const t = window.setTimeout(() => setGo(true), 60);
        return () => window.clearTimeout(t);
    }, [state, lobby.quiz_seq]);
    const target = (REPEATS - 2) * LETTERS.length + Math.max(0, LETTERS.indexOf(letter));
    const strip = useMemo(() => Array.from({ length: REPEATS * LETTERS.length }, (_, i) => LETTERS[i % LETTERS.length]!), []);
    const landed = state === "spin" && elapsed > SPIN_MS;
    const reelTransform = go || landed ? `translateX(${-(target + 0.5) * ITEM}px)` : `translateX(${-0.5 * ITEM}px)`;
    const reelTransition = go && !landed ? `transform ${Math.max(300, SPIN_MS - elapsed)}ms cubic-bezier(.12,.72,.14,1)` : "none";
    useEffect(() => {
        if (state !== "spin" || elapsed > 800) return;
        const timers: number[] = [];
        let t = 0;
        for (let i = 0; i < 18; i++) {
            t += 120 + i * i * 14;
            if (t > SPIN_MS - 300) break;
            timers.push(window.setTimeout(() => playFx("tick"), t));
        }
        timers.push(window.setTimeout(() => playFx("voteWin"), SPIN_MS));
        return () => timers.forEach((x) => window.clearTimeout(x));
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [state, lobby.quiz_seq]);

    // ---------------- Abstimmung ----------------
    const myVote = q.status?.myvote ?? null;
    const votedCount = new Set(q.status?.voted ?? []).size;
    const canVote = (state === "spin" || state === "vote") && !!me && cands.length === 3;
    const vote = useCallback((c: number) => void q.voteCategory(c), [q]);
    useEffect(() => {
        if (!canVote) return;
        const onKey = (ev: KeyboardEvent) => {
            const tag = (ev.target as HTMLElement | null)?.tagName;
            if (tag === "INPUT" || tag === "TEXTAREA") return;
            if (ev.key === "1" || ev.key === "2" || ev.key === "3") vote(Number(ev.key));
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [canVote, vote]);

    // ---------------- Eingabe: Wörter schweben im Raum ----------------
    const [seedBase] = useState(() => Math.floor(Math.random() * 1e9));
    const seed = seedBase + lobby.quiz_seq * 31;
    // eigene Eingaben in Eingabe-Reihenfolge (lokal sofort, beim Neuladen vom Server)
    const [localState, setLocal] = useState<{ seq: number; list: string[] }>({ seq: -1, list: [] });
    const serverMine = q.status?.mine;
    const typed = useMemo(() => {
        const base = localState.seq === lobby.quiz_seq ? localState.list : [];
        const seen = new Set(base.map((x) => x.toLowerCase()));
        return [...base, ...(serverMine ?? []).filter((x) => !seen.has(x.toLowerCase()))];
    }, [localState, lobby.quiz_seq, serverMine]);
    const [text, setText] = useState("");
    const inputRef = useRef<HTMLInputElement | null>(null);
    const canType = state === "question" && !!me;
    const iAmDone = !!me && (q.status?.done ?? []).includes(me.player_id);
    const doneSet = useMemo(() => new Set(q.status?.done ?? []), [q.status]);
    useEffect(() => {
        if (canType) inputRef.current?.focus();
    }, [canType, lobby.quiz_seq]);

    const add = useCallback(async () => {
        const t = text.trim().replace(/\s+/g, " ");
        if (!canType || iAmDone || t.length < 2) return;
        setText("");
        if (typed.some((x) => x.toLowerCase() === t.toLowerCase())) {
            onToast(tr("Das hast du schon eingegeben."), 1400);
            return;
        }
        setLocal((s) => ({ seq: lobby.quiz_seq, list: [...(s.seq === lobby.quiz_seq ? s.list : []), t] }));
        playFx("vote");
        const ok = await q.submitTerm(t);
        if (!ok) setLocal((s) => ({ seq: s.seq, list: s.list.filter((x) => x !== t) }));
    }, [text, canType, iAmDone, typed, lobby.quiz_seq, onToast, tr, q]);

    // ---------------- Wörter der Karte ----------------
    const words: Word[] = useMemo(() => {
        const key = (pid: string, t: string) => `${pid}|${t.toLowerCase()}`;
        if (state === "question") return typed.map((t) => ({ key: key(mePlayerId ?? "me", t), text: t, pid: mePlayerId ?? "me", kind: "plain" as const, mine: true }));
        if (state !== "reveal") return [];
        const out: Word[] = [];
        const myRow = rows.find((r) => r.playerId === mePlayerId);
        const mineAll: Word[] = [];
        if (myRow) {
            for (const v of myRow.valid) mineAll.push({ key: key(myRow.playerId, v.t), text: v.l, pid: myRow.playerId, kind: "ok", mine: true });
            for (const b of myRow.bad) mineAll.push({ key: key(myRow.playerId, b), text: b, pid: myRow.playerId, kind: "bad", mine: true });
            for (const d of myRow.dup) mineAll.push({ key: key(myRow.playerId, d), text: d, pid: myRow.playerId, kind: "dup", mine: true });
        }
        // meine Wörter behalten ihren Platz aus der Eingabe-Phase (Reihenfolge wie getippt)
        const orderOf = (w: Word) => {
            const t = typed.findIndex((x) => w.key.endsWith(`|${x.toLowerCase()}`));
            return t >= 0 ? t : 1000 + mineAll.indexOf(w);
        };
        // Schreibweise (key) ist der getippte Text, angezeigt wird der erkannte Begriff
        const mineSorted = [...mineAll].sort((a, b) => orderOf(a) - orderOf(b));
        out.push(...mineSorted);
        for (const r of [...rows].sort((a, b) => a.playerId.localeCompare(b.playerId))) {
            if (r.playerId === mePlayerId) continue;
            const theirs: Word[] = [];
            for (const v of r.valid) theirs.push({ key: key(r.playerId, v.t), text: v.l, pid: r.playerId, kind: "ok", mine: false });
            for (const b of r.bad) theirs.push({ key: key(r.playerId, b), text: b, pid: r.playerId, kind: "bad", mine: false });
            for (const d of r.dup) theirs.push({ key: key(r.playerId, d), text: d, pid: r.playerId, kind: "dup", mine: false });
            out.push(...theirs.sort((a, b) => a.key.localeCompare(b.key)));
        }
        return out;
    }, [state, typed, rows, mePlayerId]);
    const crowded = words.length > 44;

    // Wörter färben sich erst kurz nach der Auflösung (grün/groß bzw. rot/klein)
    const revealStart = lobby.quiz_started_at ? Date.parse(lobby.quiz_started_at) : serverNow();
    const tReveal = state === "reveal" ? (serverNow() - revealStart) / 1000 : 0;
    const colored = state === "reveal" && tReveal > 0.8;
    // Einspruch: nur solange die Wörter-Karte steht (Server lässt bis 1 s vorher zu)
    const appealOpen = state === "reveal" && !!me && !me.is_bot && tReveal < MAP_S - 1.2;
    const appeals: Appeal[] = q.status?.appeals ?? [];
    const myBadCount = rows.find((r) => r.playerId === mePlayerId)?.bad.length ?? 0;
    const openOthers = appeals.filter((a) => a.s === "open" && a.o !== mePlayerId).length;

    // ---------------- Wertungs-Show ----------------
    const n = rows.length;
    const D = showSeconds(n);
    const last = !!reveal?.last;
    const showStage = state !== "reveal" ? 0 : tReveal >= MAP_S + (last ? D : 0) && last ? 2 : tReveal >= MAP_S ? 1 : 0;
    const ascTotals = useMemo(
        () => [...players].map((p) => ({ playerId: p.player_id, name: p.name, points: Number(p.song_points ?? 0) })).sort((a, b) => a.points - b.points || b.name.localeCompare(a.name)),
        [players]
    );
    const mine = rows.find((r) => r.playerId === mePlayerId) ?? null;

    return (
        <main className="fullH lrMain">
            <div className="lrTopRight">
                <AudioControl />
            </div>

            <header className="lrHead">
                <span className="lrMode">
                    {info.icon} {tr(info.label)}
                </span>
                <span className="lrGoal">🎯 {tr(info.goal)}</span>
                {idx > 0 || state === "vote" ? (
                    <span className="lrCount">
                        {tr("Kategorie {i} von {n}", { i: Math.min(state === "vote" ? idx + 1 : Math.max(1, idx), total), n: total })}
                        {lobby.series_total > 1 ? ` · ${tr("Runde {i}/{n}", { i: lobby.series_index, n: lobby.series_total })}` : ""}
                    </span>
                ) : null}
            </header>

            <div className="lrBar" aria-hidden>
                <div className={`lrBarFill ${q.left < 8 && state === "question" ? "hot" : ""}`} style={{ transform: `scaleX(${q.ratio})` }} />
            </div>

            {/* ---------- Roulette + Abstimmung ---------- */}
            {state === "spin" || !state ? (
                <section className="lrScene" key={`spin:${lobby.quiz_seq}`}>
                    <div className="lrKick">{tr("Das Roulette entscheidet …")}</div>
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
                            <div className="lrReel" style={{ transform: reelTransform, transition: reelTransition }}>
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
                    <VoteCards cands={cands} tally={tally} myVote={myVote} canVote={canVote} onVote={vote} votedCount={votedCount} humans={humans} rise />
                </section>
            ) : null}

            {state === "vote" ? (
                <section className="lrScene" key={`vote:${lobby.quiz_seq}`}>
                    <div className="lrPanel">
                        <div className="lrLetter" aria-label={tr("Buchstabe {l}", { l: letter })}>
                            {letter}
                        </div>
                        <div className="lrPanelText">
                            <small>{tr("Kategorie {i} von {n}", { i: Math.min(idx + 1, total), n: total })}</small>
                            <h2>{tr("Wählt die nächste Kategorie")}</h2>
                        </div>
                        <TimerRing left={q.left} ratio={q.ratio} hot={false} label={tr("Verbleibende Zeit")} />
                    </div>
                    <VoteCards cands={cands} tally={tally} myVote={myVote} canVote={canVote} onVote={vote} votedCount={votedCount} humans={humans} />
                </section>
            ) : null}

            {/* ---------- Eingabe ---------- */}
            {state === "question" ? (
                <section className="lrScene" key={`q:${lobby.quiz_seq}`}>
                    <div className="lrPanel">
                        <div className="lrLetter" aria-label={tr("Buchstabe {l}", { l: letter })}>
                            {letter}
                        </div>
                        <div className="lrPanelText">
                            <small>{tr("Kategorie {i} von {n}", { i: idx, n: total })}</small>
                            <h1>{cat?.name ?? "…"}</h1>
                            <span>{tr("Tippe so viele Begriffe wie möglich, die mit „{l}“ anfangen.", { l: letter })}</span>
                        </div>
                        <TimerRing left={q.left} ratio={q.ratio} hot={q.left < 8} label={tr("Verbleibende Zeit")} />
                    </div>

                    {me ? (
                        <>
                            <form
                                className="lrForm"
                                onSubmit={(e) => {
                                    e.preventDefault();
                                    void add();
                                }}
                            >
                                <input
                                    ref={inputRef}
                                    className="lrInput"
                                    value={text}
                                    onChange={(e) => setText(e.target.value)}
                                    placeholder={iAmDone ? tr("Du bist fertig – warte auf die anderen …") : tr("Begriff eintippen und Enter …")}
                                    maxLength={40}
                                    disabled={iAmDone}
                                    autoComplete="off"
                                    autoCapitalize="words"
                                    autoCorrect="off"
                                    spellCheck={false}
                                    enterKeyHint="send"
                                    aria-label={tr("Begriff")}
                                />
                                <button type="submit" className="btn btnPrimary lrAdd" disabled={iAmDone || text.trim().length < 2}>
                                    {tr("Hinzufügen")}
                                </button>
                            </form>
                            <div className="lrCountRow">
                                <b>{typed.length}</b> {typed.length === 1 ? tr("Begriff") : tr("Begriffe")}
                                <button type="button" className="btn btnSecondary btnSmall lrDone" onClick={() => void q.finishTerms()} disabled={iAmDone || q.busy}>
                                    {iAmDone ? tr("✓ Fertig") : tr("Fertig ✓")}
                                </button>
                            </div>
                        </>
                    ) : (
                        <div className="lrWatch">{tr("Du schaust zu.")}</div>
                    )}

                    <WordMap words={words} seed={seed} colored={false} crowded={false} players={players} label={tr("Deine Eingaben")} tag={`✍️ ${tr("Deine Eingaben")}`} />
                </section>
            ) : null}

            {/* ---------- Auflösung: Wörter-Karte, danach Wertungs-Show ---------- */}
            {state === "reveal" && reveal ? (
                <section className="lrScene" key={`r:${lobby.quiz_seq}`}>
                    <div className="lrPanel">
                        <div className="lrLetter" aria-label={tr("Buchstabe {l}", { l: String(reveal.letter ?? letter) })}>
                            {String(reveal.letter ?? letter)}
                        </div>
                        <div className="lrPanelText">
                            <small>{tr("Auflösung")}</small>
                            <h2>{String(reveal.category ?? "")}</h2>
                        </div>
                        {me ? (
                            <div className="lrMineHead">
                                <b>{mine?.points ?? 0}</b>
                                {tr("richtig")}
                            </div>
                        ) : null}
                    </div>
                    <WordMap
                        words={words}
                        seed={seed}
                        colored={colored}
                        crowded={crowded}
                        players={players}
                        label={tr("Alle Eingaben")}
                        tag={`👥 ${tr("Alle Eingaben")}`}
                        showAuthors
                        appeals={appeals}
                        appealOpen={appealOpen}
                        mePlayerId={mePlayerId}
                        onAppeal={(t) => void q.appeal(t)}
                        onAppealVote={(o, t, yes) => void q.appealVote(o, t, yes)}
                    />
                    {appealOpen && myBadCount > 0 ? <div className="lrAppealHint">⚖️ {tr("Zu Unrecht rot? Tippe auf dein rotes Wort – die anderen stimmen ab.")}</div> : null}
                    {appealOpen && openOthers > 0 ? <div className="lrAppealHint vote">👍👎 {tr("Gilt das Wort? Stimme bei den Einsprüchen ab.")}</div> : null}
                    <div className="lrLegend">
                        <span className="ok">✓ {tr("erkannt")}</span>
                        <span className="bad">✗ {tr("nicht erkannt")}</span>
                        <span className="dup">＝ {tr("doppelt")}</span>
                    </div>
                </section>
            ) : null}

            {/* ---------- Pulte: alle Spieler mit Punktestand ---------- */}
            <Podia
                players={players}
                mePlayerId={mePlayerId}
                state={state}
                doneSet={doneSet}
                votedSet={new Set(q.status?.voted ?? [])}
                gains={state === "reveal" ? new Map(rows.map((r) => [r.playerId, r.points])) : null}
                gainKey={lobby.quiz_seq}
                compact={state === "question" || state === "reveal"}
            />

            {state === "reveal" && showStage > 0 ? (
                <RankShow
                    key={`show:${lobby.quiz_seq}:${showStage}`}
                    title={showStage === 2 ? tr("Gesamtwertung") : String(reveal?.category ?? "")}
                    subtitle={showStage === 2 ? tr("Nach {n} Kategorien", { n: total }) : tr("Die Wertung dieser Kategorie")}
                    rows={showStage === 2 ? ascTotals : rows.map((r) => ({ playerId: r.playerId, name: r.name, points: r.points }))}
                    startMs={revealStart + (MAP_S + (showStage === 2 ? D : 0)) * 1000}
                    players={players}
                    mePlayerId={mePlayerId}
                    ptsLabel={showStage === 2 ? tr("Punkte") : tr("Begriffe")}
                />
            ) : null}

            <style>{STYLES}</style>
        </main>
    );
}

/** Fester Farbton je Kategorie (damit jede Karte ihre eigene Farbe hat) */
function hueOf(name: string): number {
    let h = 0;
    for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) % 360;
    return h;
}

/** Zeit-Ring wie bei der Buzzer-Arena: der Ring läuft leer, in der Mitte steht die Restzeit */
function TimerRing({ left, ratio, hot, label }: { left: number; ratio: number; hot: boolean; label: string }) {
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
function Podia({ players, mePlayerId, state, doneSet, votedSet, gains, gainKey, compact }: { players: QuizPlayer[]; mePlayerId: string | null; state: string | null | undefined; doneSet: Set<string>; votedSet: Set<string>; gains: Map<string, number> | null; gainKey: number; compact: boolean }) {
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

/** Drei Kategorien zur Abstimmung (unten beim Roulette bzw. groß zwischen den Kategorien) */
function VoteCards({ cands, tally, myVote, canVote, onVote, votedCount, humans, rise = false }: { cands: CatInfo[]; tally: number[]; myVote: number | null; canVote: boolean; onVote: (c: number) => void; votedCount: number; humans: number; rise?: boolean }) {
    const { tr } = useI18n();
    return (
        <div className={`lrVotes ${rise ? "rise" : ""}`}>
            <div className="lrVoteHint">
                {canVote ? tr("Stimme für eine Kategorie – die Mehrheit entscheidet (Taste 1, 2 oder 3)") : tr("Die Kategorie wird abgestimmt …")}
                <b>
                    {votedCount}/{humans}
                </b>
            </div>
            <div className="lrVoteGrid" role="radiogroup" aria-label={tr("Kategorie wählen")}>
                {cands.map((c, i) => {
                    const mineV = myVote === i + 1;
                    const cnt = Number(tally[i] ?? 0);
                    return (
                        <button
                            key={c.id}
                            type="button"
                            role="radio"
                            aria-checked={mineV}
                            className={`lrVoteCard ${mineV ? "on" : ""}`}
                            style={{ ["--h" as string]: hueOf(c.name) }}
                            disabled={!canVote}
                            onClick={() => onVote(i + 1)}
                        >
                            <span className="lrVoteNo">{i + 1}</span>
                            {mineV ? <span className="lrVoteCheck" aria-hidden>✓</span> : null}
                            <span className="lrVoteIcon" aria-hidden>
                                {CAT_ICON[c.name] ?? "🎯"}
                            </span>
                            <b className="lrVoteName">{c.name}</b>
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

/** Wörter-Karte: jedes Wort steht fest an seinem Platz im Raum; bei der Auflösung färben sie sich (richtig: grün + größer, falsch: rot + kleiner) */
function WordMap({
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

/**
 * Wertungs-Show: der Bildschirm wird frei (gleicher Hintergrund), Trommelwirbel, dann kommt der Letzte, danach Platz für Platz nach
 * oben – je höher, desto mehr Konfetti und Effekte; Platz 1 mit Fanfare und Konfetti-Feuerwerk. Der Takt kommt von der Server-Uhr,
 * wer später dazukommt, sieht gleich den passenden Platz. "Überspringen" zeigt sofort die fertige Liste (nur bei mir).
 */
function RankShow({ title, subtitle, rows, startMs, players, mePlayerId, ptsLabel }: { title: string; subtitle: string; rows: { playerId: string; name: string; points: number }[]; startMs: number; players: QuizPlayer[]; mePlayerId: string | null; ptsLabel: string }) {
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
