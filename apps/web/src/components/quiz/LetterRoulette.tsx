"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { gameModeInfo } from "@/lib/gameModes";
import { serverNow } from "@/lib/serverClock";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { AudioControl } from "@/components/AudioControl";
import { playFx } from "@/lib/gameFx";
import { useQuiz, type QuizLobby, type QuizPlayer } from "@/components/quiz/useQuiz";

const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
const ITEM = 104; // Breite eines Buchstabens auf der Walze (px)
const REPEATS = 7; // Walze besteht aus 7x A–Z, der Zielbuchstabe liegt in der vorletzten Wiederholung
const SPIN_MS = 5600;

type CatInfo = { id: string; name: string };
type ResultRow = { playerId: string; name: string; points: number; valid: string[]; bad: string[]; dup: string[] };

/**
 * ROULETTE – Buchstabe + drei Kategorien (Migration 127).
 * Ablauf: Die Walze läuft von A bis Z und bleibt bei einem Buchstaben stehen, drei Kategorien werden enthüllt. Pro Kategorie
 * tippt jeder 45 Sekunden lang so viele passende Begriffe wie möglich (jeder sieht nur die eigenen). Danach: eigene Liste
 * grün/rot, dann die Rangliste von unten (wenigste Begriffe) nach oben.
 */
