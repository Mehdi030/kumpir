"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "@/lib/i18n";
import { AudioControl } from "@/components/AudioControl";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { ConfettiBurst } from "@/components/quiz/ConfettiBurst";
import { pts, useQuiz, type QuizLobby, type QuizPlayer } from "@/components/quiz/useQuiz";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { serverNow } from "@/lib/serverClock";
import { errorText } from "@/lib/errorText";
import { playFanfare } from "@/lib/gameFx";
import { criterionInfo, type BattleDuel, type BattlePick, type BattleReveal } from "@/lib/battle";
import { playClip, previewUrlOf } from "@/lib/battleClip";
import { gameModeInfo } from "@/lib/gameModes";

type SongRow = { id: string; title: string; artist: string; year: number | null; vs: number };

/** Spielt den Ausschnitt eines Duell-Teilnehmers, solange sein Zustand (play_a / play_b) läuft – bei allen gleichzeitig. */
function ClipPlayer({ pick, active, startedAt, seconds }: { pick: BattlePick | undefined; active: boolean; startedAt: string | null; seconds: number }) {
    const { tr } = useI18n();
    const [blocked, setBlocked] = useState(false);
    const songId = pick?.songId ?? null;
    const start = pick?.start ?? 0;
    useEffect(() => {
        if (!active || !songId) return;
        let alive = true;
        let stop = () => {};
        void previewUrlOf(songId).then((url) => {
            if (!alive || !url) return;
            const t0 = startedAt ? Date.parse(startedAt) : NaN;
            const offset = Number.isNaN(t0) ? 0 : Math.max(0, (serverNow() - t0) / 1000);
            stop = playClip(url, start, seconds, offset, setBlocked);
        });
        return () => {
            alive = false;
            stop();
        };
    }, [active, songId, start, startedAt, seconds]);
    return active && blocked ? <div className="btBlocked">🔊 {tr("Tippe irgendwo, damit der Ton startet")}</div> : null;
}

/** Knopf zum erneuten Anhören eines Ausschnitts (nur bei mir, für die Jury). */
function Replay({ pick, seconds, label }: { pick: BattlePick | undefined; seconds: number; label: string }) {
    const stopRef = useRef<() => void>(() => {});
    const [on, setOn] = useState(false);
    useEffect(() => () => stopRef.current(), []);
    if (!pick?.songId) return null;
    const songId = pick.songId;
    const click = async () => {
        stopRef.current();
        if (on) {
            setOn(false);
            return;
        }
        const url = await previewUrlOf(songId);
        if (!url) return;
        setOn(true);
        const stop = playClip(url, pick.start, seconds);
        const t = window.setTimeout(() => setOn(false), seconds * 1000);
        stopRef.current = () => {
            window.clearTimeout(t);
            stop();
            setOn(false);
        };
    };
    return (
        <button type="button" className="btn btnSecondary btnSmall btReplay" onClick={() => void click()}>
            {on ? "⏹" : "▶"} {label}
        </button>
    );
}

