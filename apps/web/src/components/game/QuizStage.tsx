"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { serverNow } from "@/lib/serverClock";
import { fmtNum, useI18n } from "@/lib/i18n";
import { errorText } from "@/lib/errorText";
import { gameModeInfo } from "@/lib/gameModes";
import { playFx } from "@/lib/gameFx";
import { playlistLook } from "@/lib/musicGenres";
import { SongRound } from "@/components/game/SongRound";
import { SnippetPlayer, SNIPPET_CLIPS, snippetStage } from "@/components/game/SnippetPlayer";
import { PlayerAvatar, type AvatarConfig } from "@/components/game/PlayerAvatar";
import { AudioControl } from "@/components/AudioControl";

/** Lobby-Felder, die das Quiz braucht (Migration 108). */
export type QuizLobby = {
    code: string;
    game_mode: string | null;
    topic_selected: string | null;
    series_index: number;
    series_total: number;
    current_song_id: string | null;
    current_song_started_at: string | null;
    quiz_state: string | null;
    quiz_index: number;
    quiz_total: number;
    quiz_seq: number;
    quiz_rev: number;
    quiz_started_at: string | null;
    quiz_ends_at: string | null;
    quiz_picker: string | null;
    quiz_options: Record<string, unknown> | null;
    quiz_reveal: Record<string, unknown> | null;
    quiz_locked: string[];
};

export type QuizPlayer = {
    player_id: string;
    name: string;
    song_points?: number;
    avatar_config?: AvatarConfig | null;
    is_bot?: boolean;
};

type Status = {
    seq: number;
    me: { answered: boolean; correct?: boolean | null; points?: number; tries?: number; answer?: string };
    answered: string[];
    pickOptions: { id: string; title: string; artist: string }[] | null;
    bets: { a: number; b: number; mine: string | null } | null;
};

type RevealResult = { playerId: string; points: number; correct: boolean; answer: string | null };

const pts = (n: number) => (Number.isInteger(n) ? String(n) : fmtNum(n, 1));

function secondsLeft(endsAt: string | null): number {
    const t = endsAt ? Date.parse(endsAt) : NaN;
    return Number.isNaN(t) ? 0 : Math.max(0, (t - serverNow()) / 1000);
}