export function LetterRoulette({ lobby, players, mePlayerId, onToast }: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (m: string, ms?: number) => void }) {
    const { tr } = useI18n();
    const q = useQuiz({ lobby, mePlayerId, onToast });
    const info = gameModeInfo("letters");
    const state = lobby.quiz_state;
    const opts = lobby.quiz_options ?? {};
    const letter = String(opts.letter ?? "A").toUpperCase();
    const cats = useMemo(() => ((opts.cats as CatInfo[] | undefined) ?? []).slice(0, 3), [opts.cats]);
    const idx = Math.max(0, lobby.quiz_index); // 1..3 während der Kategorien
    const cat = cats[idx - 1] ?? null;
    const me = players.find((p) => p.player_id === mePlayerId) ?? null;
    const reveal = lobby.quiz_reveal as { letter?: string; category?: string; index?: number; results?: ResultRow[] } | null;
    const rows = useMemo(() => reveal?.results ?? [], [reveal]);

    // ---------------- Walze (spin) ----------------
    // Wer mitten im Roulette dazukommt, sieht gleich das Ergebnis
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
    const reelStyle = {
        transform: `translateX(${-(target + 0.5) * ITEM}px)`,
        transition: go && !landed ? `transform ${Math.max(300, SPIN_MS - elapsed)}ms cubic-bezier(.12,.72,.14,1)` : "none",
    };
    const startX = `${-0.5 * ITEM}px`;
    // Tick-Töne beim Drehen (ein paar, die langsamer werden)
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

    // ---------------- Eingabe (question) ----------------
    // Eigene Eingaben gehören zur Frage (neue Kategorie = leer); beim Neuladen kommen sie vom Server
    const [localState, setLocal] = useState<{ seq: number; list: string[] }>({ seq: -1, list: [] });
    const serverMine = q.status?.mine;
    const entries = useMemo(() => {
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
        if (entries.some((x) => x.toLowerCase() === t.toLowerCase())) {
            onToast(tr("Das hast du schon eingegeben."), 1400);
            return;
        }
        setLocal((s) => ({ seq: lobby.quiz_seq, list: [t, ...(s.seq === lobby.quiz_seq ? s.list : [])] }));
        playFx("vote");
        const ok = await q.submitTerm(t);
        if (!ok) setLocal((s) => ({ seq: s.seq, list: s.list.filter((x) => x !== t) }));
    }, [text, canType, iAmDone, entries, lobby.quiz_seq, onToast, tr, q]);

    // ---------------- Auflösung (reveal) ----------------
    const mine = rows.find((r) => r.playerId === mePlayerId) ?? null;
    const [open, setOpen] = useState<string | null>(null);
    const total = (id: string) => Number(players.find((p) => p.player_id === id)?.song_points ?? 0);
    const ranked = useMemo(() => [...players].sort((a, b) => Number(b.song_points ?? 0) - Number(a.song_points ?? 0) || a.name.localeCompare(b.name)), [players]);
    const best = rows.length ? Math.max(...rows.map((r) => r.points)) : 0;

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
                {idx > 0 ? (
                    <span className="lrCount">
                        {tr("Kategorie {i} von {n}", { i: Math.min(idx, 3), n: 3 })}
                        {lobby.series_total > 1 ? ` · ${tr("Runde {i}/{n}", { i: lobby.series_index, n: lobby.series_total })}` : ""}
                    </span>
                ) : null}
            </header>

            <div className="lrBar" aria-hidden>
                <div className={`lrBarFill ${q.left < 8 && state === "question" ? "hot" : ""}`} style={{ transform: `scaleX(${state === "spin" ? 0 : q.ratio})` }} />
            </div>

            {/* ---------- Roulette ---------- */}
            {state === "spin" || !state ? (
                <section className="lrSpin" key={`spin:${lobby.quiz_seq}`}>
                    <div className="lrKick">{tr("Das Roulette entscheidet …")}</div>
                    <div className="lrReelWrap">
                        <div className="lrPointer" aria-hidden>
                            ▼
                        </div>
                        <div className="lrReel" style={{ transform: go || landed ? reelStyle.transform : `translateX(${startX})`, transition: reelStyle.transition }}>
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
                    <div className={`lrCats ${elapsed > SPIN_MS - 200 || landed ? "show" : ""}`}>
                        {cats.map((c, i) => (
                            <div key={c.id} className="lrCatCard" style={{ ["--i" as string]: i }}>
                                <span className="lrCatNo">{i + 1}</span>
                                <b>{c.name}</b>
                            </div>
                        ))}
                    </div>
                    <CatsReveal show={!landed && elapsed <= SPIN_MS - 200} ms={SPIN_MS - elapsed} />
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
                                <b>{entries.length}</b> {entries.length === 1 ? tr("Begriff") : tr("Begriffe")}
                                <button type="button" className="btn btnSecondary btnSmall lrDone" onClick={() => void q.finishTerms()} disabled={iAmDone || q.busy}>
                                    {iAmDone ? tr("✓ Fertig") : tr("Fertig ✓")}
                                </button>
                            </div>
                            <ul className="lrStack" aria-label={tr("Deine Eingaben")}>
                                {entries.map((e, i) => (
                                    <li key={`${e}:${entries.length - i}`} className={i === 0 ? "new" : ""}>
                                        {e}
                                    </li>
                                ))}
                            </ul>
                        </>
                    ) : (
                        <div className="lrWatch">{tr("Du schaust zu.")}</div>
                    )}

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

            {/* ---------- Auflösung ---------- */}
            {state === "reveal" && reveal ? (
                <section className="lrReveal" key={`r:${lobby.quiz_seq}`}>
                    <div className="lrRevHead">
                        <div className="lrLetter small">{String(reveal.letter ?? letter)}</div>
                        <div>
                            <small>{tr("Auflösung")}</small>
                            <h2>{String(reveal.category ?? "")}</h2>
                        </div>
                    </div>

                    {me ? (
                        <div className="lrMine">
                            <div className="lrMineHead">
                                {tr("Deine Liste")} · <b>{mine?.points ?? 0}</b> {tr("richtig")}
                            </div>
                            <div className="lrWords">
                                {(mine?.valid ?? []).map((w, i) => (
                                    <span key={`v${i}`} className="lrWord ok" style={{ ["--i" as string]: i }}>
                                        ✓ {w}
                                    </span>
                                ))}
                                {(mine?.dup ?? []).map((w, i) => (
                                    <span key={`d${i}`} className="lrWord dup" style={{ ["--i" as string]: (mine?.valid.length ?? 0) + i }} title={tr("doppelt – zählt nur einmal")}>
                                        ＝ {w}
                                    </span>
                                ))}
                                {(mine?.bad ?? []).map((w, i) => (
                                    <span key={`b${i}`} className="lrWord bad" style={{ ["--i" as string]: (mine?.valid.length ?? 0) + (mine?.dup.length ?? 0) + i }}>
                                        ✗ {w}
                                    </span>
                                ))}
                                {!mine || (mine.valid.length === 0 && mine.bad.length === 0 && mine.dup.length === 0) ? <span className="lrNone">{tr("Diesmal nichts eingegeben.")}</span> : null}
                            </div>
                        </div>
                    ) : null}

                    <div className="lrRank">
                        <div className="lrRankHead">{tr("Rangliste – von unten nach oben")}</div>
                        <ol className="lrRankList">
                            {/* rows kommt aufsteigend (Letzter zuerst); angezeigt wird oben der Sieger, die Einblendung läuft aber vom Letzten */}
                            {[...rows].reverse().map((r, i) => {
                                const fromBottom = rows.length - 1 - i;
                                const win = r.points === best && best > 0;
                                const p = players.find((x) => x.player_id === r.playerId);
                                return (
                                    <li
                                        key={r.playerId}
                                        className={`lrRankRow ${win ? "win" : ""} ${r.playerId === mePlayerId ? "me" : ""} ${open === r.playerId ? "open" : ""}`}
                                        style={{ ["--d" as string]: `${3.2 + fromBottom * 1.15}s` }}
                                    >
                                        <button type="button" className="lrRankBtn" onClick={() => setOpen((o) => (o === r.playerId ? null : r.playerId))} aria-expanded={open === r.playerId}>
                                            <span className="lrPlace">{i + 1}</span>
                                            {p ? <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={34} /> : null}
                                            <span className="lrRankName">
                                                {r.name}
                                                {win ? " 👑" : ""}
                                            </span>
                                            <span className="lrRankBar" aria-hidden>
                                                <i style={{ width: `${best ? Math.max(6, (r.points / best) * 100) : 6}%` }} />
                                            </span>
                                            <span className="lrRankPts">{r.points}</span>
                                        </button>
                                        {open === r.playerId ? (
                                            <div className="lrRankWords">
                                                {r.valid.length ? r.valid.join(" · ") : tr("Keine richtigen Begriffe.")}
                                            </div>
                                        ) : null}
                                    </li>
                                );
                            })}
                        </ol>
                    </div>

                    <div className="lrTotal" aria-label={tr("Gesamtstand")}>
                        <span className="lrTotalLabel">{tr("Gesamt")}</span>
                        {ranked.map((p) => (
                            <span key={p.player_id} className={`lrTotalChip ${p.player_id === mePlayerId ? "me" : ""}`}>
                                {p.name} <b>{total(p.player_id)}</b>
                            </span>
                        ))}
                    </div>
                </section>
            ) : null}

            <style>{STYLES}</style>
        </main>
    );
}

