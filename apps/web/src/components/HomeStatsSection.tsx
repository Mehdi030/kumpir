"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useAuth } from "@/components/AuthProvider";
import { useAchievements } from "@/hooks/useAchievements";
import { useProfile } from "@/hooks/useProfile";
import { Spinner } from "@/components/Spinner";
import { CountUp } from "@/components/CountUp";
import { AccountStats } from "@/components/profile/AccountStats";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { seasonKey, type ProfileStats } from "@/lib/profileStats";
import { fmtNum, trNow, useI18n } from "@/lib/i18n";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

/**
 * Statistik-Sektion auf der Startseite (nur mit Konto). Kurzüberblick; ein Klick auf die Überschrift oder
 * "Mehr anzeigen" öffnet ein Pop-up mit allem (Verlauf, Musik-Werte, Gegner, Monats-Rückblick – Migration 076).
 *
 * variant (Hauptmenü ohne Scrollen, Wunsch Mehdi 2026-10-12):
 *   dock = feste Leiste links neben der Hauptkarte (breite Bildschirme, gegenüber der Freunde-Leiste)
 *   chip = eine Zeile/Knopf in der Hauptkarte (schmalere Bildschirme), öffnet das Pop-up
 *   card = Kasten in der Karte (alt)
 */
export function HomeStatsSection({ variant = "card" }: { variant?: "card" | "dock" | "chip" }) {
    const { tr } = useI18n();
    const { user, loading: authLoading } = useAuth();
    const { stats, unlocked, catalog, loading: statsLoading } = useAchievements(AUTH_DISABLED ? null : user?.id ?? null);
    const [open, setOpen] = useState(false);

    if (AUTH_DISABLED || authLoading || !user) return null;

    const fastest = stats?.fastest_pass_ms ? `${fmtNum(stats.fastest_pass_ms / 1000)} s` : "–";
    const quick: [string, string][] = [
        [tr("Runden"), String(stats?.games_played ?? 0)],
        [tr("Rundensiege"), String(stats?.wins ?? 0)],
        [tr("Weitergaben"), String(stats?.total_passes ?? 0)],
        [tr("Rettungen in letzter Sekunde"), String(stats?.total_clutch_passes ?? 0)],
        [tr("Schnellste Weitergabe"), fastest],
        [tr("Beste Serie"), String(stats?.best_survival_streak ?? 0)],
    ];

    if (variant === "chip") {
        return (
            <>
                <button type="button" className="homeChip" onClick={() => setOpen(true)} title={tr("Ganze Statistik anzeigen")}>
                    <span className="homeChipIcon" aria-hidden>
                        📊
                    </span>
                    <span className="homeChipText">
                        <b>{tr("Statistik")}</b>
                        <span>
                            {statsLoading ? "…" : tr("{n} Runden · {w} Siege", { n: stats?.games_played ?? 0, w: stats?.wins ?? 0 })}
                        </span>
                    </span>
                    <span className="homeChipArrow" aria-hidden>
                        ›
                    </span>
                </button>
                {open ? <StatsModal onClose={() => setOpen(false)} quick={quick} /> : null}
            </>
        );
    }

    return (
        <div className={`statsSectionCard ${variant === "dock" ? "statsDock" : ""}`}>
            <div className="statsSectionHead">
                <button type="button" className="statsHeadBtn" onClick={() => setOpen(true)} title={tr("Ganze Statistik anzeigen")}>
                    📊 {tr("Deine Statistik")} <span className="statsHeadArrow">›</span>
                </button>
                <Link href="/achievements" className="fieldHelp" style={{ fontWeight: 900 }}>
                    {tr("Alle Erfolge →")}
                </Link>
            </div>
            {statsLoading ? (
                <div style={{ display: "grid", placeItems: "center", padding: 16 }}>
                    <Spinner size={18} label={tr("Lade…")} />
                </div>
            ) : (
                <div className="statsGrid" style={{ marginTop: 10 }}>
                    <StatBox label={tr("Runden")} value={String(stats?.games_played ?? 0)} />
                    <StatBox label={tr("Rundensiege")} value={String(stats?.wins ?? 0)} />
                    <StatBox label={tr("Beste Serie")} value={String(stats?.best_survival_streak ?? 0)} />
                    <StatBox label={tr("Erfolge")} value={`${unlocked.length}/${catalog.length}`} />
                    {variant === "dock" ? (
                        <>
                            <StatBox label={tr("Weitergaben")} value={String(stats?.total_passes ?? 0)} />
                            <StatBox label={tr("Schnellste")} value={fastest} />
                        </>
                    ) : null}
                </div>
            )}
            <button type="button" className="statsMoreBtn" onClick={() => setOpen(true)}>
                {tr("Mehr anzeigen")}
            </button>

            {open ? <StatsModal onClose={() => setOpen(false)} quick={quick} /> : null}

            <style>{`
                .statsSectionCard{ margin-top: 18px; padding: 16px; border-radius: 18px; background: rgba(0,0,0,0.16); border: 1px solid rgba(255,255,255,0.10); display: grid; }
                .statsSectionHead{ display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
                .statsHeadBtn{ border: 0; background: none; color: #fff; font: inherit; font-weight: 900; font-size: 15px; letter-spacing: .3px; cursor: pointer; padding: 4px 6px; margin: -4px -6px; border-radius: 10px; display: inline-flex; align-items: center; gap: 6px; }
                .statsHeadBtn:hover{ background: rgba(255,255,255,.1); }
                .statsHeadArrow{ font-size: 20px; line-height: 1; transition: transform .2s ease; }
                .statsHeadBtn:hover .statsHeadArrow{ transform: translateX(3px); }
                .statsGrid{ display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 1fr)); gap: 8px; }
                .statsMoreBtn{ justify-self: center; margin-top: 12px; border: 1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.08); color: #fff; font: inherit; font-weight: 800; font-size: 13.5px; padding: 8px 18px; border-radius: 999px; cursor: pointer; }
                .statsMoreBtn:hover{ background: rgba(255,255,255,.16); }
                /* Leiste links (gegenüber der Freunde-Leiste, gleiche Breite/Optik) */
                .statsDock{
                  position: fixed; z-index: 5; margin: 0; left: 24px; top: 96px;
                  width: clamp(240px, calc((100vw - var(--homeW, 860px)) / 2 - 56px), 400px);
                  padding: 18px; border-radius: 26px; gap: 4px;
                  background: rgba(20,8,4,.5); border: 1px solid var(--glass-line);
                  backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); box-shadow: 0 18px 50px rgba(0,0,0,.25);
                  animation: kmRise .7s var(--ease-out) .2s backwards;
                }
                .statsDock .statsHeadBtn{ font-size: 20px; font-family: var(--font-display); }
                .statsDock .statsGrid{ grid-template-columns: 1fr 1fr; gap: 10px; }
            `}</style>
        </div>
    );
}

