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

const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
const ITEM = 104; // Breite eines Buchstabens auf der Walze (px)
const REPEATS = 7; // Walze = 7x A–Z, der Zielbuchstabe liegt in der vorletzten Wiederholung
const SPIN_MS = 5600;

// Wörter-Karte: feste Spalten, y in Zeilen (so bleibt jedes Wort an seinem Platz, auch wenn weitere dazukommen)
const MAP_COLS = 4;
const BASE_ROWS = 8; // Zeilenhöhe steht im CSS (--rh), damit sie auf dem Handy kleiner sein kann

// Wertungs-Show: Wörter-Karte 7 s, dann je Platz 2,2 s (Trommelwirbel 0,9 s + Treffer), Sieger +1,5 s – muss zur Datenbank passen (Migration 128)
const MAP_S = 7;
const INTRO_S = 1;
const PLACE_S = 2.2;
const ROLL_S = 0.9;
const showSeconds = (n: number) => INTRO_S + PLACE_S * n + 1.5;

type CatInfo = { id: string; name: string };
type ValidItem = { t: string; l: string };
type ResultRow = { playerId: string; name: string; points: number; valid: ValidItem[]; bad: string[]; dup: string[] };
type Word = { key: string; text: string; pid: string; kind: "plain" | "ok" | "bad" | "dup"; mine: boolean };

