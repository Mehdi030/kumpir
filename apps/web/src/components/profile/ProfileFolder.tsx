"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { useProfile } from "@/hooks/useProfile";
import { useI18n } from "@/lib/i18n";
import { tk } from "@/lib/i18nMark";

export type ProfileTabKey = "profil" | "stats" | "achievements" | "friends" | "leaderboard";

const TABS: { key: ProfileTabKey; href: string; icon: string; label: string; sub: string }[] = [
    { key: "profil", href: "/profile", icon: "👤", label: tk("Profil & Konto"), sub: tk("Name, Figur, Konto") },
    { key: "stats", href: "/stats", icon: "📊", label: tk("Statistik"), sub: tk("Verlauf, Musik-Werte, Gegner") },
    { key: "achievements", href: "/achievements", icon: "🏅", label: tk("Erfolge"), sub: tk("Freigeschaltete Erfolge") },
    { key: "friends", href: "/friends", icon: "👥", label: tk("Freunde"), sub: tk("Freunde & Anfragen") },
    { key: "leaderboard", href: "/leaderboard", icon: "🏆", label: tk("Bestenliste"), sub: tk("Saison & Allzeit") },
];

/**
 * Gemeinsamer Rahmen für Profil, Statistik, Erfolge, Freunde und Bestenliste (Wunsch Mehdi 2026-10-14):
 * die Karte steht links, rechts daneben kleben die Reiter wie bei einer Akte – von jeder dieser Seiten kommt man
 * mit einem Klick zu jeder anderen (nicht nur zurück ins Hauptmenü). Schmal: Reiter oben über der Karte.
 */
export function ProfileFolder({ active, label, children }: { active: ProfileTabKey; label?: string; children: ReactNode }) {
    const { tr } = useI18n();
    const { profile } = useProfile();
    const tabs = [
        ...TABS,
        ...(profile?.isStaff ? [{ key: "admin" as const, href: "/admin", icon: "🛡️", label: tk("Admin-Panel"), sub: profile.role === "admin" ? "Admin" : "Supporter" }] : []),
    ];

    return (
        <div className="profWrap">
            <div className="profFolder">
                <section className="card profCard" aria-label={label}>
                    {children}
                </section>

                <nav className="profTabs" aria-label={tr("Bereiche")}>
                    {tabs.map((t, i) => (
                        <Link
                            key={t.key}
                            href={t.href}
                            className={`profTab ${t.key === active ? "on" : ""}`}
                            style={{ ["--i" as string]: i }}
                            title={tr(t.sub)}
                            aria-current={t.key === active ? "page" : undefined}
                        >
                            <span className="profTabIcon" aria-hidden>
                                {t.icon}
                            </span>
                            <span className="profTabText">
                                <b>{tr(t.label)}</b>
                                <small>{tr(t.sub)}</small>
                            </span>
                        </Link>
                    ))}
                </nav>
            </div>

            <style>{`
        .profWrap{ width: min(1160px, 100%); }
        .profFolder{ display: grid; grid-template-columns: minmax(0, 1fr) 200px; align-items: start; width: 100%; }
        .profCard{ position: relative; z-index: 1; }
        /* Reiter wie bei einer Akte: kleben rechts an der Karte */
        .profTabs{ display: grid; gap: 8px; padding-top: 34px; margin-left: -2px; }
        .profTab{ display: flex; align-items: center; gap: 10px; padding: 12px 14px 12px 16px; border-radius: 0 18px 18px 0; color: #fff; text-decoration: none;
          background: linear-gradient(90deg, rgba(60,14,8,.78), rgba(90,24,10,.62)); border: 1px solid rgba(255,255,255,.16); border-left: 0;
          box-shadow: 6px 8px 22px rgba(0,0,0,.22); transform-origin: left center;
          transition: transform .2s cubic-bezier(.22,1,.36,1), background .2s ease, padding .2s ease;
          animation: profTabIn .45s cubic-bezier(.22,1,.36,1) backwards; animation-delay: calc(var(--i, 0) * 60ms + 150ms); }
        .profTab:hover{ transform: translateX(6px); background: linear-gradient(90deg, rgba(120,36,10,.85), rgba(160,60,14,.7)); }
        .profTab.on{ background: linear-gradient(90deg, #ffd23f, #ffb21a); color: #2b1600; border-color: rgba(255,210,63,.9); transform: translateX(-4px); padding-right: 18px; box-shadow: 0 8px 24px rgba(255,178,26,.28); }
        .profTab.on .profTabText small{ opacity: .8; }
        .profTabIcon{ font-size: 22px; flex: none; }
        .profTabText{ display: grid; min-width: 0; line-height: 1.15; }
        .profTabText b{ font-size: 14.5px; font-weight: 900; }
        .profTabText small{ font-size: 11px; opacity: .72; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        @keyframes profTabIn{ from{ opacity: 0; transform: translateX(-24px); } }

        /* schmal: Reiter oben über der Karte */
        @media (max-width: 860px){
          .profFolder{ grid-template-columns: 1fr; }
          .profTabs{ order: -1; grid-auto-flow: column; grid-auto-columns: minmax(64px, 1fr); padding: 0 10px; margin: 0 0 -2px; overflow-x: auto; }
          .profTab{ border-radius: 16px 16px 0 0; border: 1px solid rgba(255,255,255,.16); border-bottom: 0; flex-direction: column; gap: 2px; padding: 9px 6px; text-align: center; box-shadow: none; }
          .profTab:hover{ transform: translateY(-3px); }
          .profTab.on{ transform: none; padding-right: 6px; }
          .profTabText small{ display: none; }
          .profTabText b{ font-size: 11.5px; }
          .profTabIcon{ font-size: 20px; }
          @keyframes profTabIn{ from{ opacity: 0; transform: translateY(12px); } }
        }
        @media (prefers-reduced-motion: reduce){ .profTab{ animation: none; } }
      `}</style>
        </div>
    );
}
