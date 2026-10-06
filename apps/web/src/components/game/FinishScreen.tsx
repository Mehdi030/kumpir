"use client";

import React, { useState } from "react";
import Link from "next/link";
import { SeriesTable, type SeriesRow } from "@/components/game/SeriesTable";
import { Spinner } from "@/components/Spinner";
import { ToastStack } from "@/components/ToastStack";
import { renderResultCard } from "@/lib/resultCard";
import { useI18n } from "@/lib/i18n";

export type FinishRow = {
    id: string;
    name: string;
    place: number;
    score: number;
    songPoints: number;
    moves: number;
    isMe: boolean;
};

export type FinishHighlight = { label: string; icon: string; name: string; value: string };

type ToastItem = React.ComponentProps<typeof ToastStack>["toasts"];

type Props = {
    isSeries: boolean;
    totalRounds: number;
    winnerName: string;
    /** Eigener Platz + Punkte (Match-Gesamt bei mehreren Runden). */
    me: { place: number; score: number } | null;
    rows: FinishRow[];
    seriesRows: SeriesRow[];
    /** Kompakte Wertung für die teilbare Ergebniskarte (bei Match: Gesamtwertung). */
    shareRows: { place: number; name: string; score: number; isMe?: boolean }[];
    mePlayerId: string | null;
    highlights: FinishHighlight[];
    loggedIn: boolean;
    /** Mind. 2 Menschen -> zählt für Bestenliste/Statistik (Migration 075). */
    ranked: boolean;
    /** Nur zugeschaut (nicht mitgespielt): keine Rematch-/Lobby-Knöpfe. */
    spectator: boolean;
    busy: "reset" | "rematch" | null;
    onRematch: () => void;
    onLobby: () => void;
    toasts: ToastItem;
};

const MEDAL = ["🥇", "🥈", "🥉"];

/**
 * Endseite: ein Held (Sieger), EINE Wertung (Tabelle), kurze Highlights, zwei Buttons.
 * Bei mehreren Runden ist die Wertung die Match-Gesamtwertung (Punkte je Runde + Summe),
 * bei einer einzelnen Runde die Rundenwertung.
 */
