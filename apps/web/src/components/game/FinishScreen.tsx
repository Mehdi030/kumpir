"use client";

import React, { useState } from "react";
import Link from "next/link";
import { PassStatsTable, type PassStatsRow } from "@/components/game/PassStatsTable";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { Spinner } from "@/components/Spinner";
import { ToastStack } from "@/components/ToastStack";
import { renderResultCard } from "@/lib/resultCard";
import { useI18n } from "@/lib/i18n";
import { track } from "@/lib/track";

export type FinishRow = PassStatsRow;

export type FinishHighlight = { label: string; icon: string; name: string; value: string };

type ToastItem = React.ComponentProps<typeof ToastStack>["toasts"];

type Props = {
    isSeries: boolean;
    totalRounds: number;
    winnerName: string;
    /** Eigener Platz + Punkte (Match-Gesamt bei mehreren Runden). */
    me: { place: number; score: number } | null;
    rows: FinishRow[];
    /** Kompakte Wertung für die teilbare Ergebniskarte (bei Match: Gesamtwertung). */
    shareRows: { place: number; name: string; score: number; isMe?: boolean }[];
    mePlayerId: string | null;
    highlights: FinishHighlight[];
    loggedIn: boolean;
    /** Mind. 2 Menschen -> zählt für Bestenliste/Statistik (Migration 075). */
    ranked: boolean;
    /** Nur zugeschaut (nicht mitgespielt): keine Rematch-/Lobby-Knöpfe. */
    spectator: boolean;
    /** Quiz-Modi (Buzzer, Jahr raten): keine Abgabezeiten und keine Titel-Spalten im Endstand */
    quizMode?: boolean;
    busy: "reset" | "rematch" | null;
    onRematch: () => void;
    onLobby: () => void;
    toasts: ToastItem;
};

/**
 * Endseite – passt ohne Scrollen auf den Bildschirm (Wunsch Mehdi 2026-10-12):
 * links Sieger + Highlights + Knöpfe, rechts EINE Wertung mit Punkten und schnellster/langsamster Abgabe
 * (bei mehreren Runden: Gesamtpunkte und die besten Werte über alle Runden). Auf dem Handy untereinander.
 */
