"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { gameModeInfo } from "@/lib/gameModes";
import { SongRound } from "@/components/game/SongRound";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { AudioControl } from "@/components/AudioControl";
import { pts, useQuiz, type QuizLobby, type QuizPlayer, type RevealResult } from "@/components/quiz/useQuiz";

/**
 * BUZZER – Game-Show-Arena (Migration 118).
 * Ziel: Wer zuerst 10 Punkte hat, gewinnt. Aufstellung: Pulte nebeneinander am unteren Rand, jedes Pult WÄCHST mit den
 * Punkten bis zum Zielstrich. In der Mitte dreht sich die Schallplatte, darunter der große Buzzer.
 */
/** Eingabefeld für den, der gebuzzert hat – fokussiert sofort; gehört zur Frage (key), startet also immer leer. */
function AnswerForm({ busy, onSubmit }: { busy: boolean; onSubmit: (text: string) => Promise<boolean> }) {
    const { tr } = useI18n();
    const [text, setText] = useState("");
    const ref = useRef<HTMLInputElement | null>(null);
    useEffect(() => {
        ref.current?.focus();
    }, []);
    return (
        <form
            className="bzForm"
            onSubmit={(e) => {
                e.preventDefault();
                const a = text.trim();
                if (!a) return;
                setText("");
                // Klappt es nicht (Netz), kommt der Text zurück ins Feld
                void onSubmit(a).then((ok) => {
                    if (!ok) setText(a);
                });
            }}
        >
            <input
                ref={ref}
                className="bzInput"
                value={text}
                onChange={(e) => setText(e.target.value)}
                placeholder={tr("Songtitel oder Künstler …")}
                maxLength={60}
                autoComplete="off"
                autoCorrect="off"
                spellCheck={false}
                enterKeyHint="send"
            />
            <button type="submit" className="btn btnPrimary" disabled={busy || !text.trim()}>
                {tr("Antworten")}
            </button>
        </form>
    );
}

