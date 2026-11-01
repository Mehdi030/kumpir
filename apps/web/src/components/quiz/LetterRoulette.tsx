"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { gameModeInfo } from "@/lib/gameModes";
import { serverNow } from "@/lib/serverClock";
import { AudioControl } from "@/components/AudioControl";
import { playFx, playHeartbeat } from "@/lib/gameFx";
import { useQuiz, type QuizLobby, type QuizPlayer } from "@/components/quiz/useQuiz";
import { STYLES } from "@/components/quiz/letterRouletteStyles";
import { Podia, SlotReel, TimerRing, VoteCards } from "@/components/quiz/RouletteParts";
import { WordMap } from "@/components/quiz/WordMap";
import { MissedBox, RankShow } from "@/components/quiz/RankShow";
import { MAP_S_DEFAULT, showSeconds, type Appeal, type CatInfo, type ResultRow, type Word } from "@/components/quiz/rouletteShared";

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
    const reveal = lobby.quiz_reveal as { letter?: string; category?: string; index?: number; last?: boolean; mapSecs?: number; missed?: string[]; results?: ResultRow[] } | null;
    const MAP_S = Number(reveal?.mapSecs ?? MAP_S_DEFAULT);
    const rows = useMemo(() => reveal?.results ?? [], [reveal]);
    const humans = players.filter((p) => !p.is_bot).length;

    // Takt (für Show und Stufen), 250 ms
    const [, setBeat] = useState(0);
    useEffect(() => {
        const t = window.setInterval(() => setBeat((n) => n + 1), 250);
        return () => window.clearInterval(t);
    }, []);

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
    // Zeitdruck: in den letzten 10 Sekunden schlägt ein Herzschlag (immer schneller) und der Rand pulsiert rot
    const pressure = state === "question" && !iAmDone && q.left <= 10 && q.left > 0;
    const panic = pressure && q.left <= 3.5;
    const leftRef = useRef(q.left);
    useEffect(() => {
        leftRef.current = q.left;
    });
    useEffect(() => {
        if (!pressure) return;
        let t = 0;
        const beat = () => {
            const l = leftRef.current;
            playHeartbeat(Math.max(0, Math.min(1, (10 - l) / 10)));
            t = window.setTimeout(beat, l > 6 ? 1000 : l > 3.5 ? 760 : 520);
        };
        beat();
        return () => window.clearTimeout(t);
    }, [pressure]);
    const doneSet = useMemo(() => new Set(q.status?.done ?? []), [q.status]);
    useEffect(() => {
        if (canType) inputRef.current?.focus();
    }, [canType, lobby.quiz_seq]);

    const add = async () => {
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
    };

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
        <main className={`fullH lrMain ${pressure ? "pressure" : ""} ${panic ? "panic" : ""}`}>
            <div className="lrTopRight">
                <AudioControl />
            </div>

            <header className="lrHead">
                <span className="lrMode">
                    {info.icon} {tr(info.label)}
                </span>
                <span className="lrGoal">🎯 {tr(info.goal)}</span>
                {idx > 0 || state === "vote" || state === "spin" ? (
                    <span className="lrCount">
                        {tr("Kategorie {i} von {n}", { i: Math.min(state === "vote" || state === "spin" ? idx + 1 : Math.max(1, idx), total), n: total })}
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
                    <div className="lrKick">{idx > 0 ? tr("Neuer Buchstabe, neue Themen …") : tr("Das Roulette entscheidet …")}</div>
                    <SlotReel key={lobby.quiz_seq} letter={letter} startedAt={lobby.quiz_started_at} />
                    <VoteCards key={`vc:${lobby.quiz_seq}`} cands={cands} tally={tally} myVote={myVote} canVote={canVote} onVote={vote} votedCount={votedCount} humans={humans} intro={lobby.quiz_started_at} />
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
                    {reveal.missed?.length ? <MissedBox missed={reveal.missed} /> : null}
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
                    missed={showStage === 1 ? reveal?.missed ?? [] : []}
                />
            ) : null}

            <style>{STYLES}</style>
        </main>
    );
}

