"use client";

import { use, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { AccountNameNote } from "@/components/AccountNameNote";
import { HomeButton } from "@/components/BackButton";
import { Spinner } from "@/components/Spinner";
import { BackdropFx } from "@/components/game/BackdropFx";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
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
 * Look (Wunsch Mehdi 2026-11-02): Duell-Bühne mit Gesicht des Herausforderers, großer leuchtender Punktzahl und Modus-Farbe.
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
        <main className="chMain">
            <BackdropFx variant="warm" rays vignette />
            <section className="chCard" aria-label={tr("Herausforderung")} data-mode={c?.mode ?? ""}>
                <HomeButton corner />
                {!res ? (
                    <div className="chSkel" aria-busy>
                        <i className="sk w60" />
                        <i className="sk big" />
                        <i className="sk w80" />
                    </div>
                ) : !c ? (
                    <>
                        <h1 className="chTitle">⚔️ {tr("Herausforderung")}</h1>
                        <p className="chSub">{tr("Diese Herausforderung gibt es nicht (mehr).")}</p>
                    </>
                ) : (
                    <>
                        <div className="chVs" aria-hidden>
                            <div className="chSide">
                                <div className="chAv">
                                    <PlayerAvatar seed={c.creator} size={86} />
                                </div>
                                <b>{c.creator}</b>
                            </div>
                            <div className="chSwords">⚔️</div>
                            <div className="chSide">
                                <div className="chAv ghost">?</div>
                                <b>{name || tr("Du")}</b>
                            </div>
                        </div>
                        <h1 className="chTitle">{tr("{name} fordert dich heraus!", { name: c.creator })}</h1>
                        <p className="chSub">
                            <span className="chMode">{mode ? `${mode.icon} ${tr(mode.label)}` : c.mode}</span> · {tr("allein gegen {n} Bots", { n: c.bots })}
                        </p>
                        <div className="chScore">
                            <div className="chScoreLabel">{tr("Punkte zum Schlagen")}</div>
                            <div className="chScoreNum">{String(Number(c.score)).replace(".", ",")}</div>
                        </div>

                        {c.expired ? (
                            <p className="chSub">{tr("Diese Herausforderung ist abgelaufen.")}</p>
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
                                <button type="button" className="btn btnPrimary btnXL btnGlow chGo" onClick={() => void start()} disabled={busy || !validation.ok}>
                                    {busy ? <Spinner size={16} label={tr("Starte…")} /> : `⚔️ ${tr("Herausforderung annehmen")}`}
                                </button>
                            </>
                        )}

                        {c.results.length ? (
                            <div className="chList">
                                <div className="chListHead">{tr("Bisherige Versuche")}</div>
                                {c.results.map((r, i) => (
                                    <div key={i} className={`chRow ${r.score > c.score ? "beat" : ""}`}>
                                        <span>
                                            {medal[i] ?? i + 1} {r.name}
                                        </span>
                                        <b>{String(Number(r.score)).replace(".", ",")}</b>
                                    </div>
                                ))}
                            </div>
                        ) : null}
                    </>
                )}
            </section>
            <style>{`
        .chMain{ min-height: 100dvh; display: grid; place-items: center; padding: 20px 16px; color: #fff; position: relative; overflow: hidden; }
        .chCard{ position: relative; z-index: 2; width: min(480px, 100%); display: grid; gap: 12px; padding: 26px 22px 22px; border-radius: 26px; text-align: center;
          background: linear-gradient(180deg, rgba(48,14,10,.72), rgba(30,8,8,.8)); border: 1px solid rgba(255,255,255,.2); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
          box-shadow: 0 30px 80px rgba(0,0,0,.45), inset 0 1px 0 rgba(255,255,255,.18); animation: chIn .7s cubic-bezier(.16,1,.3,1) both; }
        @keyframes chIn{ from{ opacity: 0; transform: translateY(18px) scale(.97); } }
        .chVs{ display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; gap: 6px; margin-top: 18px; }
        .chSide{ display: grid; justify-items: center; gap: 6px; min-width: 0; }
        .chSide b{ font-size: 14px; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .chAv{ border-radius: 50%; padding: 4px; background: radial-gradient(circle at 38% 32%, rgba(255,246,214,.75), rgba(255,200,80,.28) 72%); box-shadow: 0 0 0 4px rgba(255,214,10,.5), 0 0 34px rgba(255,214,10,.4); animation: chBob 3.2s ease-in-out infinite; }
        .chAv.ghost{ width: 94px; height: 94px; display: grid; place-items: center; font-size: 40px; font-weight: 900; color: rgba(255,255,255,.55); background: rgba(255,255,255,.08); box-shadow: 0 0 0 3px rgba(255,255,255,.25); animation-delay: .6s; }
        @keyframes chBob{ 0%,100%{ transform: translateY(0); } 50%{ transform: translateY(-5px); } }
        .chSwords{ font-size: 38px; filter: drop-shadow(0 6px 10px rgba(0,0,0,.5)); animation: chClash 2.4s ease-in-out infinite; }
        @keyframes chClash{ 0%,100%{ transform: rotate(-8deg) scale(1); } 50%{ transform: rotate(8deg) scale(1.15); } }
        .chTitle{ margin: 4px 0 0; font-size: clamp(22px, 5vw, 30px); line-height: 1.1; font-weight: 800; letter-spacing: -.01em; }
        .chSub{ margin: 0; font-size: 14px; font-weight: 600; opacity: .85; }
        .chMode{ display: inline-block; padding: 2px 10px; border-radius: 999px; background: rgba(255,255,255,.16); border: 1px solid rgba(255,255,255,.28); font-weight: 800; }
        .chCard[data-mode="letters"] .chMode{ background: rgba(130,70,220,.4); border-color: rgba(190,150,255,.7); }
        .chCard[data-mode="buzzer"] .chMode{ background: rgba(220,50,40,.4); border-color: rgba(255,150,130,.7); }
        .chCard[data-mode="year"] .chMode{ background: rgba(40,150,200,.4); border-color: rgba(140,210,245,.7); }
        .chScore{ margin: 6px 0; padding: 16px 12px 14px; border-radius: 20px; background: radial-gradient(ellipse at 50% 0%, rgba(255,214,10,.28), rgba(255,255,255,.06) 70%); border: 1px solid rgba(255,224,138,.5); box-shadow: 0 0 40px rgba(255,214,10,.18); }
        .chScoreLabel{ font-size: 11.5px; font-weight: 800; letter-spacing: 2px; text-transform: uppercase; opacity: .85; }
        .chScoreNum{ font-family: var(--font-display); font-size: clamp(64px, 18vw, 92px); font-weight: 900; line-height: 1; color: #ffe08a; text-shadow: 0 0 30px rgba(255,214,10,.65), 0 6px 0 rgba(120,60,0,.5); font-variant-numeric: tabular-nums; }
        .chGo{ width: 100%; margin-top: 4px; }
        .chList{ display: grid; gap: 4px; margin-top: 8px; text-align: left; }
        .chListHead{ font-size: 12px; font-weight: 800; letter-spacing: 1px; text-transform: uppercase; opacity: .85; margin-bottom: 2px; }
        .chRow{ display: flex; justify-content: space-between; gap: 10px; padding: 8px 12px; border-radius: 12px; background: rgba(255,255,255,.07); font-weight: 700; font-size: 14px; }
        .chRow.beat{ background: rgba(60,200,120,.2); border: 1px solid rgba(120,240,170,.5); }
        .chSkel{ display: grid; gap: 14px; padding: 20px 4px; justify-items: center; }
        .sk{ display: block; height: 16px; border-radius: 10px; background: linear-gradient(90deg, rgba(255,255,255,.08), rgba(255,255,255,.22), rgba(255,255,255,.08)) 0 0 / 200% 100%; animation: skShim 1.3s linear infinite; }
        .sk.w60{ width: 60%; } .sk.w80{ width: 80%; } .sk.big{ width: 100%; height: 110px; border-radius: 20px; }
        @keyframes skShim{ to{ background-position: -200% 0; } }
        @media (prefers-reduced-motion: reduce){ .chCard, .chAv, .chSwords, .sk{ animation: none; } }
      `}</style>
        </main>
    );
}