export function BuzzerArena({ lobby, players, mePlayerId, onToast }: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (m: string, ms?: number) => void }) {
    const { tr } = useI18n();
    const q = useQuiz({ lobby, mePlayerId, onToast });
    const info = gameModeInfo("buzzer");
    const state = lobby.quiz_state;
    const target = lobby.quiz_target ?? 10;
    const me = players.find((p) => p.player_id === mePlayerId) ?? null;
    const locked = useMemo(() => new Set(lobby.quiz_locked ?? []), [lobby.quiz_locked]);
    const buzzerId = state === "buzzed" ? lobby.quiz_picker : null;
    const iAmBuzzer = !!me && buzzerId === me.player_id;
    const lockedOut = !!me && locked.has(me.player_id);
    const canBuzz = state === "question" && !!me && !lockedOut;
    const nameOf = useCallback((id: unknown) => players.find((p) => p.player_id === id)?.name ?? "…", [players]);
    const reveal = lobby.quiz_reveal;
    const results = ((reveal?.results as RevealResult[] | undefined) ?? []).filter((r) => Number(r.points) > 0);
    const winner = results[0] ?? null;
    const goalId = (reveal?.goal as string | null | undefined) ?? null;

    // Fensterhöhe: die Pulte wachsen mit dem Bildschirm
    const [view, setView] = useState(() => (typeof window === "undefined" ? { w: 1024, h: 780 } : { w: window.innerWidth, h: window.innerHeight }));
    const vh = view.h;
    const phone = view.w < 640;
    useEffect(() => {
        const on = () => setView({ w: window.innerWidth, h: window.innerHeight });
        window.addEventListener("resize", on);
        return () => window.removeEventListener("resize", on);
    }, []);

    // Rückmeldung gehört zur Frage (neue Frage = weg)
    const [feedbackState, setFeedback] = useState<{ text: string; nonce: number; seq: number } | null>(null);
    const feedback = feedbackState && feedbackState.seq === lobby.quiz_seq ? feedbackState : null;

    // Leertaste / Enter = Buzzer
    useEffect(() => {
        const onKey = (ev: KeyboardEvent) => {
            const tag = (ev.target as HTMLElement | null)?.tagName;
            if (tag === "INPUT" || tag === "TEXTAREA") return;
            if (canBuzz && (ev.key === " " || ev.key === "Enter")) {
                ev.preventDefault();
                void q.buzz();
            }
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [canBuzz, q]);

    const submit = useCallback(
        async (a: string) => {
            const res = await q.answer(a);
            if (res && !res.correct) setFeedback({ text: tr("Leider falsch – du bist für diesen Song raus."), nonce: Date.now(), seq: lobby.quiz_seq });
            return res !== null;
        },
        [q, tr, lobby.quiz_seq]
    );

    const songPlaying = state === "question" || state === "buzzed" || state === "reveal";
    const ringState = state === "buzzed" ? "answer" : state === "reveal" ? "reveal" : "ask";
    const R = 118;
    const C = 2 * Math.PI * R;

    // Pultgröße: Basis + bis zum Zielstrich
    const narrow = players.length > 8;
    const H = phone ? Math.max(80, Math.min(140, Math.round(vh * 0.17))) : narrow ? Math.min(130, Math.round(vh * 0.2)) : Math.max(110, Math.min(240, Math.round(vh * 0.27)));
    const BASE = phone || narrow ? 54 : 64;
    const buzzerPlayer = players.find((p) => p.player_id === buzzerId) ?? null;

    return (
        <main className="fullH bzMain">
            {songPlaying ? <SongRound songId={lobby.current_song_id} startedAt={lobby.current_song_started_at} /> : null}
            <div className="bzTopRight">
                <AudioControl />
            </div>

            <header className="bzHead">
                <span className="bzMode">
                    {info.icon} {tr(info.label)}
                </span>
                <span className="bzGoal">🎯 {tr(info.goal)}</span>
                <span className="bzCount">
                    {tr("Song {i}", { i: Math.max(1, lobby.quiz_index) })}
                    {lobby.series_total > 1 ? ` · ${tr("Runde {i}/{n}", { i: lobby.series_index, n: lobby.series_total })}` : ""}
                </span>
            </header>

            {/* ---------- Bühne: Schallplatte + Buzzer ---------- */}
            <section className="bzStage" aria-live="polite">
                <div className={`bzDisc ${ringState} ${state === "reveal" ? "slow" : ""}`}>
                    <svg className="bzRing" viewBox="0 0 260 260" aria-hidden>
                        <circle cx="130" cy="130" r={R} className="bzRingBg" />
                        <circle cx="130" cy="130" r={R} className="bzRingFg" strokeDasharray={C} strokeDashoffset={C * (1 - q.ratio)} transform="rotate(-90 130 130)" />
                    </svg>
                    <div className="bzVinyl">
                        <div className="bzLabel">
                            {buzzerPlayer ? (
                                <PlayerAvatar seed={buzzerPlayer.name} config={buzzerPlayer.avatar_config ?? null} size={64} />
                            ) : (
                                <span className="bzNote">♪</span>
                            )}
                        </div>
                    </div>
                    {songPlaying && state !== "reveal" ? (
                        <div className="bzEq" aria-hidden>
                            {Array.from({ length: 5 }).map((_, i) => (
                                <i key={i} style={{ ["--d" as string]: `${i * 0.13}s` }} />
                            ))}
                        </div>
                    ) : null}
                </div>

                <div className="bzTalk" key={`${lobby.quiz_seq}:${state}:${buzzerId ?? ""}`}>
                    {state === "question" ? (
                        <>
                            <div className="bzTitle">{lockedOut ? tr("🔒 Du bist für diesen Song raus") : tr("Erkennst du den Song?")}</div>
                            <div className="bzSub">
                                {!me ? tr("Du schaust zu.") : lockedOut ? tr("Warte, bis die anderen fertig sind.") : tr("Wer zuerst buzzert, darf antworten.")}
                            </div>
                            {canBuzz ? (
                                <button type="button" className="bzButton" onClick={() => void q.buzz()} disabled={q.busy} aria-label={tr("Buzzer")}>
                                    <span>{tr("BUZZ!")}</span>
                                    <small>{tr("Leertaste")}</small>
                                </button>
                            ) : null}
                        </>
                    ) : state === "buzzed" ? (
                        iAmBuzzer ? (
                            <>
                                <div className="bzTitle">{tr("Los – Titel oder Künstler!")}</div>
                                <AnswerForm key={lobby.quiz_seq} busy={q.busy} onSubmit={submit} />
                            </>
                        ) : (
                            <>
                                <div className="bzTitle">{tr("🔔 {name} hat gebuzzert!", { name: nameOf(buzzerId) })}</div>
                                <div className="bzSub">{tr("{name} antwortet …", { name: nameOf(buzzerId) })}</div>
                            </>
                        )
                    ) : state === "reveal" && reveal ? (
                        <>
                            <div className="bzKick">{tr("Auflösung")}</div>
                            <div className="bzSong">{String(reveal.title ?? "")}</div>
                            <div className="bzArtist">
                                {String(reveal.artist ?? "")}
                                {reveal.year ? ` · ${String(reveal.year)}` : ""}
                            </div>
                            {winner ? (
                                <div className="bzWin">
                                    🔔 {nameOf(winner.playerId)} <b>+{pts(Number(winner.points))}</b>
                                </div>
                            ) : (
                                <div className="bzSub">{tr("Diesmal hat es keiner erkannt.")}</div>
                            )}
                            {goalId ? <div className="bzGoalWin">{tr("🏆 {name} hat {n} Punkte – Sieg!", { name: nameOf(goalId), n: target })}</div> : null}
                        </>
                    ) : (
                        <div className="bzTitle">{tr("Gleich geht's los …")}</div>
                    )}
                    {feedback && state === "question" ? (
                        <div className="bzBad" key={feedback.nonce}>
                            {feedback.text}
                        </div>
                    ) : null}
                </div>
            </section>

            {/* ---------- Pulte: wachsen mit den Punkten ---------- */}
            <section className={`bzPodia ${phone ? "phone" : ""}`} style={{ ["--H" as string]: `${H}px`, ["--base" as string]: `${BASE}px` }} aria-label={tr("Punktestand")}>
                <div className="bzFinish" style={{ bottom: `${BASE + H}px` }} aria-hidden>
                    <span>🏁 {target}</span>
                </div>
                {players.map((p) => {
                    const score = Number(p.song_points ?? 0);
                    const h = BASE + Math.min(1, score / target) * H;
                    const lit = buzzerId === p.player_id;
                    const out = locked.has(p.player_id);
                    const gain = results.find((r) => r.playerId === p.player_id);
                    return (
                        <div key={p.player_id} className={`bzPod ${lit ? "lit" : ""} ${out ? "out" : ""} ${p.player_id === mePlayerId ? "me" : ""} ${goalId === p.player_id ? "champ" : ""}`}>
                            {gain && state === "reveal" ? (
                                <span className="bzGain" key={`${lobby.quiz_seq}:${p.player_id}`}>
                                    +{pts(Number(gain.points))}
                                </span>
                            ) : null}
                            {lit ? <span className="bzBell">🔔</span> : null}
                            {goalId === p.player_id ? <span className="bzCrown">👑</span> : null}
                            <div className="bzFigure">
                                <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} mood={out ? "out" : lit ? "panic" : "normal"} size={narrow ? 40 : 56} />
                            </div>
                            <div className="bzBlock" style={{ height: `${h}px` }}>
                                <span className="bzName" title={p.name}>
                                    {p.name}
                                </span>
                                <span className="bzScore">{pts(score)}</span>
                                {out ? <span className="bzLock">🔒</span> : null}
                            </div>
                        </div>
                    );
                })}
            </section>

            <style>{`
        .bzMain{ min-height: 100dvh; color: #fff; display: flex; flex-direction: column; gap: 6px; padding: 12px 14px 0; position: relative; overflow: hidden;
          background: radial-gradient(ellipse 55% 45% at 50% -5%, rgba(255,214,120,.22), transparent 70%), radial-gradient(ellipse 40% 60% at 12% 30%, rgba(255,70,140,.10), transparent 70%),
                      radial-gradient(ellipse 40% 60% at 88% 30%, rgba(90,120,255,.12), transparent 70%), linear-gradient(180deg, #1f1033 0%, #120a22 55%, #0a0614 100%); }
        .bzTopRight{ position: fixed; top: 14px; right: 14px; z-index: 30; }
        .bzHead{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding-right: 64px; }
        .bzMode{ font-family: var(--font-display); font-weight: 900; font-size: clamp(20px, 3vw, 28px); }
        .bzGoal{ padding: 6px 12px; border-radius: 999px; font-weight: 900; font-size: 13.5px; background: rgba(255,210,63,.16); border: 1px solid rgba(255,210,63,.5); color: #ffe08a; }
        .bzCount{ margin-left: auto; padding: 6px 12px; border-radius: 999px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.16); font-weight: 850; font-size: 13px; }

        .bzStage{ flex: 1; display: flex; align-items: center; justify-content: center; gap: clamp(16px, 4vw, 48px); flex-wrap: wrap; padding: 4px 0; min-height: 0; }
        .bzDisc{ position: relative; width: 260px; height: 260px; flex: none; }
        .bzRing{ position: absolute; inset: 0; width: 100%; height: 100%; }
        .bzRingBg{ fill: none; stroke: rgba(255,255,255,.12); stroke-width: 7; }
        .bzRingFg{ fill: none; stroke: #ffd23f; stroke-width: 7; stroke-linecap: round; transition: stroke-dashoffset .2s linear, stroke .3s ease; }
        .bzDisc.answer .bzRingFg{ stroke: #ff5a4a; }
        .bzDisc.reveal .bzRingFg{ stroke: #7dffa9; }
        .bzVinyl{ position: absolute; inset: 24px; border-radius: 50%; animation: bzSpin 3.2s linear infinite;
          background: repeating-radial-gradient(circle at 50% 50%, #0b0b10 0 2px, #17171f 2px 4px), conic-gradient(from 20deg, rgba(255,255,255,.10), transparent 25%, rgba(255,255,255,.08) 50%, transparent 75%, rgba(255,255,255,.10));
          background-blend-mode: screen; box-shadow: 0 14px 40px rgba(0,0,0,.55), inset 0 0 0 3px rgba(255,255,255,.06); display: grid; place-items: center; }
        .bzDisc.slow .bzVinyl, .bzDisc.slow .bzLabel{ animation-duration: 14s; }
        .bzLabel{ width: 38%; aspect-ratio: 1; border-radius: 50%; display: grid; place-items: center; background: radial-gradient(circle at 40% 35%, #ffe08a, #ff9d2e 70%); box-shadow: inset 0 0 0 3px rgba(0,0,0,.18); animation: bzSpin 3.2s linear infinite reverse; overflow: hidden; }
        .bzLabel img{ width: 100%; height: 100%; }
        .bzNote{ font-size: 40px; color: #3a1d00; font-weight: 900; }
        @keyframes bzSpin{ to{ transform: rotate(360deg); } }
        .bzEq{ position: absolute; left: 50%; bottom: -6px; transform: translateX(-50%); display: flex; gap: 4px; align-items: flex-end; height: 26px; }
        .bzEq i{ width: 6px; height: 100%; border-radius: 3px; background: linear-gradient(180deg, #ffe08a, #ff8a3c); transform-origin: bottom; animation: bzEq .7s ease-in-out infinite alternate; animation-delay: var(--d); }
        @keyframes bzEq{ from{ transform: scaleY(.2); } to{ transform: scaleY(1); } }

        .bzTalk{ display: grid; gap: 10px; justify-items: center; text-align: center; max-width: 440px; min-width: min(300px, 100%); animation: bzIn .35s cubic-bezier(.16,1,.3,1); }
        @keyframes bzIn{ from{ opacity: 0; transform: translateY(10px) scale(.98); } }
        .bzTitle{ font-family: var(--font-display); font-weight: 900; font-size: clamp(22px, 3.4vw, 34px); overflow-wrap: anywhere; }
        .bzSub{ opacity: .85; font-weight: 750; }
        .bzKick{ font-size: 12px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; opacity: .7; }
        .bzSong{ font-family: var(--font-display); font-weight: 900; font-size: clamp(26px, 4vw, 42px); overflow-wrap: anywhere; animation: bzPop .45s ease-out; }
        @keyframes bzPop{ 0%{ transform: scale(.85); opacity: 0; } 70%{ transform: scale(1.05); opacity: 1; } 100%{ transform: scale(1); } }
        .bzArtist{ font-weight: 850; opacity: .9; }
        .bzWin{ padding: 8px 16px; border-radius: 14px; background: rgba(125,255,169,.16); border: 1px solid rgba(125,255,169,.5); font-weight: 850; font-size: 18px; }
        .bzWin b{ color: #7dffa9; }
        .bzGoalWin{ padding: 9px 16px; border-radius: 14px; font-weight: 950; background: linear-gradient(90deg, rgba(255,210,63,.3), rgba(255,140,40,.25)); border: 1px solid #ffd23f; color: #ffe08a; animation: bzPop .5s ease-out; }
        .bzBad{ color: #ffb3a6; font-weight: 850; animation: bzIn .25s ease-out; }

        .bzButton{ width: 170px; height: 170px; border-radius: 50%; border: 6px solid rgba(255,255,255,.35); cursor: pointer; display: grid; place-content: center; gap: 0; color: #fff;
          background: radial-gradient(circle at 35% 30%, #ff8a6b, #e0261b 60%, #9c120b); box-shadow: 0 12px 0 #6d0b06, 0 22px 44px rgba(0,0,0,.45); transition: transform .08s, box-shadow .08s; }
        .bzButton span{ font-family: var(--font-display); font-weight: 900; font-size: 38px; line-height: 1; }
        .bzButton small{ font-size: 11px; font-weight: 800; opacity: .8; letter-spacing: 1px; text-transform: uppercase; }
        .bzButton:hover:not(:disabled){ filter: brightness(1.08); }
        .bzButton:active:not(:disabled){ transform: translateY(9px); box-shadow: 0 3px 0 #6d0b06, 0 8px 20px rgba(0,0,0,.45); }
        .bzForm{ display: flex; gap: 8px; width: min(420px, 100%); }
        .bzInput{ flex: 1; min-width: 0; height: 52px; border-radius: 14px; border: 2px solid #ff5a4a; background: rgba(0,0,0,.35); color: #fff; font-size: 18px; font-weight: 800; padding: 0 14px; outline: none; box-shadow: 0 0 0 4px rgba(255,90,74,.2); }

        /* Pulte */
        .bzPodia{ position: relative; display: flex; align-items: flex-end; justify-content: center; gap: clamp(4px, 1vw, 12px); padding: 0 0 0; margin: 0 -14px; padding-inline: 14px;
          min-height: calc(var(--base) + var(--H) + 92px); padding-bottom: 10px; }
        .bzFinish{ position: absolute; left: 0; right: 0; height: 0; border-top: 2px dashed rgba(255,210,63,.65); z-index: 1; pointer-events: none; }
        .bzFinish span{ position: absolute; right: 12px; top: -26px; padding: 2px 10px; border-radius: 999px; background: rgba(255,210,63,.18); border: 1px solid rgba(255,210,63,.6); color: #ffe08a; font-weight: 900; font-size: 12.5px; }
        .bzPod{ position: relative; flex: 1 1 0; max-width: 104px; min-width: 0; display: flex; flex-direction: column; align-items: center; z-index: 2; }
        .bzFigure{ position: relative; z-index: 2; margin-bottom: -4px; transition: transform .3s ease, filter .3s ease; }
        .bzFigure img{ display: block; filter: drop-shadow(0 6px 8px rgba(0,0,0,.45)); }
        .bzBlock{ width: 100%; position: relative; display: grid; align-content: start; justify-items: center; gap: 2px; padding-top: 8px; border-radius: 12px 12px 4px 4px;
          background: linear-gradient(180deg, rgba(255,255,255,.26), rgba(255,255,255,.07)); border: 1px solid rgba(255,255,255,.22); border-bottom: 0;
          transition: height .9s cubic-bezier(.22,1,.36,1), background .3s ease, box-shadow .3s ease; box-shadow: 0 -4px 20px rgba(0,0,0,.25); }
        .bzName{ max-width: 94%; font-size: 12px; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: .92; }
        .bzScore{ font-family: var(--font-display); font-weight: 900; font-size: 24px; line-height: 1; color: #ffe08a; }
        .bzPod.me .bzBlock{ border-color: #3fe0f5; box-shadow: 0 -4px 20px rgba(0,0,0,.25), 0 0 0 2px rgba(63,224,245,.35); }
        .bzPod.lit .bzBlock{ background: linear-gradient(180deg, rgba(255,210,63,.6), rgba(255,140,40,.2)); border-color: #ffd23f; box-shadow: 0 0 36px rgba(255,200,60,.65); }
        .bzPod.lit .bzFigure{ animation: bzJump .5s ease-in-out infinite alternate; }
        @keyframes bzJump{ from{ transform: translateY(0); } to{ transform: translateY(-10px); } }
        .bzPod.out .bzBlock{ background: linear-gradient(180deg, rgba(120,120,130,.35), rgba(80,80,90,.1)); border-color: rgba(255,255,255,.1); }
        .bzPod.out .bzFigure{ filter: grayscale(1) opacity(.7); }
        .bzLock{ font-size: 14px; }
        .bzBell{ position: absolute; top: -32px; z-index: 5; font-size: 24px; animation: bzJump .4s ease-in-out infinite alternate; }
        .bzCrown{ position: absolute; top: -34px; z-index: 5; font-size: 26px; animation: bzPop .6s ease-out; }
        .bzGain{ position: absolute; top: -30px; z-index: 6; font-family: var(--font-display); font-weight: 900; font-size: 24px; color: #7dffa9; text-shadow: 0 2px 8px rgba(0,0,0,.6); animation: bzRise 1.6s ease-out forwards; }
        @keyframes bzRise{ 0%{ opacity: 0; transform: translateY(14px) scale(.6); } 20%{ opacity: 1; transform: translateY(0) scale(1.2); } 100%{ opacity: 0; transform: translateY(-54px) scale(1); } }
        .bzPod.champ .bzBlock{ background: linear-gradient(180deg, rgba(255,210,63,.7), rgba(255,140,40,.3)); border-color: #ffd23f; }

        @media (max-width: 640px){
          .bzMain{ gap: 2px; padding-top: 10px; }
          .bzHead{ gap: 6px; }
          .bzCount{ margin-left: 0; padding: 4px 10px; }
          .bzGoal{ font-size: 12px; padding: 4px 10px; }
          .bzDisc{ width: 128px; height: 128px; }
          .bzVinyl{ inset: 12px; }
          .bzNote{ font-size: 26px; }
          .bzEq{ height: 18px; bottom: -4px; }
          .bzButton{ width: 104px; height: 104px; border-width: 4px; box-shadow: 0 7px 0 #6d0b06, 0 12px 24px rgba(0,0,0,.45); }
          .bzButton span{ font-size: 24px; }
          .bzButton small{ display: none; }
          .bzTalk{ gap: 6px; }
          .bzTitle{ font-size: 20px; }
          .bzSub{ font-size: 13px; }
          .bzSong{ font-size: 22px; }
          .bzWin{ font-size: 15px; padding: 5px 12px; }
          .bzScore{ font-size: 16px; }
          .bzName{ font-size: 9.5px; }
          .bzStage{ gap: 6px; padding: 0; }
          .bzPodia{ min-height: calc(var(--base) + var(--H) + 74px); gap: 3px; }
          .bzForm{ flex-direction: column; }
          .bzInput{ height: 44px; font-size: 16px; }
        }
        @media (prefers-reduced-motion: reduce){
          .bzVinyl, .bzLabel, .bzEq i, .bzPod.lit .bzFigure, .bzBell, .bzTalk, .bzSong, .bzGain{ animation: none !important; }
        }
      `}</style>
        </main>
    );
}
