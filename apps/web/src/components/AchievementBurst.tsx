"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { Achievement } from "@/lib/achievements";
import { TIER_STYLE } from "@/lib/achievements";
import { useI18n } from "@/lib/i18n";
import { playFx } from "@/lib/gameFx";

const RECAP_KEY = "kumpir_ach_recap";
const SHOW_MS = 2600;

type Stored = Pick<Achievement, "code" | "title" | "description" | "icon" | "tier">;

/** Erfolge merken, damit sie nach der Runde in Lobby/Hauptmenü noch einmal kurz unten rechts erscheinen. */
export function queueAchievementRecap(list: Achievement[]) {
    if (!list.length) return;
    try {
        const prev = JSON.parse(localStorage.getItem(RECAP_KEY) || "[]") as Stored[];
        const merged = [...prev.filter((p) => !list.some((a) => a.code === p.code)), ...list.map(({ code, title, description, icon, tier }) => ({ code, title, description, icon, tier }))];
        localStorage.setItem(RECAP_KEY, JSON.stringify(merged.slice(-6)));
    } catch {
        /* privater Modus */
    }
}

export function takeAchievementRecap(): Stored[] {
    try {
        const list = JSON.parse(localStorage.getItem(RECAP_KEY) || "[]") as Stored[];
        localStorage.removeItem(RECAP_KEY);
        return Array.isArray(list) ? list : [];
    } catch {
        return [];
    }
}

/**
 * Erfolg mitten in der Runde (Wunsch Mehdi 2026-10-13): das Emoji springt groß in der Bildschirmmitte auf,
 * darunter steht, was man freigeschaltet hat – nach gut 2 s ist es wieder weg. Mehrere nacheinander.
 * Blockiert keine Klicks (das Spiel läuft weiter).
 */
export function AchievementBurst({ achievements, onDone }: { achievements: Achievement[]; onDone: (code: string) => void }) {
    const { tr } = useI18n();
    const [mounted, setMounted] = useState(false);
    const cur = achievements[0] ?? null;
    // onDone kann sich bei jedem Rendern ändern (Spielseite rendert oft) – Zeitgeber trotzdem nur einmal pro Erfolg
    const doneRef = useRef(onDone);
    useEffect(() => {
        doneRef.current = onDone;
    }, [onDone]);

    useEffect(() => {
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setMounted(true);
    }, []);

    useEffect(() => {
        if (!cur) return;
        playFx("voteWin");
        const t = window.setTimeout(() => doneRef.current(cur.code), SHOW_MS);
        return () => window.clearTimeout(t);
    }, [cur?.code]); // eslint-disable-line react-hooks/exhaustive-deps

    if (!mounted || !cur || typeof document === "undefined") return null;
    const tier = TIER_STYLE[cur.tier] ?? TIER_STYLE.bronze;

    return createPortal(
        <div className="achBurst" key={cur.code} aria-live="polite" role="status">
            <div className="achBurstRing" style={{ borderColor: tier.border }} aria-hidden />
            <div className="achBurstIcon" aria-hidden>
                {cur.icon}
            </div>
            <div className="achBurstText" style={{ background: tier.bg, borderColor: tier.border, boxShadow: tier.glow }}>
                <small>{tr("🎉 Erfolg freigeschaltet")}</small>
                <b>{tr(cur.title)}</b>
                <span>{tr(cur.description)}</span>
            </div>
            <style>{`
        .achBurst{ position: fixed; inset: 0; z-index: 10000; pointer-events: none; display: grid; place-items: center; align-content: center; gap: 10px;
          animation: achOut .45s ease-in ${SHOW_MS - 450}ms forwards; }
        .achBurstIcon{ font-size: clamp(90px, 16vw, 150px); line-height: 1; filter: drop-shadow(0 14px 30px rgba(0,0,0,.45)); animation: achPop .7s cubic-bezier(.2,1.6,.4,1) both; }
        .achBurstRing{ position: absolute; width: 160px; height: 160px; border-radius: 50%; border: 6px solid; top: 50%; left: 50%; margin: -130px 0 0 -80px;
          animation: achRing .9s ease-out both; }
        .achBurstText{ display: grid; justify-items: center; gap: 2px; padding: 10px 20px; border-radius: 18px; border: 2px solid; color: #fff; text-align: center;
          backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px); max-width: min(420px, 90vw); animation: achText .5s .2s cubic-bezier(.16,1,.3,1) both; }
        .achBurstText small{ font-size: 11px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; opacity: .85; }
        .achBurstText b{ font-family: var(--font-display); font-size: clamp(22px, 3.4vw, 30px); font-weight: 900; }
        .achBurstText span{ font-size: 13px; font-weight: 700; opacity: .9; }
        @keyframes achPop{ 0%{ transform: scale(0) rotate(-25deg); opacity: 0; } 60%{ transform: scale(1.25) rotate(6deg); opacity: 1; } 100%{ transform: scale(1) rotate(0); } }
        @keyframes achRing{ from{ transform: scale(.3); opacity: .9; } to{ transform: scale(2.4); opacity: 0; } }
        @keyframes achText{ from{ opacity: 0; transform: translateY(14px) scale(.95); } }
        @keyframes achOut{ to{ opacity: 0; transform: scale(.92); } }
        @media (prefers-reduced-motion: reduce){ .achBurstIcon, .achBurstRing, .achBurstText{ animation: none !important; } }
      `}</style>
        </div>,
        document.body
    );
}