/** Kleiner Helfer: blendet die Kategorien erst am Ende der Walzen-Animation ein (auch ohne Neuzeichnen von außen) */
function CatsReveal({ show, ms }: { show: boolean; ms: number }) {
    const [, force] = useState(0);
    useEffect(() => {
        if (!show) return;
        const t = window.setTimeout(() => force((n) => n + 1), Math.max(0, ms) + 50);
        return () => window.clearTimeout(t);
    }, [show, ms]);
    return null;
}

const STYLES = `
.lrMain{ min-height: 100dvh; color: #fff; display: flex; flex-direction: column; gap: 10px; padding: 12px 14px 22px; position: relative; overflow-x: hidden;
  background: radial-gradient(ellipse 60% 45% at 50% -8%, rgba(255,205,90,.28), transparent 70%), radial-gradient(ellipse 50% 60% at 8% 35%, rgba(255,60,120,.16), transparent 70%),
              radial-gradient(ellipse 50% 60% at 92% 35%, rgba(70,200,255,.14), transparent 70%), linear-gradient(180deg, #2a0f3c 0%, #1a0a2a 55%, #0e0618 100%); }
.lrTopRight{ position: fixed; top: 14px; right: 14px; z-index: 30; }
.lrHead{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 0 64px 0 128px; min-height: 40px; }
@media (max-width: 640px){ .lrHead{ padding-left: 52px; } }
.lrMode{ font-family: var(--font-display); font-weight: 900; font-size: clamp(20px, 3vw, 28px); }
.lrGoal{ font-size: 12.5px; font-weight: 850; color: #ffe08a; padding: 4px 11px; border-radius: 999px; background: rgba(255,210,63,.12); border: 1px solid rgba(255,210,63,.35); }
.lrCount{ margin-left: auto; font-size: 13px; font-weight: 800; opacity: .8; }
.lrBar{ height: 8px; border-radius: 999px; background: rgba(255,255,255,.1); overflow: hidden; }
.lrBarFill{ height: 100%; transform-origin: left center; transition: transform .25s linear; background: linear-gradient(90deg, #ffd23f, #ff9d2e); }
.lrBarFill.hot{ background: linear-gradient(90deg, #ff6a3c, #ff2e4a); }

/* Walze */
.lrSpin{ display: grid; justify-items: center; align-content: center; gap: 22px; flex: 1; padding: 10px 0; }
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
.lrCats{ display: flex; gap: 12px; flex-wrap: wrap; justify-content: center; min-height: 86px; opacity: 0; transform: translateY(14px); transition: opacity .4s ease, transform .4s ease; }
.lrCats.show{ opacity: 1; transform: none; }
.lrCatCard{ display: flex; align-items: center; gap: 12px; padding: 14px 22px; border-radius: 20px; background: linear-gradient(160deg, rgba(255,210,63,.2), rgba(255,80,140,.12)); border: 2px solid rgba(255,210,63,.55);
  font-size: clamp(18px, 2.6vw, 26px); animation: lrCard .6s cubic-bezier(.2,1.5,.4,1) both; animation-delay: calc(var(--i) * .22s); }
.lrCats:not(.show) .lrCatCard{ animation: none; }
.lrCatNo{ width: 34px; height: 34px; border-radius: 50%; display: grid; place-items: center; background: #ffd23f; color: #2a1200; font-weight: 900; }
@keyframes lrCard{ from{ opacity: 0; transform: rotateX(80deg) scale(.8); } to{ opacity: 1; transform: none; } }

/* Eingabe */
.lrPlay{ display: grid; grid-template-columns: minmax(0, 1fr); gap: 12px; align-content: start; width: min(760px, 100%); margin: 0 auto; flex: 1; animation: lrIn .4s cubic-bezier(.16,1,.3,1); }
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
.lrStack{ list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; }
.lrStack li{ padding: 8px 14px; border-radius: 999px; font-weight: 800; font-size: 15px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.2); animation: lrPop .35s cubic-bezier(.2,1.6,.4,1); }
.lrStack li.new{ background: rgba(255,210,63,.2); border-color: rgba(255,210,63,.6); }
@keyframes lrPop{ from{ opacity: 0; transform: translateY(-10px) scale(.85); } }
.lrWatch{ text-align: center; font-weight: 800; opacity: .8; padding: 22px 0; }
.lrOthers{ display: flex; gap: 6px; flex-wrap: wrap; justify-content: center; margin-top: 4px; }
.lrChip{ display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px 4px 5px; border-radius: 999px; font-size: 12.5px; font-weight: 800; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); opacity: .85; }
.lrChip.done{ background: rgba(60,200,120,.2); border-color: rgba(100,230,150,.5); opacity: 1; }

/* Auflösung */
.lrReveal{ display: grid; grid-template-columns: minmax(0, 1fr); gap: 14px; align-content: start; width: min(820px, 100%); margin: 0 auto; flex: 1; animation: lrIn .4s cubic-bezier(.16,1,.3,1); }
.lrRevHead{ display: flex; align-items: center; gap: 14px; }
.lrRevHead small{ font-size: 11px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; opacity: .7; }
.lrRevHead h2{ margin: 0; font-size: clamp(24px, 4vw, 36px); }
.lrMine{ padding: 12px 14px; border-radius: 20px; background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.14); display: grid; gap: 8px; }
.lrMineHead{ font-weight: 800; font-size: 14px; }
.lrMineHead b{ color: #8dffb8; font-family: var(--font-display); font-size: 20px; }
.lrWords{ display: flex; flex-wrap: wrap; gap: 7px; }
.lrWord{ padding: 6px 12px; border-radius: 999px; font-weight: 800; font-size: 14px; border: 1px solid; animation: lrWord .45s cubic-bezier(.2,1.5,.4,1) both; animation-delay: calc(var(--i, 0) * .09s); }
.lrWord.ok{ background: rgba(20,120,70,.55); border-color: rgba(90,230,150,.7); color: #d6ffe6; }
.lrWord.bad{ background: rgba(140,26,22,.55); border-color: rgba(255,100,88,.7); color: #ffd6d1; }
.lrWord.dup{ background: rgba(150,100,20,.5); border-color: rgba(255,200,90,.6); color: #ffe9bd; }
.lrNone{ opacity: .7; font-weight: 700; }
@keyframes lrWord{ from{ opacity: 0; transform: scale(.7); } }
.lrRank{ display: grid; gap: 8px; }
.lrRankHead{ font-size: 12px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .7; }
.lrRankList{ list-style: none; margin: 0; padding: 0; display: grid; gap: 7px; }
.lrRankRow{ border-radius: 18px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.14); opacity: 0; transform: translateY(18px) scale(.96); animation: lrRank .6s cubic-bezier(.2,1.4,.4,1) both; animation-delay: var(--d); }
@keyframes lrRank{ to{ opacity: 1; transform: none; } }
.lrRankRow.win{ background: linear-gradient(160deg, rgba(255,210,63,.3), rgba(255,140,40,.14)); border-color: #ffd23f; box-shadow: 0 0 30px rgba(255,210,63,.3); }
.lrRankRow.me{ outline: 2px solid rgba(120,220,255,.6); }
.lrRankBtn{ width: 100%; display: flex; align-items: center; gap: 10px; padding: 9px 14px; border: 0; background: none; color: inherit; font: inherit; text-align: left; cursor: pointer; }
.lrPlace{ flex: none; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 13px; background: rgba(255,255,255,.14); }
.lrRankName{ font-weight: 900; font-size: 16px; min-width: 90px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.lrRankBar{ flex: 1; height: 10px; border-radius: 999px; background: rgba(255,255,255,.1); overflow: hidden; min-width: 40px; }
.lrRankBar i{ display: block; height: 100%; border-radius: 999px; background: linear-gradient(90deg, #ffd23f, #ff9d2e); }
.lrRankPts{ flex: none; min-width: 34px; text-align: right; font-family: var(--font-display); font-weight: 900; font-size: 24px; color: #ffe08a; }
.lrRankWords{ padding: 0 14px 12px 50px; font-size: 13.5px; opacity: .9; line-height: 1.5; }
.lrTotal{ display: flex; flex-wrap: wrap; gap: 6px; align-items: center; justify-content: center; padding-top: 4px; }
.lrTotalLabel{ font-size: 11px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .65; margin-right: 4px; }
.lrTotalChip{ padding: 4px 11px; border-radius: 999px; font-size: 13px; font-weight: 800; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); }
.lrTotalChip b{ color: #ffe08a; margin-left: 4px; }
.lrTotalChip.me{ border-color: rgba(120,220,255,.6); }
@media (max-width: 640px){
  .lrCell{ font-size: 72px; }
  .lrReelWrap{ height: 130px; }
  .lrLetter{ width: 70px; height: 70px; font-size: 48px; border-radius: 20px; }
  .lrTask{ padding: 10px 12px; gap: 12px; }
  .lrTaskText h1{ font-size: 24px; }
  .lrTimer{ font-size: 30px; min-width: 52px; }
  .lrInput{ font-size: 17px; padding: 13px 14px; }
  .lrRankBar{ display: none; }
}
@media (prefers-reduced-motion: reduce){ .lrCell.hit, .lrCatCard, .lrStack li, .lrWord, .lrRankRow{ animation: none !important; opacity: 1; transform: none; } }
`;