/** Song suchen, Stelle festlegen, endgültig bestätigen (nur für die zwei Battle-Teilnehmer, solange sie noch nicht gewählt haben). */
function PickPanel({ code, mePlayerId, clip, onToast }: { code: string; mePlayerId: string; clip: number; onToast: (m: string, ms?: number) => void }) {
    const { tr } = useI18n();
    const supabase = getSupabaseClient();
    const [query, setQuery] = useState("");
    const [found, setFound] = useState<{ q: string; rows: SongRow[] } | null>(null);
    const [chosen, setChosen] = useState<SongRow | null>(null);
    const [start, setStart] = useState(0);
    const [freeMode, setFreeMode] = useState(false);
    const [freeText, setFreeText] = useState("");
    const [busy, setBusy] = useState(false);
    const [hearing, setHearing] = useState(false);
    const stopRef = useRef<() => void>(() => {});

    useEffect(() => {
        const term = query.trim();
        if (term.length < 2) return;
        let alive = true;
        const t = window.setTimeout(() => {
            void supabase.rpc("rpc_battle_search", { p_code: code, p_player_id: mePlayerId, p_query: term }).then(({ data }) => {
                if (alive) setFound({ q: term, rows: Array.isArray(data) ? (data as SongRow[]) : [] });
            });
        }, 280);
        return () => {
            alive = false;
            window.clearTimeout(t);
        };
    }, [query, code, mePlayerId, supabase]);
    useEffect(() => () => stopRef.current(), []);

    const rows = found && found.q === query.trim() ? found.rows : [];
    const noHits = query.trim().length >= 2 && found?.q === query.trim() && rows.length === 0;

    const hear = async () => {
        stopRef.current();
        if (hearing) {
            setHearing(false);
            return;
        }
        if (!chosen) return;
        const url = await previewUrlOf(chosen.id);
        if (!url) return onToast(tr("Für diesen Song gibt es keine Hörprobe."), 2200);
        setHearing(true);
        const stop = playClip(url, start, clip);
        const t = window.setTimeout(() => setHearing(false), clip * 1000);
        stopRef.current = () => {
            window.clearTimeout(t);
            stop();
            setHearing(false);
        };
    };

    const send = async (songId: string | null, text: string | null, at: number) => {
        if (busy) return;
        stopRef.current();
        setBusy(true);
        const { error } = await supabase.rpc("rpc_battle_pick", { p_code: code, p_player_id: mePlayerId, p_song_id: songId, p_text: text, p_start: at });
        setBusy(false);
        if (error) onToast(`❌ ${errorText(error.message)}`, 2400);
    };

    return (
        <section className="btPick" aria-label={tr("Dein Song")}>
            <h2>{tr("🎵 Such dir deinen Song aus")}</h2>
            {!freeMode ? (
                <>
                    {!chosen ? (
                        <>
                            <input className="btSearch" value={query} onChange={(e) => setQuery(e.target.value)} placeholder={tr("Songtitel oder Künstler suchen …")} aria-label={tr("Song suchen")} autoComplete="off" maxLength={40} />
                            <ul className="btResults">
                                {rows.map((r) => (
                                    <li key={r.id}>
                                        <button
                                            type="button"
                                            onClick={() => {
                                                setChosen(r);
                                                setStart(Math.max(0, Math.min(22, r.vs)));
                                            }}
                                        >
                                            <b>{r.title}</b>
                                            <span>
                                                {r.artist}
                                                {r.year ? ` · ${r.year}` : ""}
                                            </span>
                                        </button>
                                    </li>
                                ))}
                                {noHits ? <li className="btNone">{tr("Nichts gefunden – versuch einen anderen Namen oder trag den Song nur als Text ein.")}</li> : null}
                            </ul>
                            <button type="button" className="btLink" onClick={() => setFreeMode(true)}>
                                {tr("Song nicht dabei? Nur den Namen eintragen (ohne Ton)")}
                            </button>
                        </>
                    ) : (
                        <div className="btChosen">
                            <div className="btChosenSong">
                                <b>{chosen.title}</b>
                                <span>{chosen.artist}</span>
                            </div>
                            <label className="btSlider">
                                <span>{tr("Welche Stelle? Start bei {t}", { t: `0:${String(start).padStart(2, "0")}` })}</span>
                                <input
                                    type="range"
                                    min={0}
                                    max={22}
                                    step={1}
                                    value={start}
                                    onChange={(e) => {
                                        setStart(Number(e.target.value));
                                        stopRef.current();
                                        setHearing(false);
                                    }}
                                />
                                <small>{tr("Der Ausschnitt ist {n} Sekunden lang.", { n: clip })}</small>
                            </label>
                            <div className="btRow">
                                <button type="button" className="btn btnSecondary" onClick={() => void hear()}>
                                    {hearing ? "⏹" : "▶"} {tr("Stelle anhören")}
                                </button>
                                <button type="button" className="btn btnPrimary btnGlow" disabled={busy} onClick={() => void send(chosen.id, null, start)}>
                                    ✅ {tr("Festlegen – das ist mein Song")}
                                </button>
                            </div>
                            <button
                                type="button"
                                className="btLink"
                                onClick={() => {
                                    stopRef.current();
                                    setChosen(null);
                                }}
                            >
                                ← {tr("anderen Song suchen")}
                            </button>
                        </div>
                    )}
                </>
            ) : (
                <div className="btChosen">
                    <input className="btSearch" value={freeText} onChange={(e) => setFreeText(e.target.value)} placeholder={tr("Song und Künstler, z. B. „Dancing Queen – ABBA“")} maxLength={60} aria-label={tr("Songname")} />
                    <small>{tr("Ohne Ausschnitt hört die Jury nichts – sie entscheidet nur nach dem Namen.")}</small>
                    <div className="btRow">
                        <button type="button" className="btn btnPrimary btnGlow" disabled={busy || freeText.trim().length < 2} onClick={() => void send(null, freeText, 0)}>
                            ✅ {tr("Festlegen")}
                        </button>
                    </div>
                    <button type="button" className="btLink" onClick={() => setFreeMode(false)}>
                        ← {tr("zurück zur Suche")}
                    </button>
                </div>
            )}
        </section>
    );
}