function StatsModal({ onClose, quick }: { onClose: () => void; quick: [string, string][] }) {
    const { tr } = useI18n();
    const { profile } = useProfile();
    const [season, setSeason] = useState(() => seasonKey(0));
    const [data, setData] = useState<ProfileStats | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    useEffect(() => {
        const onKey = (e: KeyboardEvent) => {
            if (e.key === "Escape") onClose();
        };
        window.addEventListener("keydown", onKey);
        const prev = document.body.style.overflow;
        document.body.style.overflow = "hidden";
        return () => {
            window.removeEventListener("keydown", onKey);
            document.body.style.overflow = prev;
        };
    }, [onClose]);

    useEffect(() => {
        let cancel = false;
        void (async () => {
            setLoading(true);
            const { data: d, error: e } = await getSupabaseClient().rpc("get_my_profile_stats", { p_season: season });
            if (cancel) return;
            setLoading(false);
            if (e) return setError(trNow("Statistik konnte nicht geladen werden."));
            setError("");
            setData(d as ProfileStats);
        })();
        return () => {
            cancel = true;
        };
    }, [season]);

    const name = profile?.displayName || profile?.username || tr("Du");

    // Direkt an <body> hängen: die Startseiten-Karte ist animiert, darin würde "position: fixed" festhängen
    return createPortal(
        <div className="stModalBack" onClick={onClose} role="presentation">
            <div className="stModal" role="dialog" aria-modal="true" aria-label={tr("Deine Statistik")} onClick={(e) => e.stopPropagation()}>
                <div className="stModalHead">
                    <h2>📊 {tr("Deine Statistik")}</h2>
                    <button type="button" className="stClose" onClick={onClose} aria-label={tr("Schließen")}>
                        ✕
                    </button>
                </div>
                <div className="stQuick">
                    {quick.map(([l, v]) => (
                        <div key={l} className="stQuickBox">
                            <div className="stQuickLabel">{l}</div>
                            <div className="stQuickValue">{v}</div>
                        </div>
                    ))}
                </div>
                {error ? <p className="fieldHelp fieldHelpError">{error}</p> : null}
                {data ? (
                    <AccountStats data={data} username={name} season={season} onSeasonChange={setSeason} seasonLoading={loading} />
                ) : loading ? (
                    <div style={{ display: "grid", placeItems: "center", padding: 30 }}>
                        <Spinner size={24} label={tr("Lade Statistik…")} />
                    </div>
                ) : null}
                <Link href="/stats" className="stProfileLink" onClick={onClose}>
                    {tr("Als eigene Seite öffnen →")}
                </Link>
            </div>
            <style>{`
                .stModalBack{ position: fixed; inset: 0; z-index: 4000; background: rgba(10,4,2,.62); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); display: grid; place-items: center; padding: 18px; animation: stFade .25s ease both; }
                .stModal{ width: min(920px, 100%); max-height: calc(100vh - 36px); overflow: auto; overscroll-behavior: contain; padding: 22px; border-radius: 28px;
                  background: linear-gradient(180deg, rgba(60,18,8,.96), rgba(32,10,6,.97)); border: 1px solid rgba(255,255,255,.18); box-shadow: 0 40px 120px rgba(0,0,0,.55);
                  display: grid; gap: 16px; animation: stPop .4s cubic-bezier(.16,1,.3,1) both; color: #fff; }
                .stModalHead{ display: flex; align-items: center; justify-content: space-between; gap: 10px; }
                .stModalHead h2{ margin: 0; font-size: 26px; }
                .stClose{ width: 40px; height: 40px; border-radius: 999px; border: 1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.08); color: #fff; font-size: 16px; cursor: pointer; }
                .stClose:hover{ background: rgba(255,255,255,.18); }
                .stQuick{ display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 10px; }
                .stQuickBox{ padding: 12px; border-radius: 16px; background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.12); display: grid; gap: 4px; text-align: center; }
                .stQuickLabel{ font-size: 10.5px; font-weight: 800; letter-spacing: .6px; text-transform: uppercase; opacity: .7; }
                .stQuickValue{ font-size: 22px; font-weight: 950; }
                .stProfileLink{ justify-self: end; font-weight: 900; color: #ffe08a; text-decoration: none; }
                @keyframes stFade{ from{ opacity: 0; } to{ opacity: 1; } }
                @keyframes stPop{ from{ opacity: 0; transform: translateY(18px) scale(.97); } to{ opacity: 1; transform: none; } }
            `}</style>
        </div>,
        document.body
    );
}

function StatBox({ label, value }: { label: string; value: string }) {
    return (
        <div
            style={{
                padding: 10,
                borderRadius: 14,
                background: "rgba(255,255,255,0.05)",
                border: "1px solid rgba(255,255,255,0.10)",
                display: "flex",
                flexDirection: "column",
                gap: 4,
                alignItems: "center",
                justifyContent: "center",
            }}
        >
            <div style={{ fontSize: 10, fontWeight: 800, opacity: 0.7, letterSpacing: 0.6, textTransform: "uppercase" }}>{label}</div>
            <div style={{ fontSize: 18, fontWeight: 950 }}>
                <CountUp value={value} />
            </div>
        </div>
    );
}