export function QuizStage({
    lobby,
    players,
    mePlayerId,
    onToast,
}: {
    lobby: QuizLobby;
    players: QuizPlayer[];
    mePlayerId: string | null;
    onToast: (msg: string, ms?: number) => void;
}) {
    const { tr } = useI18n();
    const supabase = getSupabaseClient();
    const mode = lobby.game_mode ?? "artist";
    const info = gameModeInfo(mode);
    const state = lobby.quiz_state;
    const opts = (lobby.quiz_options ?? {}) as Record<string, unknown>;
    const reveal = (lobby.quiz_reveal ?? null) as Record<string, unknown> | null;
    const me = players.find((p) => p.player_id === mePlayerId) ?? null;
    const nameOf = useCallback((id: unknown) => players.find((p) => p.player_id === id)?.name ?? "…", [players]);

    const [status, setStatus] = useState<Status | null>(null);
    const [answer, setAnswer] = useState("");
    const [busy, setBusy] = useState(false);
    const [feedback, setFeedback] = useState<{ kind: "ok" | "bad"; text: string; nonce: number } | null>(null);
    const [, setNow] = useState(0);
    const inputRef = useRef<HTMLInputElement | null>(null);

    // Uhr für Zeitbalken + Takt (Server-Tick als Absicherung, falls der Cron mal hängt)
    const tickBusy = useRef(false);
    useEffect(() => {
        const t = window.setInterval(() => {
            setNow((n) => n + 1);
            if (lobby.quiz_ends_at && secondsLeft(lobby.quiz_ends_at) <= 0 && !tickBusy.current) {
                tickBusy.current = true;
                void supabase.rpc("rpc_quiz_tick", { p_code: lobby.code }).then(() => {
                    window.setTimeout(() => (tickBusy.current = false), 900);
                });
            }
        }, 200);
        return () => window.clearInterval(t);
    }, [lobby.quiz_ends_at, lobby.code, supabase]);

    // Status (eigene Antwort, wer schon fertig ist, Songauswahl, Wetten) bei jeder Änderung neu laden
    useEffect(() => {
        if (!mePlayerId) return;
        let alive = true;
        void supabase.rpc("rpc_quiz_status", { p_code: lobby.code, p_player_id: mePlayerId }).then(({ data, error }) => {
            if (!alive || error || !data) return;
            setStatus(data as Status);
        });
        return () => {
            alive = false;
        };
    }, [supabase, lobby.code, mePlayerId, lobby.quiz_rev, lobby.quiz_seq, lobby.quiz_state]);

    // Neue Frage -> Feld leeren, Fokus
    useEffect(() => {
        setAnswer("");
        setFeedback(null);
        if (state === "question" || state === "buzzed") window.setTimeout(() => inputRef.current?.focus(), 60);
    }, [lobby.quiz_seq, state]);

    const mySeqStatus = status && status.seq === lobby.quiz_seq ? status : null;
    const meAnswered = !!mySeqStatus?.me.answered;
    const meCorrect = !!mySeqStatus?.me.correct;
    const answeredSet = useMemo(() => new Set(mySeqStatus?.answered ?? []), [mySeqStatus]);

    const duelA = (opts.a as string | undefined) ?? null;
    const duelB = (opts.b as string | undefined) ?? null;
    const iAmDuelist = !!mePlayerId && (mePlayerId === duelA || mePlayerId === duelB);
    const iAmPicker = !!mePlayerId && lobby.quiz_picker === mePlayerId;
    const lockedOut = !!mePlayerId && (lobby.quiz_locked ?? []).includes(mePlayerId);
    const canPlay = !!me;

    const run = useCallback(
        async (fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>) => {
            if (busy) return null;
            setBusy(true);
            try {
                const { data, error } = await fn();
                if (error) {
                    onToast(`❌ ${errorText(error.message)}`, 2200);
                    return null;
                }
                return data ?? {};
            } finally {
                setBusy(false);
            }
        },
        [busy, onToast]
    );

    const submitText = useCallback(async () => {
        const a = answer.trim();
        if (!a || !mePlayerId) return;
        const res = (await run(() => supabase.rpc("rpc_quiz_answer", { p_code: lobby.code, p_player_id: mePlayerId, p_answer: a }))) as {
            correct?: boolean;
            points?: number;
            half?: boolean;
        } | null;
        if (!res) return;
        setAnswer("");
        if (res.correct) {
            playFx("voteWin");
            setFeedback({
                kind: "ok",
                text: res.half ? tr("Künstler richtig! +{n}", { n: pts(Number(res.points ?? 0)) }) : tr("Richtig! +{n}", { n: pts(Number(res.points ?? 0)) }),
                nonce: Date.now(),
            });
        } else {
            playFx("wrong");
            setFeedback({ kind: "bad", text: tr("Leider falsch – „{a}“", { a }), nonce: Date.now() });
            window.setTimeout(() => inputRef.current?.focus(), 30);
        }
    }, [answer, mePlayerId, run, supabase, lobby.code, tr]);

    const choose = useCallback(
        async (choice: string) => {
            if (!mePlayerId) return;
            const res = (await run(() => supabase.rpc("rpc_quiz_choose", { p_code: lobby.code, p_player_id: mePlayerId, p_choice: choice }))) as {
                correct?: boolean | null;
                points?: number;
            } | null;
            if (!res) return;
            setStatus((s) => (s ? { ...s, me: { answered: true, correct: res.correct ?? null, points: res.points, answer: choice } } : s));
            if (res.correct === true) playFx("voteWin");
            else if (res.correct === false) playFx("wrong");
            else playFx("vote");
        },
        [mePlayerId, run, supabase, lobby.code]
    );

    const buzz = useCallback(async () => {
        if (!mePlayerId) return;
        playFx("tick");
        await run(() => supabase.rpc("rpc_quiz_buzz", { p_code: lobby.code, p_player_id: mePlayerId }));
    }, [mePlayerId, run, supabase, lobby.code]);

    const pick = useCallback(
        async (songId: string) => {
            if (!mePlayerId) return;
            await run(() => supabase.rpc("rpc_quiz_pick", { p_code: lobby.code, p_player_id: mePlayerId, p_song_id: songId }));
        },
        [mePlayerId, run, supabase, lobby.code]
    );

    const bet = useCallback(
        async (playerId: string) => {
            if (!mePlayerId) return;
            const ok = await run(() => supabase.rpc("rpc_quiz_bet", { p_code: lobby.code, p_player_id: mePlayerId, p_pick: playerId }));
            if (ok) {
                playFx("vote");
                setStatus((s) => (s && s.bets ? { ...s, bets: { ...s.bets, mine: playerId } } : s));
            }
        },
        [mePlayerId, run, supabase, lobby.code]
    );

    // Tasten: 1–4 = Antwort wählen, Leertaste = Buzzer
    const choices = useMemo(() => (Array.isArray(opts.choices) ? (opts.choices as string[]) : []), [opts.choices]);
    useEffect(() => {
        const onKey = (ev: KeyboardEvent) => {
            const tag = (ev.target as HTMLElement | null)?.tagName;
            if (tag === "INPUT" || tag === "TEXTAREA") return;
            if (state !== "question" || !canPlay) return;
            if (mode === "artist" && !meAnswered && /^[1-4]$/.test(ev.key) && choices[Number(ev.key) - 1]) {
                ev.preventDefault();
                void choose(choices[Number(ev.key) - 1]);
            }
            if (mode === "buzzer" && !lockedOut && (ev.key === " " || ev.key === "Enter")) {
                ev.preventDefault();
                void buzz();
            }
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [state, mode, canPlay, meAnswered, choices, choose, buzz, lockedOut]);

    // ------------------------------------------------------------ Zeitbalken
    const total = useMemo(() => {
        const a = lobby.quiz_started_at ? Date.parse(lobby.quiz_started_at) : NaN;
        const b = lobby.quiz_ends_at ? Date.parse(lobby.quiz_ends_at) : NaN;
        return Number.isNaN(a) || Number.isNaN(b) ? 1 : Math.max(1, (b - a) / 1000);
    }, [lobby.quiz_started_at, lobby.quiz_ends_at]);
    const left = secondsLeft(lobby.quiz_ends_at);
    const ratio = Math.max(0, Math.min(1, left / total));

    const ranked = useMemo(
        () => [...players].sort((a, b) => Number(b.song_points ?? 0) - Number(a.song_points ?? 0) || a.name.localeCompare(b.name)),
        [players]
    );
    const revealResults = ((reveal?.results as RevealResult[] | undefined) ?? []).filter((r) => Number(r.points) > 0 || r.answer);
    const look = playlistLook(lobby.topic_selected);

    const questionLabel =
        mode === "duel"
            ? tr("Duell {i} von {n}", { i: lobby.quiz_index, n: lobby.quiz_total })
            : tr("Frage {i} von {n}", { i: lobby.quiz_index, n: lobby.quiz_total });

    // ------------------------------------------------------------ Audio
    const songPlaying = state === "question" || state === "buzzed" || state === "reveal";
    const audio =
        mode === "snippet" && state === "question" ? (
            <SnippetPlayer songId={lobby.current_song_id} startedAt={lobby.quiz_started_at} />
        ) : songPlaying ? (
            <SongRound
                songId={lobby.current_song_id}
                startedAt={mode === "snippet" ? lobby.quiz_started_at : lobby.current_song_started_at}
            />
        ) : null;

    // ------------------------------------------------------------ Textfeld
    const textBox = (placeholder: string) => (
        <form
            className="qzForm"
            onSubmit={(e) => {
                e.preventDefault();
                void submitText();
            }}
        >
            <input
                ref={inputRef}
                className={`qzInput ${feedback?.kind === "bad" ? "qzShake" : ""}`}
                key={feedback?.kind === "bad" ? feedback.nonce : "in"}
                value={answer}
                onChange={(e) => setAnswer(e.target.value)}
                placeholder={placeholder}
                maxLength={60}
                autoComplete="off"
                autoCorrect="off"
                spellCheck={false}
                enterKeyHint="send"
            />
            <button type="submit" className="btn btnPrimary qzSend" disabled={busy || !answer.trim()}>
                {tr("Abgeben")}
            </button>
        </form>
    );

    const doneCard = (text: string) => <div className="qzDone">{text}</div>;

    // ------------------------------------------------------------ Hauptbereich je Zustand
    let body: React.ReactNode = null;

    if (state === "pick") {
        body = iAmPicker ? (
            <div className="qzBlock">
                <div className="qzTitle">{tr("Du suchst den Song aus!")}</div>
                <div className="qzSub">{tr("Am besten einen, den manche kennen – aber nicht alle. Dann gibt es Bonuspunkte.")}</div>
                <div className="qzPickGrid">
                    {(mySeqStatus?.pickOptions ?? status?.pickOptions ?? []).map((s) => (
                        <button key={s.id} type="button" className="qzPick" onClick={() => void pick(s.id)} disabled={busy}>
                            <span className="qzPickTitle">{s.title}</span>
                            <span className="qzPickArtist">{s.artist}</span>
                        </button>
                    ))}
                </div>
            </div>
        ) : (
            <div className="qzBlock">
                <div className="qzTitle">{tr("{name} sucht einen Song aus …", { name: nameOf(lobby.quiz_picker) })}</div>
                <div className="qzSub">{tr("Gleich wird geraten – Ohren auf!")}</div>
            </div>
        );
    } else if (state === "bet") {
        const bets = mySeqStatus?.bets ?? status?.bets ?? null;
        body = (
            <div className="qzBlock">
                <div className="qzKick">{tr("⚔️ Nächstes Duell")}</div>
                <div className="qzDuel">
                    {[duelA, duelB].map((id, i) => {
                        const p = players.find((x) => x.player_id === id);
                        const mine = bets?.mine === id;
                        return (
                            <button
                                key={id ?? i}
                                type="button"
                                className={`qzDuelist ${mine ? "on" : ""}`}
                                disabled={!canPlay || iAmDuelist || busy || !id}
                                onClick={() => id && void bet(id)}
                            >
                                <PlayerAvatar seed={p?.name ?? "?"} config={p?.avatar_config ?? null} size={72} />
                                <span className="qzDuelName">{p?.name ?? "…"}</span>
                                {!iAmDuelist && canPlay ? <span className="qzDuelBet">{mine ? tr("Dein Tipp ✓") : tr("Darauf wetten")}</span> : null}
                                <span className="qzDuelCount">{tr("{n} Tipps", { n: i === 0 ? (bets?.a ?? 0) : (bets?.b ?? 0) })}</span>
                            </button>
                        );
                    })}
                </div>
                <div className="qzSub">
                    {iAmDuelist
                        ? tr("Du bist im Duell! Wer zuerst zwei Songs errät, gewinnt (+3).")
                        : tr("Tippe auf den Sieger – richtig getippt gibt +1.")}
                </div>
            </div>
        );
    } else if (state === "question" || state === "buzzed") {
        const gapMasked = typeof opts.masked === "string" ? opts.masked : null;
        if (mode === "artist") {
            body = (
                <div className="qzBlock">
                    <div className="qzTitle">{tr("Wer singt das?")}</div>
                    <div className="qzChoices">
                        {choices.map((c, i) => {
                            const picked = mySeqStatus?.me.answer === c;
                            return (
                                <button
                                    key={c}
                                    type="button"
                                    className={`qzChoice ${picked ? (meCorrect ? "ok" : "bad") : ""}`}
                                    disabled={!canPlay || meAnswered || busy}
                                    onClick={() => void choose(c)}
                                >
                                    <span className="qzChoiceKey">{i + 1}</span>
                                    {c}
                                </button>
                            );
                        })}
                    </div>
                    {meAnswered ? doneCard(meCorrect ? tr("Richtig! +{n}", { n: pts(Number(mySeqStatus?.me.points ?? 0)) }) : tr("Leider daneben.")) : null}
                </div>
            );
        } else if (mode === "year") {
            body = (
                <div className="qzBlock">
                    <div className="qzTitle">{tr("Aus welchem Jahr ist der Song?")}</div>
                    {meAnswered ? (
                        doneCard(tr("Dein Tipp: {y} – gleich kommt die Auflösung.", { y: mySeqStatus?.me.answer ?? "" }))
                    ) : canPlay ? (
                        <form
                            className="qzForm"
                            onSubmit={(e) => {
                                e.preventDefault();
                                if (/^\d{4}$/.test(answer.trim())) void choose(answer.trim());
                            }}
                        >
                            <input
                                ref={inputRef}
                                className="qzInput qzYear"
                                value={answer}
                                onChange={(e) => setAnswer(e.target.value.replace(/\D/g, "").slice(0, 4))}
                                placeholder="2019"
                                inputMode="numeric"
                                autoComplete="off"
                            />
                            <button type="submit" className="btn btnPrimary qzSend" disabled={busy || !/^\d{4}$/.test(answer.trim())}>
                                {tr("Tippen")}
                            </button>
                        </form>
                    ) : null}
                </div>
            );
        } else if (mode === "buzzer") {
            const buzzer = lobby.quiz_picker;
            body = (
                <div className="qzBlock">
                    {state === "buzzed" ? (
                        buzzer === mePlayerId ? (
                            <>
                                <div className="qzTitle">{tr("Du hast gebuzzert – schnell antworten!")}</div>
                                {textBox(tr("Songtitel oder Künstler …"))}
                            </>
                        ) : (
                            <div className="qzTitle">{tr("🔔 {name} hat gebuzzert!", { name: nameOf(buzzer) })}</div>
                        )
                    ) : lockedOut ? (
                        doneCard(tr("Falsch – für diesen Song bist du raus."))
                    ) : canPlay ? (
                        <>
                            <button type="button" className="qzBuzz" onClick={() => void buzz()} disabled={busy}>
                                {tr("BUZZ!")}
                            </button>
                            <div className="qzSub">{tr("Erkannt? Drück den Buzzer (oder Leertaste) und nenne Titel oder Künstler.")}</div>
                        </>
                    ) : null}
                </div>
            );
        } else if (mode === "duel") {
            body = (
                <div className="qzBlock">
                    <div className="qzDuelScore">
                        <span>{nameOf(duelA)}</span>
                        <b>
                            {Number(opts.wa ?? 0)} : {Number(opts.wb ?? 0)}
                        </b>
                        <span>{nameOf(duelB)}</span>
                    </div>
                    <div className="qzSub">{tr("Song {i} von höchstens 3", { i: Number(opts.song ?? 1) })}</div>
                    {iAmDuelist
                        ? meCorrect
                            ? doneCard(tr("Richtig!"))
                            : textBox(tr("Songtitel oder Künstler …"))
                        : doneCard(tr("Du schaust zu – wer ist schneller?"))}
                </div>
            );
        } else {
            // snippet, pick, gap: Text eintippen
            const isPickerHere = mode === "pick" && iAmPicker;
            const stage = mode === "snippet" ? snippetStage(lobby.quiz_started_at).stage : 0;
            body = (
                <div className="qzBlock">
                    {mode === "gap" && gapMasked ? (
                        <>
                            <div className="qzSub">{tr("Welches Wort fehlt im Titel?")}</div>
                            <div className="qzGap">{gapMasked}</div>
                        </>
                    ) : mode === "snippet" ? (
                        <>
                            <div className="qzTitle">{tr("Welcher Song ist das?")}</div>
                            <div className="qzStages">
                                {SNIPPET_CLIPS.map((s, i) => (
                                    <span key={s} className={`qzStage ${i === stage ? "on" : i < stage ? "past" : ""}`}>
                                        {s} s · +{4 - i}
                                    </span>
                                ))}
                            </div>
                        </>
                    ) : (
                        <div className="qzTitle">
                            {isPickerHere ? tr("Dein Song läuft – die anderen raten!") : mode === "pick" ? tr("{name} hat diesen Song gewählt", { name: nameOf(lobby.quiz_picker) }) : tr("Welcher Song ist das?")}
                        </div>
                    )}
                    {isPickerHere || !canPlay
                        ? null
                        : meCorrect
                          ? doneCard(tr("Richtig! +{n} – warte auf die anderen.", { n: pts(Number(mySeqStatus?.me.points ?? 0)) }))
                          : textBox(mode === "gap" ? tr("Fehlendes Wort …") : tr("Songtitel oder Künstler …"))}
                </div>
            );
        }
    } else if (state === "reveal" && reveal) {
        const myRes = ((reveal.results as RevealResult[] | undefined) ?? []).find((r) => r.playerId === mePlayerId);
        body = (
            <div className="qzBlock qzReveal">
                <div className="qzKick">{tr("Auflösung")}</div>
                <div className="qzSongTitle">{String(reveal.title ?? "")}</div>
                <div className="qzSongArtist">
                    {String(reveal.artist ?? "")}
                    {reveal.year ? ` · ${String(reveal.year)}` : ""}
                </div>
                {reveal.word ? <div className="qzSub">{tr("Gesuchtes Wort: {w}", { w: String(reveal.word) })}</div> : null}
                {mode === "artist" && choices.length ? (
                    <div className="qzChoices qzChoicesSmall">
                        {choices.map((c) => {
                            const right = c === reveal.artist;
                            const mine = myRes?.answer === c || mySeqStatus?.me.answer === c;
                            return (
                                <div key={c} className={`qzChoice ${right ? "ok" : mine ? "bad" : ""}`}>
                                    {right ? "✓ " : mine ? "✗ " : ""}
                                    {c}
                                </div>
                            );
                        })}
                    </div>
                ) : null}
                {reveal.pickerBonus ? <div className="qzSub">{tr("+{n} für {name}: gute Songwahl!", { n: Number(reveal.pickerBonus), name: nameOf(lobby.quiz_picker) })}</div> : null}
                {reveal.duelDone ? (
                    <div className="qzDuelWin">
                        {reveal.duelWinner ? tr("🏆 {name} gewinnt das Duell!", { name: nameOf(reveal.duelWinner) }) : tr("Unentschieden – keiner hat gewonnen.")}
                    </div>
                ) : null}
                {myRes && Number(myRes.points) > 0 ? <div className="qzMine">{tr("Du: +{n}", { n: pts(Number(myRes.points)) })}</div> : null}
                {revealResults.length ? (
                    <div className="qzResults">
                        {revealResults.slice(0, 8).map((r) => (
                            <span key={r.playerId} className={`qzRes ${Number(r.points) > 0 ? "ok" : ""}`}>
                                {nameOf(r.playerId)}
                                {r.answer && mode === "year" ? ` (${r.answer})` : ""} {Number(r.points) > 0 ? `+${pts(Number(r.points))}` : ""}
                            </span>
                        ))}
                    </div>
                ) : (
                    <div className="qzSub">{tr("Diesmal hat es keiner erkannt.")}</div>
                )}
            </div>
        );
    } else {
        body = (
            <div className="qzBlock">
                <div className="qzTitle">{tr("Gleich geht's los …")}</div>
            </div>
        );
    }

    return (
        <main className="fullH quizMain" style={{ ["--pl" as string]: look.color }}>
            {audio}
            <div className="qzTopRight">
                <AudioControl />
            </div>
            <div className="qzWrap">
                <header className="qzHead">
                    <span className="qzMode">
                        {info.icon} {tr(info.label)}
                    </span>
                    <span className="qzCount">{questionLabel}</span>
                    {(lobby.series_total ?? 1) > 1 ? (
                        <span className="qzCount">{tr("Runde {i}/{n}", { i: lobby.series_index, n: lobby.series_total })}</span>
                    ) : null}
                </header>
                <div className="qzBar" aria-hidden>
                    <div className={`qzBarFill ${left < 4 && state === "question" ? "hot" : ""}`} style={{ transform: `scaleX(${ratio})` }} />
                </div>

                <section className="qzCard" key={`${lobby.quiz_seq}:${state}`}>
                    {body}
                    {feedback && feedback.kind === "ok" && (state === "question" || state === "buzzed") ? <div className="qzFeedOk">{feedback.text}</div> : null}
                    {feedback && feedback.kind === "bad" && (state === "question" || state === "buzzed") ? (
                        <div className="qzFeedBad" key={feedback.nonce}>
                            {feedback.text}
                        </div>
                    ) : null}
                </section>

                <aside className="qzBoard">
                    {ranked.map((p, i) => {
                        const done = answeredSet.has(p.player_id) && (state === "question" || state === "buzzed");
                        const inDuel = mode === "duel" && (p.player_id === duelA || p.player_id === duelB);
                        return (
                            <div key={p.player_id} className={`qzRow ${p.player_id === mePlayerId ? "me" : ""} ${inDuel ? "duel" : ""}`}>
                                <span className="qzRank">{i + 1}</span>
                                <PlayerAvatar seed={p.name} config={p.avatar_config ?? null} size={34} />
                                <span className="qzName">
                                    {p.name}
                                    {p.player_id === mePlayerId ? ` (${tr("du")})` : ""}
                                </span>
                                {done ? <span className="qzTick" title={tr("hat geantwortet")}>✓</span> : null}
                                {lobby.quiz_picker === p.player_id && (mode === "pick" || state === "buzzed") ? <span className="qzTick">{mode === "pick" ? "🎯" : "🔔"}</span> : null}
                                <span className="qzPts" key={String(p.song_points ?? 0)}>
                                    {pts(Number(p.song_points ?? 0))}
                                </span>
                            </div>
                        );
                    })}
                </aside>
            </div>

            <style>{`
        .quizMain{ min-height: 100dvh; padding: 24px 16px 40px; color: white; display: grid; place-items: start center; }
        .qzTopRight{ position: fixed; top: 14px; right: 14px; z-index: 30; }
        .qzWrap{ width: min(1080px, 100%); display: grid; grid-template-columns: minmax(0, 1fr) 300px; grid-template-areas: "head head" "bar bar" "card board"; gap: 14px 18px; margin-top: 18px; }
        @media (max-width: 820px){ .qzWrap{ grid-template-columns: 1fr; grid-template-areas: "head" "bar" "card" "board"; } }
        .qzHead{ grid-area: head; display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
        .qzMode{ font-family: var(--font-display); font-size: clamp(22px, 3vw, 32px); font-weight: 900; margin-right: auto; }
        .qzCount{ padding: 6px 12px; border-radius: 999px; background: rgba(255,255,255,0.12); border: 1px solid rgba(255,255,255,0.16); font-weight: 900; font-size: 14px; }
        .qzBar{ grid-area: bar; height: 10px; border-radius: 999px; background: rgba(255,255,255,0.12); overflow: hidden; }
        .qzBarFill{ height: 100%; background: linear-gradient(90deg, var(--pl, #ffd23f), #ffe08a); transform-origin: left; transition: transform .2s linear; }
        .qzBarFill.hot{ background: linear-gradient(90deg, #ff5a3c, #ffb03c); }
        .qzCard{ grid-area: card; border-radius: 26px; padding: clamp(18px, 3vw, 30px); background: rgba(38,9,6,0.5); border: 2px solid rgba(255,255,255,0.14); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); min-height: 300px; display: grid; align-content: center; gap: 14px; animation: qzIn .35s ease-out; }
        @keyframes qzIn { from { opacity: 0; transform: translateY(10px) scale(.98); } to { opacity: 1; transform: none; } }
        .qzBlock{ display: grid; gap: 14px; justify-items: center; text-align: center; }
        .qzKick{ font-size: 13px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; opacity: .75; }
        .qzTitle{ font-family: var(--font-display); font-size: clamp(22px, 3.2vw, 34px); font-weight: 900; overflow-wrap: anywhere; }
        .qzSub{ opacity: .85; font-weight: 750; max-width: 560px; }
        .qzChoices{ width: 100%; display: grid; grid-template-columns: repeat(2, minmax(0,1fr)); gap: 12px; }
        @media (max-width: 560px){ .qzChoices{ grid-template-columns: 1fr; } }
        .qzChoice{ display: flex; align-items: center; gap: 10px; text-align: left; padding: 16px; border-radius: 18px; border: 2px solid rgba(255,255,255,0.18); background: rgba(255,255,255,0.08); color: white; font-weight: 900; font-size: 17px; cursor: pointer; transition: transform .12s, background .15s, border-color .15s; overflow-wrap: anywhere; }
        .qzChoice:not(:disabled):hover{ transform: translateY(-2px); background: rgba(255,255,255,0.14); border-color: var(--pl, #ffd23f); }
        .qzChoice:disabled{ cursor: default; opacity: .6; }
        .qzChoicesSmall .qzChoice{ padding: 8px 12px; font-size: 14px; cursor: default; opacity: .55; }
        .qzChoicesSmall .qzChoice.ok, .qzChoicesSmall .qzChoice.bad{ opacity: 1; }
        .qzChoice.ok{ opacity: 1; background: rgba(60,220,120,0.25); border-color: #3cdc78; }
        .qzChoice.bad{ opacity: 1; background: rgba(255,80,60,0.22); border-color: #ff5a3c; }
        .qzChoiceKey{ flex: none; width: 28px; height: 28px; border-radius: 9px; display: grid; place-items: center; background: rgba(255,255,255,0.14); font-size: 14px; }
        .qzForm{ width: min(560px, 100%); display: flex; gap: 10px; }
        .qzInput{ flex: 1; min-width: 0; height: 54px; border-radius: 16px; border: 2px solid rgba(255,255,255,0.2); background: rgba(0,0,0,0.25); color: white; font-size: 19px; font-weight: 800; padding: 0 16px; outline: none; }
        .qzInput:focus{ border-color: var(--pl, #ffd23f); }
        .qzYear{ text-align: center; font-size: 26px; letter-spacing: 4px; }
        .qzSend{ height: 54px; padding: 0 20px; }
        .qzShake{ animation: qzShake .35s; border-color: #ff5a3c; }
        @keyframes qzShake { 20%{ transform: translateX(-6px);} 40%{ transform: translateX(6px);} 60%{ transform: translateX(-4px);} 80%{ transform: translateX(4px);} }
        .qzDone, .qzFeedOk{ padding: 12px 18px; border-radius: 16px; background: rgba(60,220,120,0.18); border: 1px solid rgba(60,220,120,0.5); font-weight: 900; justify-self: center; animation: qzIn .3s ease-out; }
        .qzFeedBad{ justify-self: center; font-weight: 850; color: #ffb3a6; animation: qzIn .25s ease-out; }
        .qzGap{ font-family: var(--font-display); font-size: clamp(26px, 4.4vw, 46px); font-weight: 900; letter-spacing: 1px; overflow-wrap: anywhere; }
        .qzStages{ display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
        .qzStage{ padding: 6px 12px; border-radius: 999px; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.14); font-weight: 900; font-size: 14px; opacity: .55; }
        .qzStage.on{ opacity: 1; background: var(--pl, #ffd23f); color: #2a1200; transform: scale(1.08); }
        .qzStage.past{ opacity: .3; text-decoration: line-through; }
        .qzBuzz{ width: min(260px, 70vw); aspect-ratio: 1; border-radius: 50%; border: 6px solid rgba(255,255,255,0.35); background: radial-gradient(circle at 35% 30%, #ff8a6b, #e0261b 60%, #9c120b); color: white; font-family: var(--font-display); font-size: clamp(34px, 6vw, 52px); font-weight: 900; cursor: pointer; box-shadow: 0 16px 0 #6d0b06, 0 26px 50px rgba(0,0,0,0.4); transition: transform .08s, box-shadow .08s; }
        .qzBuzz:active{ transform: translateY(10px); box-shadow: 0 6px 0 #6d0b06, 0 12px 30px rgba(0,0,0,0.4); }
        .qzPickGrid{ width: 100%; display: grid; gap: 10px; }
        .qzPick{ display: grid; gap: 2px; text-align: left; padding: 14px 16px; border-radius: 16px; border: 2px solid rgba(255,255,255,0.18); background: rgba(255,255,255,0.08); color: white; cursor: pointer; transition: transform .12s, border-color .15s; }
        .qzPick:hover{ transform: translateY(-2px); border-color: var(--pl, #ffd23f); }
        .qzPickTitle{ font-weight: 900; font-size: 18px; }
        .qzPickArtist{ opacity: .75; font-weight: 750; }
        .qzDuel{ display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; }
        .qzDuelist{ display: grid; justify-items: center; gap: 6px; min-width: 170px; padding: 16px; border-radius: 20px; border: 2px solid rgba(255,255,255,0.18); background: rgba(255,255,255,0.07); color: white; cursor: pointer; }
        .qzDuelist:disabled{ cursor: default; }
        .qzDuelist.on{ border-color: var(--pl, #ffd23f); background: rgba(255,210,63,0.16); }
        .qzDuelName{ font-weight: 900; font-size: 18px; }
        .qzDuelBet{ font-size: 13px; font-weight: 900; color: #ffe08a; }
        .qzDuelCount{ font-size: 12px; opacity: .7; font-weight: 800; }
        .qzDuelScore{ display: flex; gap: 14px; align-items: center; font-weight: 900; font-size: 18px; }
        .qzDuelScore b{ font-family: var(--font-display); font-size: 40px; color: #ffe08a; }
        .qzDuelWin{ font-weight: 900; font-size: 20px; color: #ffe08a; }
        .qzReveal .qzSongTitle{ font-family: var(--font-display); font-size: clamp(26px, 4vw, 42px); font-weight: 900; overflow-wrap: anywhere; animation: qzPop .45s ease-out; }
        .qzSongArtist{ font-weight: 850; font-size: 18px; opacity: .9; }
        @keyframes qzPop { 0%{ transform: scale(.85); opacity: 0;} 70%{ transform: scale(1.05); opacity: 1;} 100%{ transform: scale(1);} }
        .qzMine{ font-weight: 950; color: #7dffa9; font-size: 20px; }
        .qzResults{ display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
        .qzRes{ padding: 6px 12px; border-radius: 999px; background: rgba(255,255,255,0.08); font-weight: 850; font-size: 14px; }
        .qzRes.ok{ background: rgba(60,220,120,0.2); }
        .qzBoard{ grid-area: board; display: grid; gap: 8px; align-content: start; }
        .qzRow{ display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 16px; background: rgba(38,9,6,0.45); border: 1px solid rgba(255,255,255,0.12); }
        .qzRow.me{ border-color: var(--pl, #ffd23f); }
        .qzRow.duel{ background: rgba(255,210,63,0.14); }
        .qzRank{ width: 18px; font-weight: 900; opacity: .7; }
        .qzName{ flex: 1; min-width: 0; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .qzTick{ color: #7dffa9; font-weight: 900; }
        .qzPts{ font-family: var(--font-display); font-weight: 900; font-size: 20px; color: #ffe08a; animation: qzPop .4s ease-out; }
        @media (prefers-reduced-motion: reduce){ .qzCard, .qzPts, .qzSongTitle, .qzDone, .qzFeedOk, .qzFeedBad{ animation: none !important; } }
      `}</style>
        </main>
    );
}