export function FinishScreen({ isSeries, totalRounds, winnerName, me, rows, seriesRows, shareRows, mePlayerId, highlights, loggedIn, ranked, spectator, busy, onRematch, onLobby, toasts }: Props) {
    const { t } = useI18n();
    const [shareMsg, setShareMsg] = useState("");
    const [shareBusy, setShareBusy] = useState(false);

    const shareResult = async () => {
        if (shareBusy) return;
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
                    await navigator.share({ files: [file], text, title: "Kumpir-Ergebnis" });
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
            <header className="finHero">
                <div className="finKicker">{isSeries ? t("fin.match", { n: totalRounds }) : t("fin.round")}</div>
                <div className="finTrophy" aria-hidden>
                    🏆
                </div>
                <h1 className="finWinner">{winnerName}</h1>
                <div className="finSub">{isSeries ? t("fin.winsMatch") : t("fin.winsRound")}</div>
                {me ? (
                    <div className="finMe">
                        {t("fin.me", { place: me.place, score: me.score })}
                    </div>
                ) : null}
            </header>

            {isSeries ? (
                <SeriesTable rows={seriesRows} totalSets={totalRounds} playedSets={totalRounds} mePlayerId={mePlayerId} title={t("fin.final")} />
            ) : (
                <section className="finCard">
                    <h2 className="finCardTitle">{t("fin.final")}</h2>
                    <div className="finTable" role="table">
                        <div className="finRow finHead" role="row">
                            <span>#</span>
                            <span>{t("fin.player")}</span>
                            <span className="r">{t("fin.points")}</span>
                            <span className="r" title="Richtig erratene Songs">♪ Treffer</span>
                            <span className="r" title="Überlebte Züge">Züge</span>
                        </div>
                        {rows.map((r) => (
                            <div key={r.id} className={`finRow ${r.isMe ? "me" : ""} ${r.place === 1 ? "first" : ""}`} role="row">
                                <span>{MEDAL[r.place - 1] ?? r.place}</span>
                                <span className="finName">{r.name}</span>
                                <span className="r finPts">{r.score}</span>
                                <span className="r">{r.songPoints > 0 ? (Math.round(r.songPoints * 2) / 2).toString().replace(".", ",") : "–"}</span>
                                <span className="r">{r.moves}</span>
                            </div>
                        ))}
                    </div>
                </section>
            )}

            {highlights.length > 0 ? (
                <section className="finTiles" aria-label="Highlights">
                    {highlights.map((h) => (
                        <div key={h.label} className="finTile">
                            <div className="finTileIcon" aria-hidden>
                                {h.icon}
                            </div>
                            <div className="finTileLabel">{h.label}</div>
                            <div className="finTileName">{h.name}</div>
                            <div className="finTileValue">{h.value}</div>
                        </div>
                    ))}
                </section>
            ) : null}

            {spectator ? (
                <div className="finAccount">{t("fin.spectator")}</div>
            ) : !ranked ? (
                <div className="finAccount">{t("fin.unranked")}</div>
            ) : loggedIn ? (
                <div className="finAccount ok">{t("fin.saved2")}</div>
            ) : (
                <div className="finAccount">
                    <span>{t("fin.keep")}</span>
                    <Link href="/register?next=/" className="finAccountLink">
                        {t("fin.create")}
                    </Link>
                </div>
            )}

            {spectator ? (
                // Zuschauer: Die Lobby ist noch gesperrt – sobald der Host zurück zur Lobby geht,
                // zeigt die Spielseite automatisch "Jetzt mitspielen".
                <div className="finActions">
                    <Link href="/" className="btn btnSecondary btnXL">
                        {t("solo.home")}
                    </Link>
                </div>
            ) : (
                <div className="finActions">
                    <button type="button" className="btn btnPrimary btnXL" onClick={onRematch} disabled={!!busy} title="Direkt nochmal (Taste R)">
                        {busy === "rematch" ? <Spinner size={16} label="Starte…" /> : t("fin.again")}
                    </button>
                    <button type="button" className="btn btnSecondary btnXL" onClick={onLobby} disabled={!!busy}>
                        {busy === "reset" ? <Spinner size={16} label="Lade…" /> : t("fin.lobby")}
                    </button>
                </div>
            )}
            <div className="finShare">
                <button type="button" className="btn btnSecondary btnSmall" onClick={() => void shareResult()} disabled={shareBusy}>
                    {shareBusy ? <Spinner size={14} label={t("fin.shareBusy")} /> : t("fin.share")}
                </button>
                <span className="finShareMsg" aria-live="polite">
                    {shareMsg}
                </span>
            </div>
            {spectator ? null : <div className="finHint">{t("fin.tip")}</div>}

            <ToastStack toasts={toasts} inline />

            <style>{`
        .finWrap{ width: min(820px, calc(100vw - 32px)); position: relative; z-index: 2; display: grid; gap: 18px; padding: 8px 0 28px; }
        .finHero{ text-align: center; display: grid; justify-items: center; gap: 4px; animation: finIn .7s cubic-bezier(.16,1,.3,1) both; }
        .finKicker{ font-size: 12px; font-weight: 800; letter-spacing: 2px; text-transform: uppercase; opacity: .8; }
        .finTrophy{
          width: 76px; height: 76px; border-radius: 50%; display: grid; place-items: center; font-size: 40px; margin: 6px 0 2px;
          background: radial-gradient(circle at 35% 30%, #ffe27a, #ffb21a 70%);
          box-shadow: 0 0 0 6px rgba(255,255,255,.18), 0 16px 40px rgba(0,0,0,.35);
          animation: finBob 3s ease-in-out infinite;
        }
        .finWinner{ margin: 0; font-size: clamp(38px, 8vw, 68px); line-height: 1.05; font-weight: 800; letter-spacing: -0.02em; text-shadow: 0 6px 30px rgba(0,0,0,.35); word-break: break-word; }
        .finSub{ font-size: 15px; opacity: .8; font-weight: 600; }
        .finMe{ margin-top: 10px; padding: 8px 16px; border-radius: 999px; background: rgba(255,255,255,.14); border: 1px solid rgba(255,255,255,.25); font-size: 15px; }
        .finMe b{ font-weight: 800; }

        .finCard{ border-radius: 24px; padding: 18px; background: rgba(30,8,8,.42); border: 1px solid rgba(255,255,255,.16); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); box-shadow: 0 18px 50px rgba(0,0,0,.28); animation: finIn .7s .1s cubic-bezier(.16,1,.3,1) both; }
        .finCardTitle{ margin: 0 0 10px; font-size: 18px; font-weight: 800; }
        .finTable{ display: grid; gap: 6px; }
        .finRow{ display: grid; grid-template-columns: 38px 1fr 76px 72px 54px; gap: 8px; align-items: center; padding: 10px 12px; border-radius: 14px; background: rgba(255,255,255,.07); font-weight: 600; }
        .finRow.finHead{ background: none; padding-top: 0; padding-bottom: 2px; font-size: 11px; font-weight: 800; letter-spacing: 1px; text-transform: uppercase; opacity: .65; }
        .finRow.first{ background: rgba(255,214,10,.16); border: 1px solid rgba(255,214,10,.4); }
        .finRow.me{ box-shadow: inset 0 0 0 2px rgba(34,211,238,.6); }
        .finRow .r{ text-align: right; }
        .finName{ font-weight: 800; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .finPts{ font-weight: 800; color: #ffe08a; }

        .finTiles{ display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; animation: finIn .7s .2s cubic-bezier(.16,1,.3,1) both; }
        .finTile{ border-radius: 20px; padding: 14px; text-align: center; background: rgba(30,8,8,.36); border: 1px solid rgba(255,255,255,.14); display: grid; gap: 2px; justify-items: center; }
        .finTileIcon{ font-size: 26px; }
        .finTileLabel{ font-size: 11px; font-weight: 800; letter-spacing: 1.2px; text-transform: uppercase; opacity: .65; }
        .finTileName{ font-size: 18px; font-weight: 800; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .finTileValue{ font-size: 14px; font-weight: 700; color: #ffe08a; }

        .finAccount{ display: flex; gap: 10px; align-items: center; justify-content: center; flex-wrap: wrap; padding: 12px 16px; border-radius: 16px; background: rgba(255,255,255,.10); border: 1px solid rgba(255,255,255,.2); font-size: 14px; font-weight: 600; text-align: center; }
        .finAccount.ok{ background: rgba(60,200,110,.18); border-color: rgba(110,230,150,.45); }
        .finAccountLink{ color: #2b0f04; background: #ffd23f; padding: 6px 14px; border-radius: 999px; font-weight: 800; text-decoration: none; }
        .finActions{ display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; margin-top: 4px; }
        .finShare{ display: flex; gap: 10px; align-items: center; justify-content: center; flex-wrap: wrap; }
        .finShareMsg{ font-size: 13px; font-weight: 700; opacity: .85; }
        .finHint{ text-align: center; font-size: 12px; opacity: .6; }

        @keyframes finIn{ from{ opacity: 0; transform: translateY(14px); } to{ opacity: 1; transform: translateY(0); } }
        @keyframes finBob{ 0%,100%{ transform: translateY(0); } 50%{ transform: translateY(-5px); } }
        @media (max-width: 520px){ .finRow{ grid-template-columns: 30px 1fr 56px 56px; padding: 9px 10px; font-size: 14px; } .finRow > :nth-child(5){ display: none; } .finName{ white-space: normal; } }
      `}</style>
        </div>
    );
}