export function FinishScreen({ isSeries, totalRounds, winnerName, me, rows, shareRows, highlights, loggedIn, ranked, spectator, quizMode = false, busy, onRematch, onLobby, toasts }: Props) {
    const { t, tr } = useI18n();
    const [shareMsg, setShareMsg] = useState("");
    const [shareBusy, setShareBusy] = useState(false);
    const podium = [...rows].sort((a, b) => a.place - b.place).slice(0, 3);

    const shareResult = async () => {
        if (shareBusy) return;
        track("result_share");
        setShareBusy(true);
        try {
            const blob = await renderResultCard({
                winnerName,
                isSeries,
                totalRounds,
                me,
                rows: shareRows,
                siteUrl: window.location.origin,
                labels: {
                    tagline: t("card.tagline"),
                    header: isSeries ? t("fin.match", { n: totalRounds }) : t("fin.round"),
                    wins: isSeries ? t("fin.winsMatch") : t("fin.winsRound"),
                    me: me ? t("card.me", { place: me.place, score: me.score }) : null,
                    pts: t("card.pts"),
                    cta: t("card.cta"),
                },
            });
            const file = new File([blob], "kumpir-ergebnis.png", { type: "image/png" });
            const nav = navigator as Navigator & { canShare?: (d: ShareData) => boolean };
            const text = me
                ? t("card.shareTextMe", { winner: winnerName, place: me.place, score: me.score, url: window.location.origin })
                : t("card.shareText", { winner: winnerName, url: window.location.origin });
            if (typeof nav.canShare === "function" && nav.canShare({ files: [file] })) {
                try {
                    await navigator.share({ files: [file], text, title: tr("Kumpir-Ergebnis") });
                    return;
                } catch (e) {
                    if (e instanceof Error && e.name === "AbortError") return;
                }
            }
            const a = document.createElement("a");
            a.href = URL.createObjectURL(blob);
            a.download = "kumpir-ergebnis.png";
            document.body.appendChild(a);
            a.click();
            a.remove();
            window.setTimeout(() => URL.revokeObjectURL(a.href), 4000);
            setShareMsg(t("fin.saved"));
            window.setTimeout(() => setShareMsg(""), 2500);
        } catch {
            setShareMsg(t("fin.shareFail"));
            window.setTimeout(() => setShareMsg(""), 2500);
        } finally {
            setShareBusy(false);
        }
    };

    return (
        <div className="finWrap">
            <div className="finLeft">
                <header className="finHero">
                    <div className="finKicker">{isSeries ? t("fin.match", { n: totalRounds }) : t("fin.round")}</div>
                    {podium.length >= 2 ? (
                        <div className="finPodium" aria-hidden>
                            {[podium[1], podium[0], podium[2]].map((r, i) =>
                                r ? (
                                    <div key={r.id} className={`finStep p${r.place}`} style={{ ["--d" as string]: `${[0.25, 0.05, 0.45][i]}s` }}>
                                        <div className="finStepAvatar">
                                            <PlayerAvatar seed={r.name} config={r.avatarConfig} size={r.place === 1 ? 84 : 60} />
                                            {r.place === 1 ? <span className="finCrown">👑</span> : null}
                                        </div>
                                        <div className="finStepName" title={r.name}>
                                            {r.name}
                                        </div>
                                        <div className="finStepBlock">
                                            <span className="finStepNo">{r.place}</span>
                                            <span className="finStepPts">{tr("{n} P.", { n: r.points })}</span>
                                        </div>
                                    </div>
                                ) : (
                                    <div key={`empty${i}`} />
                                )
                            )}
                        </div>
                    ) : (
                        <div className="finWinnerAvatar" aria-hidden>
                            <PlayerAvatar seed={winnerName} config={rows.find((r) => r.place === 1)?.avatarConfig} size={96} />
                            <span className="finTrophy">🏆</span>
                        </div>
                    )}
                    <h1 className="finWinner">{winnerName}</h1>
                    <div className="finSub">{isSeries ? t("fin.winsMatch") : t("fin.winsRound")}</div>
                    {me ? <div className="finMe">{t("fin.me", { place: me.place, score: me.score })}</div> : null}
                </header>

                {highlights.length > 0 ? (
                    <section className="finTiles" aria-label={tr("Highlights")}>
                        {highlights.map((h) => (
                            <div key={h.label} className="finTile">
                                <div className="finTileIcon" aria-hidden>
                                    {h.icon}
                                </div>
                                <div className="finTileLabel">{h.label}</div>
                                <div className="finTileName" title={h.name}>
                                    {h.name}
                                </div>
                                <div className="finTileValue">{h.value}</div>
                            </div>
                        ))}
                    </section>
                ) : null}

                <div className="finActions">
                    {spectator ? (
                        <Link href="/" className="btn btnSecondary">
                            {t("solo.home")}
                        </Link>
                    ) : (
                        <>
                            <button type="button" className="btn btnPrimary" onClick={onRematch} disabled={!!busy} title={tr("Direkt nochmal (Taste R)")}>
                                {busy === "rematch" ? <Spinner size={16} label={tr("Starte…")} /> : t("fin.again")}
                            </button>
                            <button type="button" className="btn btnSecondary" onClick={onLobby} disabled={!!busy}>
                                {busy === "reset" ? <Spinner size={16} label={tr("Lade…")} /> : t("fin.lobby")}
                            </button>
                        </>
                    )}
                    <button type="button" className="btn btnSecondary finShareBtn" onClick={() => void shareResult()} disabled={shareBusy} title={t("fin.share")} aria-label={t("fin.share")}>
                        {shareBusy ? <Spinner size={14} label={t("fin.shareBusy")} /> : "📤"}
                    </button>
                </div>
                <div className="finFoot">
                    {shareMsg ? (
                        <span className="finShareMsg" aria-live="polite">
                            {shareMsg}
                        </span>
                    ) : null}
                    {spectator ? (
                        <span>{t("fin.spectator")}</span>
                    ) : !ranked ? (
                        <span>{loggedIn ? t("fin.unrankedAccount") : t("fin.unranked")}</span>
                    ) : loggedIn ? (
                        <span className="ok">{t("fin.saved2")}</span>
                    ) : (
                        <span>
                            {t("fin.keep")}{" "}
                            <Link href="/register?next=/" className="finAccountLink">
                                {t("fin.create")}
                            </Link>
                        </span>
                    )}
                </div>
            </div>

            <div className="finRight">
                <PassStatsTable hideTimes={quizMode} rows={rows} title={isSeries ? `${t("fin.final")} · ${tr("alle {n} Runden", { n: totalRounds })}` : t("fin.final")} pointsLabel={isSeries ? tr("Gesamt") : tr("Punkte")} />
            </div>

            <ToastStack toasts={toasts} inline />

            <style>{`
        .finWrap{ width: min(1080px, calc(100vw - 32px)); position: relative; z-index: 2; display: grid; gap: 14px; align-items: center; align-content: center; min-height: calc(100dvh - 64px); padding: 0; }
        @media (min-width: 900px){ .finWrap{ grid-template-columns: minmax(0, .9fr) minmax(0, 1.25fr); gap: 26px; } }
        .finLeft{ display: grid; gap: 12px; align-content: center; }
        .finHero{ text-align: center; display: grid; justify-items: center; gap: 2px; animation: finIn .7s cubic-bezier(.16,1,.3,1) both; }
        .finKicker{ font-size: 12px; font-weight: 800; letter-spacing: 2px; text-transform: uppercase; opacity: .8; }
        .finWinnerAvatar{ position: relative; width: 104px; height: 104px; margin: 4px 0; border-radius: 50%; display: grid; place-items: center;
          background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.55), rgba(255,178,26,.25) 70%); box-shadow: 0 0 0 5px rgba(255,214,10,.35), 0 16px 40px rgba(0,0,0,.35); animation: finBob 3s ease-in-out infinite; }
        .finTrophy{ position: absolute; right: -6px; bottom: -4px; font-size: 32px; filter: drop-shadow(0 4px 8px rgba(0,0,0,.4)); }
        .finWinner{ margin: 0; font-size: clamp(30px, 5vw, 52px); line-height: 1.05; font-weight: 800; letter-spacing: -0.02em; text-shadow: 0 6px 30px rgba(0,0,0,.35); overflow-wrap: anywhere; }
        .finSub{ font-size: 14px; opacity: .8; font-weight: 600; }
        .finMe{ margin-top: 6px; padding: 6px 14px; border-radius: 999px; background: rgba(255,255,255,.14); border: 1px solid rgba(255,255,255,.25); font-size: 14px; }
        .finMe b{ font-weight: 800; }
        .finRight{ animation: finIn .7s .1s cubic-bezier(.16,1,.3,1) both; min-width: 0; }

        .finPodium{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); align-items: end; gap: 8px; width: min(420px, 100%); margin: 26px 0 2px; }
        .finStep{ display: grid; justify-items: center; gap: 4px; min-width: 0; animation: finRise .7s var(--d, 0s) cubic-bezier(.16,1,.3,1) both; }
        .finStepAvatar{ position: relative; border-radius: 50%; background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.45), rgba(255,178,26,.15) 70%); padding: 3px; }
        .finStep.p1 .finStepAvatar{ box-shadow: 0 0 0 4px rgba(255,214,10,.45), 0 0 36px rgba(255,214,10,.35); animation: finBob 3s ease-in-out infinite; }
        .finCrown{ position: absolute; top: -20px; left: 50%; transform: translateX(-50%) rotate(-8deg); font-size: 28px; filter: drop-shadow(0 4px 6px rgba(0,0,0,.4)); }
        .finStepName{ font-weight: 800; font-size: 13.5px; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .finStepBlock{ width: 100%; display: grid; justify-items: center; align-content: start; gap: 2px; padding-top: 8px; border-radius: 14px 14px 6px 6px;
          background: linear-gradient(180deg, rgba(255,255,255,.2), rgba(255,255,255,.06)); border: 1px solid rgba(255,255,255,.22); }
        .finStep.p1 .finStepBlock{ height: 92px; background: linear-gradient(180deg, rgba(255,214,10,.5), rgba(255,170,20,.14)); border-color: rgba(255,224,138,.7); }
        .finStep.p2 .finStepBlock{ height: 66px; background: linear-gradient(180deg, rgba(226,232,240,.42), rgba(226,232,240,.08)); }
        .finStep.p3 .finStepBlock{ height: 48px; background: linear-gradient(180deg, rgba(217,140,70,.45), rgba(217,140,70,.08)); }
        .finStepNo{ font-family: var(--font-display); font-size: 26px; font-weight: 900; line-height: 1; }
        .finStepPts{ font-size: 12px; font-weight: 800; color: #ffe08a; }
        @keyframes finRise{ from{ opacity: 0; transform: translateY(30px) scale(.9); } }
        .finTiles{ display: grid; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr)); gap: 8px; animation: finIn .7s .2s cubic-bezier(.16,1,.3,1) both; }
        .finTile{ border-radius: 16px; padding: 8px; text-align: center; background: rgba(30,8,8,.36); border: 1px solid rgba(255,255,255,.14); display: grid; justify-items: center; min-width: 0; }
        .finTileIcon{ font-size: 20px; }
        .finTileLabel{ font-size: 9.5px; font-weight: 800; letter-spacing: .8px; text-transform: uppercase; opacity: .65; }
        .finTileName{ font-size: 14.5px; font-weight: 800; max-width: 100%; overflow-wrap: anywhere; line-height: 1.15; }
        .finTileValue{ font-size: 13px; font-weight: 800; color: #ffe08a; }

        .finActions{ display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
        .finShareBtn{ padding-left: 14px; padding-right: 14px; }
        .finFoot{ display: grid; gap: 4px; justify-items: center; text-align: center; font-size: 12.5px; font-weight: 600; opacity: .85; }
        .finFoot .ok{ color: #a7f3d0; }
        .finAccountLink{ color: #2b0f04; background: #ffd23f; padding: 3px 10px; border-radius: 999px; font-weight: 800; text-decoration: none; }
        .finShareMsg{ font-size: 13px; font-weight: 700; }

        @keyframes finIn{ from{ opacity: 0; transform: translateY(14px); } to{ opacity: 1; transform: translateY(0); } }
        @keyframes finBob{ 0%,100%{ transform: translateY(0); } 50%{ transform: translateY(-5px); } }
        @media (max-width: 899px){
          .finWrap{ gap: 10px; }
          .finWinnerAvatar{ width: 72px; height: 72px; }
          .finStep.p1 .finStepBlock{ height: 70px; } .finStep.p2 .finStepBlock{ height: 50px; } .finStep.p3 .finStepBlock{ height: 36px; }
          .finStepAvatar img{ width: 48px !important; height: 48px !important; }
          .finStep.p1 .finStepAvatar img{ width: 64px !important; height: 64px !important; }
          .finWinnerAvatar img{ width: 66px; height: 66px; }
          .finTrophy{ font-size: 24px; }
          .finLeft{ gap: 8px; }
          .finActions .btn{ padding-top: 10px; padding-bottom: 10px; }
        }
      `}</style>
        </div>
    );
}