/** HIT ODER FLOP (Migration 143): 1-gegen-1-Song-Battle, die Jury entscheidet. */
export function BattleArena({ lobby, players, mePlayerId, onToast }: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (m: string, ms?: number) => void }) {
    const { tr } = useI18n();
    const q = useQuiz({ lobby, mePlayerId, onToast });
    const supabase = getSupabaseClient();
    const info = gameModeInfo("battle");
    const state = lobby.quiz_state;
    const duel = (lobby.quiz_options?.duel ?? null) as BattleDuel | null;
    const reveal = (state === "reveal" ? lobby.quiz_reveal : null) as BattleReveal | null;
    const clip = duel?.clip ?? 8;
    const crit = criterionInfo(duel?.crit);
    const [busy, setBusy] = useState(false);

    const by = useMemo(() => new Map(players.map((p) => [p.player_id, p])), [players]);
    const nameOf = (id: string | undefined) => (id ? by.get(id)?.name ?? "…" : "…");
    const iAmJury = !!duel && mePlayerId === duel.jury;
    const mySide: "a" | "b" | null = duel && mePlayerId === duel.a ? "a" : duel && mePlayerId === duel.b ? "b" : null;
    const myPicked = !!(duel && mySide && duel.picks[mySide]);
    const ranked = useMemo(() => [...players].sort((a, b) => Number(b.song_points ?? 0) - Number(a.song_points ?? 0) || a.name.localeCompare(b.name)), [players]);

    // Sieger-Fanfare bei der Auflösung
    const winnerNow = reveal?.winner ?? null;
    useEffect(() => {
        if (state === "reveal" && winnerNow) playFanfare();
    }, [state, winnerNow, lobby.quiz_seq]);

    if (!duel) {
        return (
            <main className="fullH btMain">
                <div className="btWait">{tr("Gleich geht's los …")}</div>
                <style>{CSS}</style>
            </main>
        );
    }

    const judge = async (side: "a" | "b") => {
        if (busy || !mePlayerId) return;
        setBusy(true);
        const { error } = await supabase.rpc("rpc_battle_judge", { p_code: lobby.code, p_player_id: mePlayerId, p_side: side });
        setBusy(false);
        if (error) onToast(`❌ ${errorText(error.message)}`, 2400);
    };

    const playing = state === "play_a" ? "a" : state === "play_b" ? "b" : null;
    const role = iAmJury
        ? tr("⚖️ Du bist in diesem Duell die Jury – hör beide Ausschnitte an und entscheide.")
        : mySide
          ? tr("🥊 Du trittst gegen {name} an.", { name: nameOf(mySide === "a" ? duel.b : duel.a) })
          : tr("👀 Du schaust zu – {name} ist die Jury.", { name: nameOf(duel.jury) });

    const card = (side: "a" | "b") => {
        const id = duel[side];
        const p = by.get(id);
        const pick = duel.picks[side];
        const won = reveal?.winner === side;
        const lost = reveal && reveal.winner && reveal.winner !== side;
        const showSong = state === "reveal" || state === "judge" || (playing && (playing === side || (playing === "b" && side === "a")));
        return (
            <div className={`btCard ${side} ${playing === side ? "on" : ""} ${won ? "won" : ""} ${lost ? "lost" : ""} ${mePlayerId === id ? "me" : ""}`}>
                <span className="btSide">{side.toUpperCase()}</span>
                {won ? <span className="btCrown">👑</span> : null}
                <div className="btAvatar">
                    <PlayerAvatar seed={p?.name ?? id} config={p?.avatar_config ?? null} size={72} />
                </div>
                <b className="btName">{p?.name ?? "…"}</b>
                {playing === side ? (
                    <span className="btEq" aria-hidden>
                        <i />
                        <i />
                        <i />
                        <i />
                        <i />
                    </span>
                ) : null}
                <div className="btSong">
                    {pick && showSong ? (
                        <>
                            <b>{pick.title}</b>
                            {pick.artist ? <span>{pick.artist}</span> : pick.free ? <span>{tr("nur der Name – ohne Ton")}</span> : null}
                        </>
                    ) : state === "pick" ? (
                        <span className={pick ? "ok" : ""}>{pick ? `✅ ${tr("hat gewählt")}` : tr("sucht noch …")}</span>
                    ) : (
                        <span>…</span>
                    )}
                </div>
            </div>
        );
    };

    return (
        <main className="fullH btMain">
            <div className="btTopRight">
                <AudioControl />
            </div>
            <ClipPlayer pick={playing ? duel.picks[playing] : undefined} active={!!playing} startedAt={lobby.quiz_started_at} seconds={clip} />
            {state === "reveal" && reveal?.winner ? <ConfettiBurst key={`c${lobby.quiz_seq}`} level={1} winner /> : null}

            <header className="btHead">
                <span className="btMode">
                    {info.icon} {tr(info.label)}
                </span>
                <span className="btCount">{tr("Duell {i} von {n}", { i: duel.n, n: lobby.quiz_total })}</span>
                <span className="btCrit" title={tr(crit.hint)}>
                    {crit.icon} {tr("Prinzip")}: <b>{tr(crit.label)}</b>
                </span>
            </header>
            <div className="btBar" aria-hidden>
                <div className={`btBarFill ${q.left < 6 && (state === "pick" || state === "judge") ? "hot" : ""}`} style={{ transform: `scaleX(${q.ratio})` }} />
            </div>

            <section className="btStage" aria-live="polite">
                <div className="btJury">
                    <span className="btJuryIcon" aria-hidden>
                        ⚖️
                    </span>
                    <div>
                        <small>{tr("Jury")}</small>
                        <b>{nameOf(duel.jury)}</b>
                    </div>
                </div>
                <div className="btVsRow">
                    {card("a")}
                    <div className="btVs" aria-hidden>
                        VS
                    </div>
                    {card("b")}
                </div>
                <p className="btRole">{role}</p>
                <p className="btQuestion">{tr(crit.hint)}</p>
            </section>

            <section className="btPanel">
                {state === "pick" ? (
                    mySide && !myPicked && mePlayerId ? (
                        <PickPanel code={lobby.code} mePlayerId={mePlayerId} clip={clip} onToast={onToast} />
                    ) : (
                        <div className="btWait">
                            {mySide ? tr("Dein Song steht – warte auf {name} …", { name: nameOf(mySide === "a" ? duel.b : duel.a) }) : tr("{a} und {b} suchen ihre Songs aus …", { a: nameOf(duel.a), b: nameOf(duel.b) })}
                        </div>
                    )
                ) : playing ? (
                    <div className="btNow">
                        <div className="btNowKick">{tr("Jetzt läuft der Ausschnitt von")}</div>
                        <div className="btNowName">
                            {playing.toUpperCase()} · {nameOf(duel[playing])}
                        </div>
                        {duel.picks[playing]?.songId ? null : <div className="btNowSub">{tr("Dieser Song hat keinen Ton – die Jury entscheidet nach dem Namen.")}</div>}
                    </div>
                ) : state === "judge" ? (
                    iAmJury ? (
                        <div className="btJudge">
                            <h2>{tr("Wer gewinnt – {p}?", { p: tr(crit.label) })}</h2>
                            <div className="btJudgeRow">
                                {(["a", "b"] as const).map((s) => (
                                    <div key={s} className={`btJudgeCol ${s}`}>
                                        <button type="button" className="btn btnPrimary btnXL" disabled={busy} onClick={() => void judge(s)}>
                                            {s === "a" ? "👈" : "👉"} {nameOf(duel[s])} <small>({duel.picks[s]?.title ?? "?"})</small>
                                        </button>
                                        <Replay pick={duel.picks[s]} seconds={clip} label={tr("Nochmal anhören")} />
                                    </div>
                                ))}
                            </div>
                        </div>
                    ) : (
                        <div className="btWait">{tr("{name} entscheidet gerade …", { name: nameOf(duel.jury) })}</div>
                    )
                ) : state === "reveal" && reveal ? (
                    <div className="btResult" key={`r${lobby.quiz_seq}`}>
                        {reveal.winner ? (
                            <>
                                <div className="btResultKick">🏆 {tr("Gewinner dieses Duells")}</div>
                                <div className="btResultName">{nameOf(reveal.winnerId ?? undefined)}</div>
                                <div className="btResultSub">
                                    {reveal[reveal.winner].title} {tr("schlägt")} {reveal[reveal.winner === "a" ? "b" : "a"].title} · +1 {tr("Punkt")}
                                </div>
                            </>
                        ) : (
                            <>
                                <div className="btResultKick">🤝 {tr("Unentschieden")}</div>
                                <div className="btResultSub">{tr("Die Jury hat sich nicht entschieden – kein Punkt.")}</div>
                            </>
                        )}
                    </div>
                ) : (
                    <div className="btWait">{tr("Gleich geht's weiter …")}</div>
                )}
            </section>

            <section className="btBoard" aria-label={tr("Punktestand")}>
                {ranked.map((p) => (
                    <div key={p.player_id} className={`btScore ${p.player_id === mePlayerId ? "me" : ""} ${p.player_id === duel.jury ? "jury" : ""}`}>
                        <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={30} />
                        <span className="btScoreName" title={p.name}>
                            {p.name}
                            {p.player_id === duel.jury ? " ⚖️" : p.player_id === duel.a || p.player_id === duel.b ? " 🥊" : ""}
                        </span>
                        <b>{pts(Number(p.song_points ?? 0))}</b>
                    </div>
                ))}
            </section>
            <style>{CSS}</style>
        </main>
    );
}