const CAT_ICON: Record<string, string> = {
    Rapper: "🎤", Schauspieler: "🎬", Länder: "🌍", Städte: "🏙️", Hauptstädte: "🏛️", Sänger: "🎵", Bands: "🎸", Fußballspieler: "⚽",
    Fußballvereine: "🏟️", Flüsse: "🌊", Serien: "📺", Tiere: "🐾", "Obst & Gemüse": "🍎", Automarken: "🚗",
};

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
function slotOf(k: number, seed: number): { x: number; y: number } {
    const B = MAP_COLS * BASE_ROWS;
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
                const cx = cand % MAP_COLS;
                const cy = Math.floor(cand / MAP_COLS);
                let d = 99;
                for (const o of perm) d = Math.min(d, Math.hypot((o % MAP_COLS) - cx, (Math.floor(o / MAP_COLS) - cy) * 0.8));
                if (d > bestD) {
                    bestD = d;
                    best = cand;
                }
            }
            perm.push(best);
            free.splice(free.indexOf(best), 1);
        }
        const cell = perm[k]!;
        row = Math.floor(cell / MAP_COLS);
        col = cell % MAP_COLS;
    } else {
        const extra = k - B;
        row = BASE_ROWS + Math.floor(extra / MAP_COLS);
        const cols = Array.from({ length: MAP_COLS }, (_, i) => i);
        const r = rng(seed + row * 131);
        for (let i = cols.length - 1; i > 0; i--) {
            const j = Math.floor(r() * (i + 1));
            [cols[i], cols[j]] = [cols[j]!, cols[i]!];
        }
        col = cols[extra % MAP_COLS]!;
    }
    const j = rng(seed * 7 + k * 977);
    return { x: 16 + ((col + 0.5) / MAP_COLS) * 68 + (j() - 0.5) * 6, y: row + 0.5 + (j() - 0.5) * 0.26 };
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
    const me = players.find((p) => p.player_id === mePlayerId) ?? null;
    const reveal = lobby.quiz_reveal as { letter?: string; category?: string; index?: number; last?: boolean; results?: ResultRow[] } | null;
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
        for (const r of rows) {
            if (r.playerId === mePlayerId) continue;
            for (const v of r.valid) out.push({ key: key(r.playerId, v.t), text: v.l, pid: r.playerId, kind: "ok", mine: false });
            for (const b of r.bad) out.push({ key: key(r.playerId, b), text: b, pid: r.playerId, kind: "bad", mine: false });
            for (const d of r.dup) out.push({ key: key(r.playerId, d), text: d, pid: r.playerId, kind: "dup", mine: false });
        }
        return out;
    }, [state, typed, rows, mePlayerId]);
    const mapRows = Math.max(BASE_ROWS, Math.ceil(words.length / MAP_COLS) + 1);
    const crowded = words.length > 44;

    // Wörter färben sich erst kurz nach der Auflösung (grün/groß bzw. rot/klein)
    const revealStart = lobby.quiz_started_at ? Date.parse(lobby.quiz_started_at) : serverNow();
    const tReveal = state === "reveal" ? (serverNow() - revealStart) / 1000 : 0;
    const colored = state === "reveal" && tReveal > 0.8;

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
                        {tr("Kategorie {i} von {n}", { i: Math.min(state === "vote" ? idx + 1 : Math.max(1, idx), 3), n: 3 })}
                        {lobby.series_total > 1 ? ` · ${tr("Runde {i}/{n}", { i: lobby.series_index, n: lobby.series_total })}` : ""}
                    </span>
                ) : null}
            </header>

            <div className="lrBar" aria-hidden>
                <div className={`lrBarFill ${q.left < 8 && state === "question" ? "hot" : ""}`} style={{ transform: `scaleX(${state === "spin" || state === "vote" ? q.ratio : q.ratio})` }} />
            </div>

            {/* ---------- Roulette + Abstimmung ---------- */}
            {state === "spin" || !state ? (
                <section className="lrSpin" key={`spin:${lobby.quiz_seq}`}>
                    <div className="lrKick">{tr("Das Roulette entscheidet …")}</div>
                    <div className="lrReelWrap">
                        <div className="lrPointer" aria-hidden>
                            ▼
                        </div>
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
                    <VoteCards cands={cands} tally={tally} myVote={myVote} canVote={canVote} onVote={vote} votedCount={votedCount} humans={humans} rise />
                </section>
            ) : null}

            {state === "vote" ? (
                <section className="lrVote" key={`vote:${lobby.quiz_seq}`}>
                    <div className="lrVoteTop">
                        <div className="lrLetter">{letter}</div>
                        <div>
                            <small>{tr("Kategorie {i} von {n}", { i: Math.min(idx + 1, 3), n: 3 })}</small>
                            <h2>{tr("Wählt die nächste Kategorie")}</h2>
                        </div>
                        <div className="lrTimer" title={tr("Verbleibende Zeit")}>
                            {Math.ceil(q.left)}
                            <small>s</small>
                        </div>
                    </div>
                    <VoteCards cands={cands} tally={tally} myVote={myVote} canVote={canVote} onVote={vote} votedCount={votedCount} humans={humans} />
                    <div className="lrTotal" aria-label={tr("Gesamtstand")}>
                        <span className="lrTotalLabel">{tr("Gesamt")}</span>
                        {[...ascTotals].reverse().map((p) => (
                            <span key={p.playerId} className={`lrTotalChip ${p.playerId === mePlayerId ? "me" : ""}`}>
                                {p.name} <b>{p.points}</b>
                            </span>
                        ))}
                    </div>
                </section>
            ) : null}

            {/* ---------- Eingabe ---------- */}
            {state === "question" ? (
                <section className="lrPlay" key={`q:${lobby.quiz_seq}`}>
                    <div className="lrTask">
                        <div className="lrLetter" aria-label={tr("Buchstabe {l}", { l: letter })}>
                            {letter}
                        </div>
                        <div className="lrTaskText">
                            <small>{tr("Kategorie {i} von {n}", { i: idx, n: 3 })}</small>
                            <h1>{cat?.name ?? "…"}</h1>
                            <span>{tr("Tippe so viele Begriffe wie möglich, die mit „{l}“ anfangen.", { l: letter })}</span>
                        </div>
                        <div className="lrTimer" title={tr("Verbleibende Zeit")}>
                            {Math.ceil(q.left)}
                            <small>s</small>
                        </div>
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

                    <WordMap words={words} seed={seed} rows={mapRows} colored={false} crowded={false} players={players} label={tr("Deine Eingaben")} />

                    <div className="lrOthers" aria-label={tr("Mitspieler")}>
                        {players
                            .filter((p) => p.player_id !== mePlayerId)
                            .map((p) => (
                                <span key={p.player_id} className={`lrChip ${p.is_bot || doneSet.has(p.player_id) ? "done" : ""}`} title={p.name}>
                                    <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={22} />
                                    <span>{p.name}</span>
                                    <span aria-hidden>{p.is_bot || doneSet.has(p.player_id) ? "✓" : "⌨️"}</span>
                                </span>
                            ))}
                    </div>
                </section>
            ) : null}

            {/* ---------- Auflösung: Wörter-Karte, danach Wertungs-Show ---------- */}
            {state === "reveal" && reveal ? (
                <section className="lrReveal" key={`r:${lobby.quiz_seq}`}>
                    <div className="lrRevHead">
                        <div className="lrLetter small">{String(reveal.letter ?? letter)}</div>
                        <div>
                            <small>{tr("Auflösung")}</small>
                            <h2>{String(reveal.category ?? "")}</h2>
                        </div>
                        {me ? (
                            <div className="lrMineHead">
                                {tr("Deine Liste")} · <b>{mine?.points ?? 0}</b> {tr("richtig")}
                            </div>
                        ) : null}
                    </div>
                    <WordMap words={words} seed={seed} rows={mapRows} colored={colored} crowded={crowded} players={players} label={tr("Alle Eingaben")} showAuthors />
                    <div className="lrLegend">
                        <span className="ok">✓ {tr("erkannt")}</span>
                        <span className="bad">✗ {tr("nicht erkannt")}</span>
                        <span className="dup">＝ {tr("doppelt")}</span>
                    </div>
                </section>
            ) : null}

            {state === "reveal" && showStage > 0 ? (
                <RankShow
                    key={`show:${lobby.quiz_seq}:${showStage}`}
                    title={showStage === 2 ? tr("Gesamtwertung") : String(reveal?.category ?? "")}
                    subtitle={showStage === 2 ? tr("Nach 3 Kategorien") : tr("Die Wertung dieser Kategorie")}
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
                            style={{ ["--i" as string]: i }}
                            disabled={!canVote}
                            onClick={() => onVote(i + 1)}
                        >
                            <span className="lrVoteNo">{i + 1}</span>
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
function WordMap({ words, seed, rows, colored, crowded, players, label, showAuthors = false }: { words: Word[]; seed: number; rows: number; colored: boolean; crowded: boolean; players: QuizPlayer[]; label: string; showAuthors?: boolean }) {
    const pos = useMemo(() => words.map((_, k) => slotOf(k, seed)), [words, seed]);
    const byId = useMemo(() => new Map(players.map((p) => [p.player_id, p])), [players]);
    return (
        <div className="lrMap" style={{ height: `calc(var(--rh) * ${rows})` }} role="group" aria-label={label}>
            {words.length === 0 ? <div className="lrMapEmpty">{label}</div> : null}
            {words.map((w, i) => {
                const p = byId.get(w.pid);
                return (
                    <span
                        key={`${w.key}:${w.kind}`}
                        className={`lrW ${w.kind} ${w.mine ? "mine" : ""} ${colored ? "go" : ""} ${crowded ? "tiny" : ""}`}
                        style={{ left: `${pos[i]!.x}%`, top: `calc(var(--rh) * ${pos[i]!.y})`, ["--i" as string]: i % 24 }}
                        title={p?.name}
                    >
                        {showAuthors && p ? <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={crowded ? 16 : 20} /> : null}
                        <span>{w.text}</span>
                        {showAuthors && colored && w.kind === "ok" ? <em aria-hidden>✓</em> : null}
                        {showAuthors && colored && w.kind === "bad" ? <em aria-hidden>✗</em> : null}
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

const STYLES = `
.lrMain{ min-height: 100dvh; color: #fff; display: flex; flex-direction: column; gap: 10px; padding: 12px 14px 22px; position: relative; overflow-x: hidden;
  background: radial-gradient(ellipse 60% 45% at 50% -8%, rgba(255,205,90,.28), transparent 70%), radial-gradient(ellipse 50% 60% at 8% 35%, rgba(255,60,120,.16), transparent 70%),
              radial-gradient(ellipse 50% 60% at 92% 35%, rgba(70,200,255,.14), transparent 70%), linear-gradient(180deg, #2a0f3c 0%, #1a0a2a 55%, #0e0618 100%); }
.lrTopRight{ position: fixed; top: 14px; right: 14px; z-index: 60; }
.lrHead{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 0 64px 0 128px; min-height: 40px; }
@media (max-width: 640px){ .lrHead{ padding-left: 52px; } }
.lrMode{ font-family: var(--font-display); font-weight: 900; font-size: clamp(20px, 3vw, 28px); }
.lrGoal{ font-size: 12.5px; font-weight: 850; color: #ffe08a; padding: 4px 11px; border-radius: 999px; background: rgba(255,210,63,.12); border: 1px solid rgba(255,210,63,.35); }
.lrCount{ margin-left: auto; font-size: 13px; font-weight: 800; opacity: .8; }
.lrBar{ height: 8px; border-radius: 999px; background: rgba(255,255,255,.1); overflow: hidden; }
.lrBarFill{ height: 100%; transform-origin: left center; transition: transform .25s linear; background: linear-gradient(90deg, #ffd23f, #ff9d2e); }
.lrBarFill.hot{ background: linear-gradient(90deg, #ff6a3c, #ff2e4a); }

/* Walze */
.lrSpin{ display: flex; flex-direction: column; align-items: center; gap: 18px; flex: 1; padding: 10px 0; min-width: 0; }
.lrKick{ font-size: 13px; font-weight: 900; letter-spacing: 2px; text-transform: uppercase; opacity: .75; }
.lrReelWrap{ position: relative; width: min(900px, 100%); height: 170px; overflow: hidden; border-radius: 26px; background: linear-gradient(180deg, rgba(0,0,0,.45), rgba(0,0,0,.2)); border: 2px solid rgba(255,210,63,.5);
  box-shadow: 0 0 0 6px rgba(255,210,63,.1), 0 24px 60px rgba(0,0,0,.45), inset 0 0 40px rgba(0,0,0,.5); }
.lrReelWrap::before, .lrReelWrap::after{ content: ""; position: absolute; top: 0; bottom: 0; width: 22%; z-index: 2; pointer-events: none; }
.lrReelWrap::before{ left: 0; background: linear-gradient(90deg, #1a0a2a, transparent); }
.lrReelWrap::after{ right: 0; background: linear-gradient(270deg, #1a0a2a, transparent); }
.lrReel{ position: absolute; left: 50%; top: 0; height: 100%; display: flex; align-items: center; will-change: transform; }
.lrCell{ flex: none; width: ${ITEM}px; text-align: center; font-family: var(--font-display); font-weight: 900; font-size: 96px; line-height: 1; color: rgba(255,255,255,.55); }
.lrCell.hit{ color: #ffd23f; text-shadow: 0 0 30px rgba(255,210,63,.9); animation: lrHit .5s cubic-bezier(.3,1.6,.5,1) both; }
@keyframes lrHit{ from{ transform: scale(.8); } to{ transform: scale(1.18); } }
.lrPointer, .lrPointerB{ position: absolute; left: 50%; transform: translateX(-50%); z-index: 3; color: #ffd23f; font-size: 22px; text-shadow: 0 2px 8px rgba(0,0,0,.6); }
.lrPointer{ top: 2px; } .lrPointerB{ bottom: 2px; }

/* Abstimmung */
.lrVotes{ width: min(980px, 100%); display: grid; gap: 8px; margin-top: auto; }
.lrVotes.rise{ animation: lrRise .8s cubic-bezier(.16,1,.3,1) .5s both; }
@keyframes lrRise{ from{ opacity: 0; transform: translateY(60px); } }
.lrVoteHint{ display: flex; align-items: center; justify-content: space-between; gap: 10px; font-size: 13px; font-weight: 800; opacity: .9; }
.lrVoteHint b{ color: #ffe08a; font-family: var(--font-display); font-size: 17px; }
.lrVoteGrid{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.lrVoteCard{ position: relative; display: grid; justify-items: center; align-content: center; gap: 6px; padding: 18px 10px 14px; min-height: 150px; border-radius: 22px; cursor: pointer; color: #fff; font: inherit;
  background: linear-gradient(160deg, rgba(255,255,255,.1), rgba(255,255,255,.04)); border: 2px solid rgba(255,255,255,.2); transition: transform .18s ease, border-color .18s ease, background .18s ease; }
.lrVoteCard:hover:not(:disabled){ transform: translateY(-4px); border-color: rgba(255,210,63,.6); }
.lrVoteCard.on{ border-color: #ffd23f; background: linear-gradient(160deg, rgba(255,210,63,.28), rgba(255,140,40,.1)); box-shadow: 0 0 0 4px rgba(255,210,63,.18), 0 14px 34px rgba(0,0,0,.35); }
.lrVoteCard:disabled{ cursor: default; opacity: .85; }
.lrVoteNo{ position: absolute; top: 8px; left: 10px; width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 13px; background: rgba(255,255,255,.16); }
.lrVoteCard.on .lrVoteNo{ background: #ffd23f; color: #2a1200; }
.lrVoteIcon{ font-size: 38px; line-height: 1; }
.lrVoteName{ font-family: var(--font-display); font-size: clamp(18px, 2.4vw, 26px); line-height: 1.1; text-align: center; overflow-wrap: anywhere; }
.lrVoteDots{ display: flex; gap: 5px; flex-wrap: wrap; justify-content: center; min-height: 14px; }
.lrVoteDots i{ width: 14px; height: 14px; border-radius: 50%; background: #ffd23f; box-shadow: 0 0 8px rgba(255,210,63,.7); animation: lrPop .35s cubic-bezier(.2,1.6,.4,1); }
.lrVoteDots em{ font-style: normal; opacity: .4; }
.lrVote{ display: grid; grid-template-columns: minmax(0, 1fr); gap: 16px; align-content: start; width: min(980px, 100%); margin: 0 auto; flex: 1; animation: lrIn .4s cubic-bezier(.16,1,.3,1); }
.lrVoteTop{ display: flex; align-items: center; gap: 14px; }
.lrVoteTop small{ font-size: 11px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .7; }
.lrVoteTop h2{ margin: 0; font-size: clamp(22px, 3.4vw, 34px); }
.lrVoteTop .lrTimer{ margin-left: auto; }

/* Eingabe */
.lrPlay{ display: grid; grid-template-columns: minmax(0, 1fr); gap: 12px; align-content: start; width: min(900px, 100%); margin: 0 auto; flex: 1; animation: lrIn .4s cubic-bezier(.16,1,.3,1); }
@keyframes lrIn{ from{ opacity: 0; transform: translateY(12px); } }
.lrTask{ display: flex; align-items: center; gap: 16px; padding: 14px 18px; border-radius: 24px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.16); }
.lrLetter{ flex: none; width: 92px; height: 92px; border-radius: 26px; display: grid; place-items: center; font-family: var(--font-display); font-weight: 900; font-size: 64px; color: #2a1200;
  background: linear-gradient(160deg, #fff0a8, #ffc22e 60%, #ff9d2e); box-shadow: 0 8px 26px rgba(255,170,30,.45); }
.lrLetter.small{ width: 56px; height: 56px; border-radius: 16px; font-size: 38px; }
.lrTaskText{ display: grid; gap: 2px; min-width: 0; flex: 1; }
.lrTaskText small{ font-size: 11px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .7; }
.lrTaskText h1{ margin: 0; font-size: clamp(26px, 4.4vw, 40px); line-height: 1.05; overflow-wrap: break-word; hyphens: auto; }
.lrTaskText span{ font-size: 13px; opacity: .8; }
.lrTimer{ flex: none; font-family: var(--font-display); font-weight: 900; font-size: 40px; min-width: 70px; text-align: right; color: #ffe08a; }
.lrTimer small{ font-size: 16px; opacity: .7; margin-left: 2px; }
.lrForm{ display: flex; gap: 8px; }
.lrInput{ flex: 1; min-width: 0; padding: 15px 18px; border-radius: 18px; font: inherit; font-size: 20px; font-weight: 800; color: #fff; background: rgba(0,0,0,.4); border: 2px solid rgba(255,210,63,.55); outline: none; }
.lrInput:focus{ border-color: #ffd23f; box-shadow: 0 0 0 4px rgba(255,210,63,.2); }
.lrInput::placeholder{ color: rgba(255,255,255,.45); font-weight: 600; }
.lrInput:disabled{ opacity: .6; }
.lrAdd{ flex: none; }
.lrCountRow{ display: flex; align-items: center; gap: 6px; font-weight: 800; }
.lrCountRow b{ font-family: var(--font-display); font-size: 26px; color: #ffe08a; }
.lrDone{ margin-left: auto; }
.lrWatch{ text-align: center; font-weight: 800; opacity: .8; padding: 22px 0; }
.lrOthers{ display: flex; gap: 6px; flex-wrap: wrap; justify-content: center; margin-top: 4px; }
.lrChip{ display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px 4px 5px; border-radius: 999px; font-size: 12.5px; font-weight: 800; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); opacity: .85; }
.lrChip.done{ background: rgba(60,200,120,.2); border-color: rgba(100,230,150,.5); opacity: 1; }

/* Wörter-Karte */
.lrMap{ --rh: 56px; position: relative; width: 100%; border-radius: 22px; background: radial-gradient(ellipse at 50% 40%, rgba(255,255,255,.07), rgba(255,255,255,.015)); border: 1px dashed rgba(255,255,255,.14); overflow: hidden; }
.lrMapEmpty{ position: absolute; inset: 0; display: grid; place-items: center; opacity: .3; font-weight: 800; letter-spacing: 1.5px; text-transform: uppercase; font-size: 13px; }
.lrW{ position: absolute; transform: translate(-50%, -50%) scale(1); display: inline-flex; align-items: center; gap: 6px; padding: 5px 12px; border-radius: 999px; font-weight: 800; font-size: 15px; white-space: nowrap; max-width: 92%;
  background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.24); animation: lrWPop .45s cubic-bezier(.2,1.6,.4,1) both;
  transition: transform .7s cubic-bezier(.2,1.5,.4,1), background .6s ease, border-color .6s ease, color .6s ease, opacity .6s ease; transition-delay: calc(var(--i, 0) * 45ms); }
.lrW > span{ overflow: hidden; text-overflow: ellipsis; }
.lrW em{ font-style: normal; font-weight: 900; }
.lrW.mine{ box-shadow: 0 0 0 2px rgba(120,220,255,.45); }
.lrW.tiny{ font-size: 12px; padding: 3px 9px; }
.lrW.ok.go{ transform: translate(-50%, -50%) scale(1.22); background: rgba(20,130,72,.7); border-color: rgba(100,240,160,.9); color: #e2ffee; z-index: 3; }
.lrW.bad.go{ transform: translate(-50%, -50%) scale(.8); background: rgba(140,26,22,.6); border-color: rgba(255,100,88,.8); color: #ffd6d1; opacity: .85; }
.lrW.dup.go{ transform: translate(-50%, -50%) scale(.85); background: rgba(150,100,20,.55); border-color: rgba(255,200,90,.7); color: #ffe9bd; opacity: .85; }
@keyframes lrWPop{ from{ opacity: 0; transform: translate(-50%, -50%) scale(.3); } }
.lrReveal{ display: grid; grid-template-columns: minmax(0, 1fr); gap: 12px; align-content: start; width: min(980px, 100%); margin: 0 auto; flex: 1; animation: lrIn .4s cubic-bezier(.16,1,.3,1); }
.lrRevHead{ display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
.lrRevHead small{ font-size: 11px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; opacity: .7; }
.lrRevHead h2{ margin: 0; font-size: clamp(24px, 4vw, 36px); }
.lrMineHead{ margin-left: auto; font-weight: 800; font-size: 14px; }
.lrMineHead b{ color: #8dffb8; font-family: var(--font-display); font-size: 22px; }
.lrLegend{ display: flex; gap: 14px; justify-content: center; font-size: 12.5px; font-weight: 800; opacity: .85; }
.lrLegend .ok{ color: #8dffb8; } .lrLegend .bad{ color: #ff9d94; } .lrLegend .dup{ color: #ffd88a; }

/* Wertungs-Show */
.lrShow{ position: fixed; inset: 0; z-index: 50; display: grid; grid-template-rows: auto 1fr auto; padding: 18px 18px 20px; overflow: hidden; animation: lrShowIn .6s ease both;
  background: radial-gradient(ellipse 60% 45% at 50% -8%, rgba(255,205,90,.28), transparent 70%), radial-gradient(ellipse 50% 60% at 8% 35%, rgba(255,60,120,.16), transparent 70%),
              radial-gradient(ellipse 50% 60% at 92% 35%, rgba(70,200,255,.14), transparent 70%), linear-gradient(180deg, #2a0f3c 0%, #1a0a2a 55%, #0e0618 100%); }
.lrShow.win{ animation: lrShowIn .6s ease both, lrFlash 1.4s ease .1s; }
@keyframes lrShowIn{ from{ opacity: 0; } }
@keyframes lrFlash{ 0%{ filter: brightness(1); } 12%{ filter: brightness(2.1); } 100%{ filter: brightness(1); } }
.lrSkip{ position: absolute; top: 14px; right: 80px; z-index: 5; }
.lrShowHead{ text-align: center; padding-top: 6px; }
.lrShowHead small{ font-size: 12px; font-weight: 900; letter-spacing: 2px; text-transform: uppercase; opacity: .7; }
.lrShowHead h2{ margin: 2px 0 0; font-size: clamp(26px, 4.4vw, 44px); }
.lrStage{ display: grid; place-items: center; min-height: 0; }
.lrRollTitle{ font-family: var(--font-display); font-size: clamp(26px, 5vw, 52px); font-weight: 900; animation: lrRoll .35s ease-in-out infinite alternate; }
@keyframes lrRoll{ from{ transform: scale(1) rotate(-1.5deg); } to{ transform: scale(1.06) rotate(1.5deg); } }
.lrBig{ display: grid; justify-items: center; gap: 10px; animation: lrBig .7s cubic-bezier(.2,1.6,.4,1) both; }
@keyframes lrBig{ from{ opacity: 0; transform: scale(.3) translateY(60px); } }
.lrBigPlace{ font-size: clamp(18px, 3vw, 28px); font-weight: 900; letter-spacing: 3px; text-transform: uppercase; color: #ffe08a; }
.lrBigAvatar{ position: relative; border-radius: 50%; display: grid; place-items: center; background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.55), rgba(255,170,30,.15) 70%); box-shadow: 0 0 0 5px #ffd23f, 0 0 calc(20px + 60px * var(--lv)) rgba(255,210,63,.6); }
.lrBigAvatar img{ border-radius: 50%; }
.lrCrown{ position: absolute; top: -34px; font-size: 52px; animation: lrCrown 1s ease-in-out infinite alternate; }
@keyframes lrCrown{ from{ transform: rotate(-8deg) translateY(0); } to{ transform: rotate(8deg) translateY(-6px); } }
.lrBigName{ font-family: var(--font-display); font-weight: 900; font-size: clamp(30px, 6vw, 64px); line-height: 1; text-align: center; overflow-wrap: anywhere; }
.lrBig.winner .lrBigName{ background: linear-gradient(180deg, #fff6d6, #ffc23a 55%, #ff8a1c); -webkit-background-clip: text; background-clip: text; color: transparent; filter: drop-shadow(0 4px 16px rgba(255,150,30,.6)); }
.lrBigPts{ font-family: var(--font-display); font-weight: 900; font-size: clamp(34px, 6vw, 60px); color: #ffe08a; }
.lrBigPts small{ font-size: .38em; opacity: .75; margin-left: 4px; }
.lrSoFar{ list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; max-height: 22vh; overflow: hidden; }
.lrSoFar li{ padding: 5px 12px; border-radius: 999px; font-size: 13px; font-weight: 800; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); }
.lrSoFar li span{ opacity: .6; margin-right: 3px; }
.lrSoFar li b{ color: #ffe08a; margin-left: 4px; }
.lrFinal{ list-style: none; margin: 0 auto; padding: 8px 0; display: grid; gap: 8px; width: min(620px, 100%); align-content: center; overflow: auto; }
.lrFinal li{ display: flex; align-items: center; gap: 12px; padding: 10px 16px; border-radius: 18px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.14); animation: lrWPop .5s cubic-bezier(.2,1.5,.4,1) both; animation-delay: calc(var(--i) * 70ms); }
.lrFinal li.first{ background: linear-gradient(160deg, rgba(255,210,63,.32), rgba(255,140,40,.14)); border-color: #ffd23f; box-shadow: 0 0 30px rgba(255,210,63,.3); }
.lrFinal li.me{ outline: 2px solid rgba(120,220,255,.6); }
.lrFinal b{ flex: 1; font-size: 18px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.lrPlace{ flex: none; width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 14px; background: rgba(255,255,255,.14); }
.lrFinalPts{ font-family: var(--font-display); font-weight: 900; font-size: 26px; color: #ffe08a; }
.lrFinalPts small{ font-size: 12px; opacity: .7; margin-left: 3px; font-family: inherit; }

.lrTotal{ display: flex; flex-wrap: wrap; gap: 6px; align-items: center; justify-content: center; padding-top: 4px; }
.lrTotalLabel{ font-size: 11px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .65; margin-right: 4px; }
.lrTotalChip{ padding: 4px 11px; border-radius: 999px; font-size: 13px; font-weight: 800; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); }
.lrTotalChip b{ color: #ffe08a; margin-left: 4px; }
.lrTotalChip.me{ border-color: rgba(120,220,255,.6); }
@keyframes lrPop{ from{ opacity: 0; transform: translateY(-10px) scale(.85); } }
@media (max-width: 640px){
  .lrCell{ font-size: 72px; }
  .lrReelWrap{ height: 130px; }
  .lrLetter{ width: 70px; height: 70px; font-size: 48px; border-radius: 20px; }
  .lrTask{ padding: 10px 12px; gap: 12px; }
  .lrTaskText h1{ font-size: 24px; }
  .lrTimer{ font-size: 30px; min-width: 52px; }
  .lrInput{ font-size: 17px; padding: 13px 14px; }
  .lrVoteGrid{ grid-template-columns: 1fr; gap: 8px; }
  .lrVoteCard{ min-height: 0; grid-template-columns: auto auto 1fr auto; padding: 12px 14px 12px 40px; justify-items: start; text-align: left; }
  .lrVoteName{ text-align: left; }
  .lrMap{ --rh: 42px; }
  .lrW{ font-size: 13px; padding: 4px 10px; }
  .lrSkip{ right: 70px; }
}
@media (prefers-reduced-motion: reduce){ .lrCell.hit, .lrW, .lrVotes.rise, .lrBig, .lrRollTitle, .lrFinal li, .lrCrown{ animation: none !important; } .lrW.go{ transition: none; } }
`;
