"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { gameModeInfo } from "@/lib/gameModes";
import { SongRound } from "@/components/game/SongRound";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { AudioControl } from "@/components/AudioControl";
import { pts, useQuiz, type QuizLobby, type QuizPlayer, type RevealResult } from "@/components/quiz/useQuiz";

const PAD = 30; // Platz links/rechts, damit Figuren am Rand nicht abgeschnitten werden
const LANE = 62; // Höhe einer Figuren-Reihe
const MAX_LANES = 3;

/**
 * JAHR RATEN – Zeitreise (Migration 118).
 * Ziel: Nach 8 Songs gewinnt, wer die meisten Punkte hat. Aufstellung: Die Spieler stehen auf einer Zeitleiste – du ziehst
 * deine Figur selbst auf das Jahr; bei der Auflösung springen ALLE Figuren auf ihr Jahr und das echte Jahr fällt als Marker.
 */
export function YearTimeline({ lobby, players, mePlayerId, onToast }: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (m: string, ms?: number) => void }) {
    const { tr } = useI18n();
    const q = useQuiz({ lobby, mePlayerId, onToast });
    const info = gameModeInfo("year");
    const state = lobby.quiz_state;
    const opts = lobby.quiz_options ?? {};
    const yMin = Number(opts.yearMin ?? 2008);
    const yMax = Number(opts.yearMax ?? new Date().getFullYear());
    const span = Math.max(1, yMax - yMin);
    const me = players.find((p) => p.player_id === mePlayerId) ?? null;
    const reveal = lobby.quiz_reveal;
    const trueYear = reveal?.year != null ? Number(reveal.year) : null;
    const results = useMemo(() => ((reveal?.results as RevealResult[] | undefined) ?? []).filter((r) => r.answer != null), [reveal]);
    const canGuess = state === "question" && !!me && !q.meAnswered;
    const myLocked = state === "question" && !!me && q.meAnswered;

    // Der Tipp gehört zur Frage: neue Frage = Figur wieder in der Mitte-rechts der Zeitleiste
    const defaultPick = Math.round(yMin + span * 0.65);
    const [pickState, setPickState] = useState<{ seq: number; y: number } | null>(null);
    const pick = pickState && pickState.seq === lobby.quiz_seq ? pickState.y : defaultPick;
    const setPick = useCallback(
        (v: number | ((p: number) => number)) =>
            setPickState((prev) => {
                const cur = prev && prev.seq === lobby.quiz_seq ? prev.y : defaultPick;
                return { seq: lobby.quiz_seq, y: typeof v === "function" ? v(cur) : v };
            }),
        [lobby.quiz_seq, defaultPick]
    );
    const trackRef = useRef<HTMLDivElement | null>(null);
    const dragging = useRef(false);
    const [trackW, setTrackW] = useState(640);

    useEffect(() => {
        const el = trackRef.current;
        if (!el) return;
        const ro = new ResizeObserver(() => setTrackW(el.getBoundingClientRect().width));
        ro.observe(el);
        setTrackW(el.getBoundingClientRect().width);
        return () => ro.disconnect();
    }, []);

    const frac = (y: number) => Math.max(0, Math.min(1, (y - yMin) / span));
    const leftOf = (y: number) => `calc(${PAD}px + (100% - ${PAD * 2}px) * ${frac(y)})`;
    const pxPerYear = Math.max(4, (trackW - PAD * 2) / span);

    const pointerYear = useCallback(
        (clientX: number) => {
            const el = trackRef.current;
            if (!el) return;
            const r = el.getBoundingClientRect();
            const f = Math.max(0, Math.min(1, (clientX - r.left - PAD) / Math.max(1, r.width - PAD * 2)));
            setPick(Math.round(yMin + f * span));
        },
        [yMin, span, setPick]
    );

    const submit = useCallback(async () => {
        if (!canGuess) return;
        await q.guessYear(pick);
    }, [canGuess, q, pick]);

    // Pfeiltasten verschieben die Figur, Enter gibt den Tipp ab
    useEffect(() => {
        if (!canGuess) return;
        const onKey = (ev: KeyboardEvent) => {
            const tag = (ev.target as HTMLElement | null)?.tagName;
            if (tag === "INPUT" || tag === "TEXTAREA" || tag === "BUTTON") return;
            if (ev.key === "ArrowLeft") {
                ev.preventDefault();
                setPick((p) => Math.max(yMin, p - 1));
            } else if (ev.key === "ArrowRight") {
                ev.preventDefault();
                setPick((p) => Math.min(yMax, p + 1));
            } else if (ev.key === "Enter") {
                ev.preventDefault();
                void submit();
            }
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [canGuess, yMin, yMax, submit, setPick]);

    // ---- Figuren auf der Zeitleiste
    type Tok = { id: string; year: number; pts: number | null; mine: boolean; locked?: boolean };
    const tokens: Tok[] = useMemo(() => {
        if (state === "reveal") {
            return results.map((r) => ({ id: r.playerId, year: Number(r.answer), pts: Number(r.points), mine: r.playerId === mePlayerId }));
        }
        if (me && state === "question") {
            const guessed = q.meAnswered && q.status?.me.answer != null ? Number(q.status.me.answer) : null;
            return [{ id: me.player_id, year: guessed ?? pick, pts: null, mine: true, locked: guessed != null }];
        }
        return [];
    }, [state, results, me, mePlayerId, q.meAnswered, q.status, pick]);

    // Reihen verteilen: Figuren, die zu nah beieinander stehen, rutschen in die nächste Reihe
    const placed = useMemo(() => {
        const minDx = 50 / pxPerYear;
        const lanes: number[] = [];
        return [...tokens]
            .sort((a, b) => a.year - b.year)
            .map((t) => {
                let lane = lanes.findIndex((x) => t.year - x >= minDx);
                if (lane < 0) lane = lanes.length < MAX_LANES ? lanes.length : lanes.indexOf(Math.min(...lanes));
                lanes[lane] = t.year;
                return { ...t, lane };
            });
    }, [tokens, pxPerYear]);
    const lanesUsed = Math.max(1, ...placed.map((t) => t.lane + 1));
    const best = Math.max(0, ...results.map((r) => Number(r.points)));

    const ticks = useMemo(() => Array.from({ length: span + 1 }, (_, i) => yMin + i), [yMin, span]);
    const nameOf = useCallback((id: string) => players.find((p) => p.player_id === id)?.name ?? "…", [players]);
    const answeredIds = new Set(state === "reveal" ? results.map((r) => r.playerId) : [...q.answeredSet, ...(q.meAnswered && me ? [me.player_id] : [])]);
    const others = players.filter((p) => p.player_id !== mePlayerId);
    const noGuess = state === "reveal" ? players.filter((p) => !answeredIds.has(p.player_id)) : [];
    const ranked = useMemo(() => [...players].sort((a, b) => Number(b.song_points ?? 0) - Number(a.song_points ?? 0) || a.name.localeCompare(b.name)), [players]);
    const gainOf = (id: string) => (state === "reveal" ? results.find((r) => r.playerId === id) : undefined);
    const closest = state === "reveal" && trueYear != null && results.length ? [...results].sort((a, b) => Math.abs(Number(a.answer) - trueYear) - Math.abs(Number(b.answer) - trueYear))[0] : null;
    const trackH = 78 + lanesUsed * LANE + 56;

    return (
        <main className="fullH ytMain">
            {state ? <SongRound songId={lobby.current_song_id} startedAt={lobby.current_song_started_at} /> : null}
            <div className="ytTopRight">
                <AudioControl />
            </div>

            <header className="ytHead">
                <span className="ytMode">
                    {info.icon} {tr(info.label)}
                </span>
                <span className="ytGoal">🎯 {tr(info.goal)}</span>
                <span className="ytCount">
                    {tr("Song {i} von {n}", { i: Math.max(1, lobby.quiz_index), n: lobby.quiz_total })}
                    {lobby.series_total > 1 ? ` · ${tr("Runde {i}/{n}", { i: lobby.series_index, n: lobby.series_total })}` : ""}
                </span>
            </header>
            <div className="ytBar" aria-hidden>
                <div className={`ytBarFill ${q.left < 4 && state === "question" ? "hot" : ""}`} style={{ transform: `scaleX(${q.ratio})` }} />
            </div>

            <section className="ytInfo" aria-live="polite" key={`${lobby.quiz_seq}:${state}`}>
                {state === "reveal" && reveal ? (
                    <>
                        <div className="ytKick">{tr("Auflösung")}</div>
                        <div className="ytSong">{String(reveal.title ?? "")}</div>
                        <div className="ytArtist">
                            {String(reveal.artist ?? "")} · {tr("erschienen {y}", { y: trueYear ?? "?" })}
                        </div>
                        {closest ? (
                            <div className="ytClosest">
                                {Math.abs(Number(closest.answer) - (trueYear ?? 0)) === 0
                                    ? tr("🎯 {name} liegt genau richtig!", { name: nameOf(closest.playerId) })
                                    : tr("Am nächsten dran: {name} (±{n})", { name: nameOf(closest.playerId), n: Math.abs(Number(closest.answer) - (trueYear ?? 0)) })}
                            </div>
                        ) : (
                            <div className="ytClosest">{tr("Diesmal hat keiner getippt.")}</div>
                        )}
                    </>
                ) : state === "question" ? (
                    <>
                        <div className="ytQ">{tr("In welchem Jahr ist dieser Song erschienen?")}</div>
                        <div className="ytHint">
                            {!me ? tr("Du schaust zu.") : myLocked ? tr("Dein Tipp steht – warte auf die anderen …") : tr("Zieh deine Figur auf das Jahr – oder tippe auf die Zeitleiste.")}
                        </div>
                    </>
                ) : (
                    <div className="ytQ">{tr("Gleich geht's los …")}</div>
                )}
            </section>

            {/* ---------- Die Zeitleiste ---------- */}
            <section className="ytPanel">
                {state === "question" && others.length ? (
                    <div className="ytWait" aria-label={tr("Mitspieler")}>
                        {others.map((p) => {
                            const done = answeredIds.has(p.player_id);
                            return (
                                <span key={p.player_id} className={`ytChip ${done ? "done" : ""}`} title={p.name}>
                                    <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={24} />
                                    <span className="ytChipName">{p.name}</span>
                                    <span aria-hidden>{done ? "✓" : "…"}</span>
                                </span>
                            );
                        })}
                    </div>
                ) : null}

                <div
                    ref={trackRef}
                    className={`ytTrack ${canGuess ? "active" : ""}`}
                    style={{ height: trackH }}
                    onPointerDown={(e) => {
                        if (!canGuess) return;
                        dragging.current = true;
                        e.currentTarget.setPointerCapture(e.pointerId);
                        pointerYear(e.clientX);
                    }}
                    onPointerMove={(e) => {
                        if (dragging.current) pointerYear(e.clientX);
                    }}
                    onPointerUp={() => (dragging.current = false)}
                    onPointerCancel={() => (dragging.current = false)}
                >
                    {/* Treffer-Zone ±2 und echtes Jahr */}
                    {state === "reveal" && trueYear != null ? (
                        <>
                            <div className="ytZone" style={{ left: leftOf(trueYear - 2), width: `calc((100% - ${PAD * 2}px) * ${Math.min(1, 4 / span)})` }} aria-hidden>
                                <span>{tr("Treffer-Zone")}</span>
                            </div>
                            <div className="ytPin" style={{ left: leftOf(trueYear) }} aria-label={tr("erschienen {y}", { y: trueYear })}>
                                <span className="ytPinHead">{trueYear}</span>
                                <span className="ytPinLine" />
                            </div>
                        </>
                    ) : null}

                    {/* Achse */}
                    <div className="ytAxis" aria-hidden />
                    {ticks.map((y) => {
                        const major = y % 5 === 0;
                        return (
                            <span key={y} className={`ytTick ${major ? "major" : ""}`} style={{ left: leftOf(y) }} aria-hidden>
                                {major ? <em>{y}</em> : null}
                            </span>
                        );
                    })}

                    {/* Figuren */}
                    {placed.map((t, i) => {
                        const p = players.find((x) => x.player_id === t.id);
                        if (!p) return null;
                        const winner = state === "reveal" && best > 0 && t.pts === best;
                        const err = trueYear != null ? Math.abs(t.year - trueYear) : null;
                        return (
                            <div
                                key={t.id}
                                className={`ytTok ${t.mine ? "mine" : ""} ${t.locked ? "locked" : ""} ${state === "reveal" ? "drop" : ""} ${canGuess && t.mine ? "dragMe" : ""}`}
                                style={{ left: leftOf(t.year), bottom: `${44 + t.lane * LANE}px`, ["--i" as string]: i }}
                            >
                                {t.mine && state === "question" ? <span className="ytBubble">{t.year}</span> : null}
                                {state === "reveal" ? (
                                    <span className="ytBadge">
                                        <b>{t.year}</b>
                                        {err != null ? <small>{err === 0 ? "🎯" : `±${err}`}</small> : null}
                                        <em>{Number(t.pts) > 0 ? `+${pts(Number(t.pts))}` : "0"}</em>
                                    </span>
                                ) : null}
                                {winner ? <span className="ytCrown">👑</span> : null}
                                <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={t.mine && state === "question" ? 52 : 40} />
                                <span className="ytTokName">{t.locked ? `🔒 ${p.name}` : p.name}</span>
                            </div>
                        );
                    })}
                </div>

                {canGuess ? (
                    <div className="ytControls">
                        <button type="button" className="ytStep" onClick={() => setPick((p) => Math.max(yMin, p - 1))} aria-label={tr("Ein Jahr früher")}>
                            −
                        </button>
                        <button type="button" className="btn btnPrimary ytSend" onClick={() => void submit()} disabled={q.busy}>
                            {tr("Tipp abgeben: {y}", { y: pick })}
                        </button>
                        <button type="button" className="ytStep" onClick={() => setPick((p) => Math.min(yMax, p + 1))} aria-label={tr("Ein Jahr später")}>
                            +
                        </button>
                    </div>
                ) : state === "reveal" && noGuess.length ? (
                    <div className="ytNoGuess">{tr("Kein Tipp: {names}", { names: noGuess.map((p) => p.name).join(", ") })}</div>
                ) : null}
            </section>

            {/* ---------- Punktestand ---------- */}
            <section className="ytBoard" aria-label={tr("Punktestand")}>
                {ranked.map((p, i) => {
                    const g = gainOf(p.player_id);
                    return (
                        <div key={p.player_id} className={`ytRow ${p.player_id === mePlayerId ? "me" : ""}`}>
                            <span className="ytRank">{i + 1}</span>
                            <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={30} />
                            <span className="ytRowName" title={p.name}>
                                {p.name}
                            </span>
                            <span className="ytPts" key={String(p.song_points ?? 0)}>
                                {pts(Number(p.song_points ?? 0))}
                            </span>
                            {g && Number(g.points) > 0 ? (
                                <span className="ytGain" key={`${lobby.quiz_seq}:${p.player_id}`}>
                                    +{pts(Number(g.points))}
                                </span>
                            ) : null}
                        </div>
                    );
                })}
            </section>

            <style>{`
        .ytMain{ min-height: 100dvh; color: #fff; display: flex; flex-direction: column; gap: 8px; padding: 12px 14px 14px; position: relative; overflow-x: hidden;
          background: radial-gradient(ellipse 60% 40% at 50% -5%, rgba(91,231,196,.20), transparent 70%), repeating-linear-gradient(90deg, rgba(255,255,255,.025) 0 1px, transparent 1px 60px),
                      linear-gradient(180deg, #0d2b36 0%, #0a1c27 55%, #07121a 100%); }
        .ytTopRight{ position: fixed; top: 14px; right: 14px; z-index: 30; }
        .ytHead{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding-right: 64px; }
        .ytMode{ font-family: var(--font-display); font-weight: 900; font-size: clamp(20px, 3vw, 28px); }
        .ytGoal{ padding: 6px 12px; border-radius: 999px; font-weight: 900; font-size: 13.5px; background: rgba(91,231,196,.14); border: 1px solid rgba(91,231,196,.5); color: #9ff3dc; }
        .ytCount{ margin-left: auto; padding: 6px 12px; border-radius: 999px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.16); font-weight: 850; font-size: 13px; }
        .ytBar{ height: 8px; border-radius: 999px; background: rgba(255,255,255,.1); overflow: hidden; }
        .ytBarFill{ height: 100%; background: linear-gradient(90deg, #5be7c4, #b6ffe9); transform-origin: left; transition: transform .2s linear; }
        .ytBarFill.hot{ background: linear-gradient(90deg, #ff6b5a, #ffb03c); }

        .ytInfo{ display: grid; gap: 4px; justify-items: center; text-align: center; min-height: 86px; align-content: center; animation: ytIn .35s cubic-bezier(.16,1,.3,1); }
        @keyframes ytIn{ from{ opacity: 0; transform: translateY(8px); } }
        .ytQ{ font-family: var(--font-display); font-weight: 900; font-size: clamp(20px, 3.2vw, 32px); }
        .ytHint{ opacity: .8; font-weight: 750; font-size: 14px; }
        .ytKick{ font-size: 12px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; opacity: .7; }
        .ytSong{ font-family: var(--font-display); font-weight: 900; font-size: clamp(24px, 3.8vw, 38px); overflow-wrap: anywhere; }
        .ytArtist{ font-weight: 850; opacity: .9; }
        .ytClosest{ margin-top: 2px; padding: 5px 14px; border-radius: 999px; background: rgba(91,231,196,.14); border: 1px solid rgba(91,231,196,.45); font-weight: 850; font-size: 14px; }

        .ytPanel{ border-radius: 22px; padding: 10px 12px 12px; background: rgba(7,24,32,.55); border: 1px solid rgba(255,255,255,.14); backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px); display: grid; gap: 8px; }
        .ytWait{ display: flex; gap: 6px; flex-wrap: wrap; justify-content: center; }
        .ytChip{ display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px 3px 4px; border-radius: 999px; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); font-size: 12.5px; font-weight: 800; opacity: .75; }
        .ytChip.done{ opacity: 1; background: rgba(91,231,196,.16); border-color: rgba(91,231,196,.55); }
        .ytChip img{ border-radius: 50%; }
        .ytChipName{ max-width: 90px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

        .ytTrack{ position: relative; width: 100%; user-select: none; -webkit-user-select: none; transition: height .3s ease; }
        .ytTrack.active{ cursor: ew-resize; touch-action: none; }
        .ytAxis{ position: absolute; left: ${PAD - 8}px; right: ${PAD - 8}px; bottom: 30px; height: 6px; border-radius: 999px; background: linear-gradient(90deg, rgba(91,231,196,.35), rgba(91,231,196,.9), rgba(91,231,196,.35)); box-shadow: 0 0 14px rgba(91,231,196,.4); }
        .ytTick{ position: absolute; bottom: 30px; width: 2px; height: 14px; margin-left: -1px; background: rgba(255,255,255,.4); transform: translateY(4px); pointer-events: none; }
        .ytTick.major{ height: 20px; background: rgba(255,255,255,.8); }
        .ytTick em{ position: absolute; top: 26px; left: 50%; transform: translateX(-50%); font-style: normal; font-size: 12px; font-weight: 850; opacity: .8; white-space: nowrap; }

        .ytTok{ position: absolute; width: 74px; margin-left: -37px; display: grid; justify-items: center; gap: 1px; z-index: 5; transition: left .08s linear; pointer-events: none; }
        .ytTok img{ border-radius: 50%; background: rgba(255,255,255,.12); box-shadow: 0 0 0 3px rgba(255,255,255,.35), 0 6px 14px rgba(0,0,0,.4); }
        .ytTok.mine img{ box-shadow: 0 0 0 3px #3fe0f5, 0 6px 14px rgba(0,0,0,.4); }
        .ytTok.dragMe{ z-index: 8; }
        .ytTok.dragMe img{ box-shadow: 0 0 0 4px #5be7c4, 0 0 24px rgba(91,231,196,.7), 0 8px 18px rgba(0,0,0,.45); animation: ytFloat 1.4s ease-in-out infinite alternate; }
        .ytTok.locked img{ box-shadow: 0 0 0 4px #ffd23f, 0 6px 14px rgba(0,0,0,.4); }
        @keyframes ytFloat{ to{ transform: translateY(-4px); } }
        .ytTokName{ max-width: 74px; padding: 1px 7px; border-radius: 999px; background: rgba(8,16,24,.82); font-size: 11px; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .ytBubble{ margin-bottom: 2px; padding: 3px 12px; border-radius: 12px; background: #5be7c4; color: #05261e; font-family: var(--font-display); font-weight: 900; font-size: 20px; box-shadow: 0 4px 12px rgba(0,0,0,.4); }
        .ytTok.drop{ animation: ytDropIn .7s cubic-bezier(.2,1.4,.4,1) backwards; animation-delay: calc(var(--i, 0) * 110ms); transition: none; }
        @keyframes ytDropIn{ from{ opacity: 0; transform: translateY(-90px) scale(.5); } }
        .ytBadge{ display: inline-flex; align-items: baseline; gap: 4px; padding: 1px 7px; border-radius: 10px; background: rgba(8,16,24,.9); border: 1px solid rgba(255,255,255,.25); font-size: 12px; margin-bottom: 1px; white-space: nowrap; }
        .ytBadge b{ font-weight: 900; }
        .ytBadge small{ opacity: .8; font-weight: 800; }
        .ytBadge em{ font-style: normal; font-weight: 950; color: #7dffa9; }
        .ytCrown{ position: absolute; top: -26px; font-size: 22px; animation: ytDropIn .6s .5s cubic-bezier(.2,1.4,.4,1) backwards; }

        .ytZone{ position: absolute; top: 6px; bottom: 30px; background: linear-gradient(180deg, rgba(125,255,169,.0), rgba(125,255,169,.20)); border-left: 1px dashed rgba(125,255,169,.5); border-right: 1px dashed rgba(125,255,169,.5); pointer-events: none; }
        .ytZone span{ position: absolute; top: 2px; left: 50%; transform: translateX(-50%); font-size: 10.5px; font-weight: 900; letter-spacing: 1px; text-transform: uppercase; color: #9fffc4; opacity: .85; white-space: nowrap; }
        .ytPin{ position: absolute; top: 0; bottom: 30px; width: 0; z-index: 4; display: flex; flex-direction: column; align-items: center; pointer-events: none; animation: ytPinDrop .8s .15s cubic-bezier(.3,1.5,.5,1) backwards; }
        .ytPinHead{ transform: translateX(0); padding: 3px 12px; border-radius: 10px; background: #ff6b6b; color: #fff; font-family: var(--font-display); font-weight: 900; font-size: 20px; box-shadow: 0 6px 16px rgba(0,0,0,.5); z-index: 2; }
        .ytPinLine{ flex: 1; width: 3px; background: linear-gradient(180deg, #ff6b6b, rgba(255,107,107,.15)); }
        @keyframes ytPinDrop{ from{ opacity: 0; transform: translateY(-60px); } }

        .ytControls{ display: flex; gap: 10px; justify-content: center; align-items: center; }
        .ytStep{ width: 46px; height: 46px; border-radius: 50%; border: 2px solid rgba(255,255,255,.3); background: rgba(255,255,255,.1); color: #fff; font-size: 24px; font-weight: 900; cursor: pointer; }
        .ytStep:hover{ background: rgba(255,255,255,.2); }
        .ytSend{ min-width: 200px; height: 46px; }
        .ytNoGuess{ text-align: center; font-size: 13px; font-weight: 750; opacity: .75; }

        .ytBoard{ display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
        .ytRow{ position: relative; display: flex; align-items: center; gap: 8px; padding: 5px 12px 5px 8px; border-radius: 16px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.13); }
        .ytRow.me{ border-color: #3fe0f5; }
        .ytRank{ width: 16px; font-weight: 900; opacity: .6; text-align: center; }
        .ytRow img{ border-radius: 50%; }
        .ytRowName{ max-width: 110px; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .ytPts{ font-family: var(--font-display); font-weight: 900; font-size: 20px; color: #ffe08a; }
        .ytGain{ position: absolute; right: 8px; top: -14px; font-family: var(--font-display); font-weight: 900; color: #7dffa9; text-shadow: 0 2px 6px rgba(0,0,0,.6); animation: ytGain 1.8s ease-out forwards; }
        @keyframes ytGain{ 0%{ opacity: 0; transform: translateY(8px) scale(.7); } 20%{ opacity: 1; transform: translateY(0) scale(1.2); } 100%{ opacity: 0; transform: translateY(-18px); } }

        @media (max-width: 640px){
          .ytMain{ padding: 10px 10px 12px; gap: 6px; }
          .ytTok{ width: 60px; margin-left: -30px; }
          .ytTokName{ max-width: 60px; font-size: 10px; }
          .ytBadge{ font-size: 10.5px; padding: 1px 5px; }
          .ytBubble{ font-size: 17px; padding: 2px 9px; }
          .ytSend{ min-width: 0; flex: 1; }
          .ytInfo{ min-height: 70px; }
          .ytTick.major em{ font-size: 10.5px; }
          .ytRow{ padding: 3px 9px 3px 6px; gap: 5px; }
          .ytPts{ font-size: 16px; }
          .ytRowName{ max-width: 70px; font-size: 12px; }
        }
        @media (prefers-reduced-motion: reduce){ .ytTok, .ytPin, .ytInfo, .ytGain, .ytCrown, .ytTok.dragMe img{ animation: none !important; } }
      `}</style>
        </main>
    );
}