const CSS = `
.btMain{ min-height: 100dvh; color: #fff; display: flex; flex-direction: column; gap: 8px; padding: 12px 14px 16px; position: relative; overflow: hidden;
  background: radial-gradient(ellipse 55% 45% at 50% -5%, rgba(255,160,60,.28), transparent 70%), radial-gradient(ellipse 40% 60% at 10% 40%, rgba(255,90,60,.16), transparent 70%),
              radial-gradient(ellipse 40% 60% at 90% 40%, rgba(60,170,255,.16), transparent 70%), linear-gradient(180deg, #24102f 0%, #150a22 55%, #0a0614 100%); }
.btTopRight{ position: fixed; top: 14px; right: 14px; z-index: 30; }
.btHead{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 0 64px 0 128px; min-height: 40px; }
@media (max-width: 640px){ .btHead{ padding-left: 52px; } }
.btMode{ font-family: var(--font-display); font-weight: 900; font-size: 18px; }
.btCount{ font-size: 13px; font-weight: 800; opacity: .9; padding: 3px 10px; border-radius: 999px; background: rgba(255,255,255,.1); }
.btCrit{ font-size: 13px; font-weight: 700; padding: 3px 12px; border-radius: 999px; background: rgba(255,200,60,.16); border: 1px solid rgba(255,214,10,.5); }
.btBar{ height: 7px; border-radius: 999px; background: rgba(255,255,255,.12); overflow: hidden; }
.btBarFill{ height: 100%; transform-origin: left; background: linear-gradient(90deg, #ffd23f, #ff9d2e); transition: transform .25s linear; }
.btBarFill.hot{ background: linear-gradient(90deg, #ff6a4d, #ff2d55); }
.btStage{ display: grid; justify-items: center; gap: 8px; margin-top: 4px; }
.btJury{ display: flex; align-items: center; gap: 10px; padding: 6px 16px; border-radius: 999px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.22); }
.btJury small{ display: block; font-size: 10.5px; font-weight: 800; letter-spacing: 1.2px; text-transform: uppercase; opacity: .8; }
.btJury b{ font-size: 15px; }
.btJuryIcon{ font-size: 26px; }
.btVsRow{ display: grid; grid-template-columns: 1fr auto 1fr; align-items: stretch; gap: 10px; width: min(760px, 100%); }
.btVs{ align-self: center; font-family: var(--font-display); font-weight: 900; font-size: 30px; color: #ffd23f; text-shadow: 0 0 18px rgba(255,160,40,.9); }
.btCard{ position: relative; display: grid; justify-items: center; align-content: start; gap: 6px; padding: 18px 10px 12px; border-radius: 22px; min-width: 0;
  background: linear-gradient(180deg, rgba(255,255,255,.1), rgba(0,0,0,.2)); border: 2px solid rgba(255,255,255,.16); transition: transform .3s ease, box-shadow .3s ease, border-color .3s ease, opacity .3s ease; }
.btCard.a{ --c: #ff9d2e; } .btCard.b{ --c: #4cc3ff; }
.btCard.on{ transform: translateY(-6px) scale(1.03); border-color: var(--c); box-shadow: 0 0 34px color-mix(in srgb, var(--c) 60%, transparent); }
.btCard.won{ border-color: #ffd23f; box-shadow: 0 0 44px rgba(255,210,63,.6); transform: translateY(-4px) scale(1.04); }
.btCard.lost{ opacity: .55; }
.btCard.me{ outline: 2px dashed rgba(34,211,238,.7); outline-offset: 3px; }
.btSide{ position: absolute; top: 8px; left: 12px; font-family: var(--font-display); font-weight: 900; font-size: 20px; color: var(--c); }
.btCrown{ position: absolute; top: -22px; left: 50%; transform: translateX(-50%) rotate(-8deg); font-size: 34px; filter: drop-shadow(0 4px 6px rgba(0,0,0,.5)); }
.btAvatar{ border-radius: 50%; padding: 3px; background: radial-gradient(circle at 38% 32%, rgba(255,246,214,.7), rgba(255,200,80,.25) 72%); box-shadow: 0 0 0 3px var(--c); }
.btName{ font-size: 16px; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.btSong{ display: grid; gap: 2px; min-height: 40px; align-content: center; text-align: center; font-size: 13px; width: 100%; }
.btSong b{ font-size: 15px; overflow-wrap: anywhere; }
.btSong span{ opacity: .85; font-weight: 700; overflow-wrap: anywhere; }
.btSong span.ok{ color: #8dffb8; opacity: 1; }
.btEq{ display: flex; gap: 3px; align-items: flex-end; height: 22px; }
.btEq i{ width: 5px; border-radius: 3px; background: var(--c); animation: btEq .8s ease-in-out infinite; }
.btEq i:nth-child(2){ animation-delay: .12s; } .btEq i:nth-child(3){ animation-delay: .24s; } .btEq i:nth-child(4){ animation-delay: .36s; } .btEq i:nth-child(5){ animation-delay: .48s; }
@keyframes btEq{ 0%,100%{ height: 5px; } 50%{ height: 22px; } }
.btRole{ margin: 0; font-weight: 800; text-align: center; font-size: 14px; }
.btQuestion{ margin: 0; font-size: 12.5px; font-weight: 700; opacity: .85; text-align: center; }
.btPanel{ display: grid; justify-items: center; width: min(760px, 100%); margin: 0 auto; }
.btWait{ padding: 16px; text-align: center; font-weight: 800; opacity: .9; }
.btBlocked{ position: fixed; bottom: 14px; left: 50%; transform: translateX(-50%); z-index: 40; padding: 8px 16px; border-radius: 999px; background: rgba(0,0,0,.7); font-weight: 800; font-size: 13px; }
.btNow{ text-align: center; padding: 10px 14px; display: grid; gap: 2px; }
.btNowKick{ font-size: 12px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .85; }
.btNowName{ font-family: var(--font-display); font-weight: 900; font-size: clamp(22px, 4vw, 34px); }
.btNowSub{ font-size: 13px; font-weight: 700; opacity: .85; }
.btPick{ width: 100%; display: grid; gap: 10px; padding: 14px; border-radius: 20px; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.2); }
.btPick h2{ margin: 0; font-size: 18px; }
.btSearch{ width: 100%; padding: 12px 14px; border-radius: 14px; font: inherit; font-size: 15px; color: #fff; background: rgba(0,0,0,.35); border: 1px solid rgba(255,255,255,.28); }
.btResults{ list-style: none; margin: 0; padding: 0; display: grid; gap: 5px; max-height: 240px; overflow: auto; }
.btResults button{ width: 100%; display: grid; text-align: left; gap: 1px; padding: 9px 12px; border-radius: 12px; font: inherit; color: #fff; cursor: pointer; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.12); }
.btResults button:hover{ background: rgba(255,255,255,.16); }
.btResults button span{ font-size: 12.5px; opacity: .8; }
.btNone{ padding: 8px 4px; font-size: 13px; opacity: .8; }
.btLink{ justify-self: start; padding: 4px 2px; border: 0; background: none; color: #ffe08a; font: inherit; font-size: 13px; font-weight: 800; cursor: pointer; text-decoration: underline; }
.btChosen{ display: grid; gap: 10px; }
.btChosenSong{ display: grid; padding: 10px 14px; border-radius: 14px; background: rgba(255,214,10,.14); border: 1px solid rgba(255,224,138,.5); }
.btChosenSong span{ opacity: .85; font-weight: 700; font-size: 13px; }
.btSlider{ display: grid; gap: 4px; font-weight: 800; font-size: 14px; }
.btSlider small{ font-weight: 600; opacity: .8; }
.btSlider input{ width: 100%; accent-color: #ffd23f; height: 30px; }
.btRow{ display: flex; gap: 10px; flex-wrap: wrap; }
.btJudge{ width: 100%; display: grid; gap: 10px; text-align: center; }
.btJudge h2{ margin: 0; font-size: 20px; }
.btJudgeRow{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.btJudgeCol{ display: grid; gap: 8px; justify-items: stretch; }
.btJudgeCol button{ white-space: normal; line-height: 1.2; }
.btJudgeCol small{ display: block; font-weight: 700; opacity: .85; }
.btReplay{ justify-self: center; }
.btResult{ text-align: center; display: grid; gap: 4px; padding: 8px 12px; animation: btPop .5s cubic-bezier(.34,1.56,.64,1); }
@keyframes btPop{ from{ opacity: 0; transform: scale(.8); } }
.btResultKick{ font-size: 13px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; }
.btResultName{ font-family: var(--font-display); font-weight: 900; font-size: clamp(30px, 6vw, 52px); color: #ffe08a; text-shadow: 0 0 24px rgba(255,214,10,.6); }
.btResultSub{ font-weight: 800; opacity: .92; }
.btBoard{ display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; margin-top: auto; padding-top: 8px; }
.btScore{ display: flex; align-items: center; gap: 7px; padding: 5px 12px 5px 6px; border-radius: 999px; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); font-weight: 800; font-size: 13px; }
.btScore.me{ border-color: rgba(34,211,238,.8); }
.btScore.jury{ background: rgba(255,214,10,.14); }
.btScoreName{ max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.btScore b{ color: #ffe08a; font-size: 15px; font-variant-numeric: tabular-nums; }
@media (max-width: 640px){
  .btVsRow{ gap: 6px; } .btVs{ font-size: 20px; }
  .btCard{ padding: 16px 6px 10px; } .btAvatar img{ width: 52px !important; height: 52px !important; }
  .btJudgeRow{ grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce){ .btEq i, .btResult{ animation: none; } .btCard{ transition: none; } }
`;
