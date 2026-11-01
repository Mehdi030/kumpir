"use client";

import { use, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { AccountNameNote } from "@/components/AccountNameNote";
import { HomeButton } from "@/components/BackButton";
import { Spinner } from "@/components/Spinner";
import { useAuth } from "@/components/AuthProvider";
import { useProfile } from "@/hooks/useProfile";
import { startBotGame } from "@/lib/botGame";
import { errorText } from "@/lib/errorText";
import { GAME_MODE_BY_KEY } from "@/lib/gameModes";
import { useI18n } from "@/lib/i18n";
import { validatePlayerName } from "@/lib/profanity";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { track } from "@/lib/track";

type Challenge = {
    code: string;
    creator: string;
    mode: string;
    score: number;
    seriesTotal: 1 | 3 | 5;
    speed: "fast" | "normal" | "calm";
    roundSeconds: number;
    topicFilter: string[];
    lettersCfg: { cats?: number; secs?: number; off?: string[] } | null;
    bots: number;
    skill: 1 | 2 | 3;
    expired: boolean;
    results: { name: string; score: number }[];
};

/**
 * Herausforderung (Migration 139): Ein Freund hat in Buzzer, Zeitreise oder Roulette Punkte geholt – hier spielt man mit
 * denselben Einstellungen allein gegen Bots und versucht, die Punktzahl zu schlagen. Das Ergebnis steht danach im Endbildschirm.
 */
export default function ChallengePage({ params }: { params: Promise<{ code: string }> }) {
    const { code: raw } = use(params);
    const code = raw.toUpperCase();
    const router = useRouter();
    const { user } = useAuth();
    const { profile } = useProfile();
    const { tr } = useI18n();
    const [res, setRes] = useState<{ challenge: Challenge | null; error: string } | null>(null);
    const [typedName, setTypedName] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState("");

    useEffect(() => {
        let alive = true;
        void getSupabaseClient()
            .rpc("get_challenge", { p_code: code })
            .then(({ data, error: e }) => {
                if (alive) setRes({ challenge: (data as Challenge | null) ?? null, error: e?.message ?? "" });
            });
        return () => {
            alive = false;
        };
    }, [code]);

    // Mit Konto steht der Name fest; sonst frei wählbar (zuletzt benutzter Name als Vorschlag)
    const accountName = profile?.playerName?.slice(0, 24) ?? "";
    const [savedName] = useState(() => {
        try {
            return localStorage.getItem("kumpir_player_name") ?? "";
        } catch {
            return "";
        }
    });
    const shownName = user ? accountName : (typedName ?? savedName);
    const name = shownName.trim();
    const validation = useMemo(() => validatePlayerName(name), [name]);

    const start = async () => {
        const c = res?.challenge;
        if (!c || busy || !validation.ok) return;
        setBusy(true);
        setError("");
        try {
            track("challenge_played");
            const lobbyCode = await startBotGame({
                name,
                userId: user?.id ?? null,
                bots: c.bots,
                skill: String(c.skill) as "1" | "2" | "3",
                speed: c.speed,
                mode: c.mode,
                roundSeconds: c.roundSeconds,
                seriesTotal: c.seriesTotal,
                topicFilter: c.topicFilter ?? [],
                lettersCfg: c.lettersCfg,
                challenge: c.code,
            });
            router.push(`/game/${lobbyCode}`);
        } catch (e: unknown) {
            setError(errorText(e instanceof Error ? e.message : ""));
            setBusy(false);
        }
    };

    const c = res?.challenge ?? null;
    const mode = c ? GAME_MODE_BY_KEY[c.mode] : null;
    const medal = ["🥇", "🥈", "🥉"];

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label={tr("Herausforderung")}>
                    <HomeButton corner />
                    {!res ? (
                        <div style={{ display: "grid", placeItems: "center", padding: 28 }}>
                            <Spinner size={24} label={tr("Lade…")} />
                        </div>
                    ) : !c ? (
                        <>
                            <h1 className="h1">⚔️ {tr("Herausforderung")}</h1>
                            <p className="p hostSub">{tr("Diese Herausforderung gibt es nicht (mehr).")}</p>
                        </>
                    ) : (
                        <>
                            <h1 className="h1" style={{ marginBottom: 6 }}>
                                ⚔️ {tr("{name} fordert dich heraus!", { name: c.creator })}
                            </h1>
                            <p className="p hostSub" style={{ marginTop: 0 }}>
                                {mode ? `${mode.icon} ${tr(mode.label)}` : c.mode} · {tr("allein gegen {n} Bots", { n: c.bots })}
                            </p>
                            <div style={{ display: "grid", justifyItems: "center", gap: 2, margin: "18px 0", padding: "16px 12px", borderRadius: 18, background: "rgba(255,255,255,.1)", border: "1px solid rgba(255,255,255,.2)" }}>
                                <div style={{ fontSize: 12, fontWeight: 800, letterSpacing: 1.5, textTransform: "uppercase", opacity: 0.75 }}>{tr("Punkte zum Schlagen")}</div>
                                <div style={{ fontFamily: "var(--font-display)", fontSize: 56, fontWeight: 900, lineHeight: 1, color: "#ffe08a" }}>{c.score}</div>
                            </div>

                            {c.expired ? (
                                <p className="p hostSub">{tr("Diese Herausforderung ist abgelaufen.")}</p>
                            ) : (
                                <>
                                    {user ? (
                                        name ? <AccountNameNote name={name} /> : null
                                    ) : (
                                        <div className="fieldBlock">
                                            <div className="fieldTitle">{tr("Dein Name")}</div>
                                            <input className="pillInput" style={{ width: "100%" }} value={shownName} onChange={(e) => setTypedName(e.target.value)} maxLength={24} placeholder={tr("z. B. Steve")} aria-label={tr("Dein Name")} />
                                            {name && "message" in validation ? <div className="fieldHelp fieldHelpError">{validation.message}</div> : null}
                                        </div>
                                    )}
                                    {error ? <div className="fieldHelp fieldHelpError" style={{ marginTop: 8 }}>{error}</div> : null}
                                    <button type="button" className="btn btnPrimary" style={{ marginTop: 14, width: "100%" }} onClick={() => void start()} disabled={busy || !validation.ok}>
                                        {busy ? <Spinner size={16} label={tr("Starte…")} /> : `⚔️ ${tr("Herausforderung annehmen")}`}
                                    </button>
                                </>
                            )}

                            {c.results.length ? (
                                <div style={{ marginTop: 20 }}>
                                    <div style={{ fontSize: 13, fontWeight: 800, opacity: 0.8, marginBottom: 6 }}>{tr("Bisherige Versuche")}</div>
                                    <div style={{ display: "grid", gap: 4 }}>
                                        {c.results.map((r, i) => (
                                            <div key={i} style={{ display: "flex", justifyContent: "space-between", gap: 10, padding: "7px 12px", borderRadius: 10, background: "rgba(255,255,255,.07)", fontWeight: 700, fontSize: 14 }}>
                                                <span>
                                                    {medal[i] ?? i + 1} {r.name}
                                                </span>
                                                <span style={{ color: r.score > c.score ? "#a7f3d0" : "inherit" }}>{r.score}</span>
                                            </div>
                                        ))}
                                    </div>
                                </div>
                            ) : null}
                        </>
                    )}
                </section>
            </div>
        </main>
    );
}
