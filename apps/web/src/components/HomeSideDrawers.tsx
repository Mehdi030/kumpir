"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { useAuth } from "@/components/AuthProvider";
import { HomeFriends } from "@/components/HomeFriends";
import { HomeStatsSection } from "@/components/HomeStatsSection";
import { useFriendsStatus } from "@/hooks/useFriendsStatus";
import { useI18n } from "@/lib/i18n";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

/**
 * Statistik (links) und Freunde (rechts) als eingeklappte Laschen am Bildschirmrand (Wunsch Mehdi 2026-10-25): sie nehmen fast
 * keinen Platz weg. Ein Klick klappt die Leiste mit einer weichen Animation auf (von der Lasche aus entrollt, Inhalt kommt gestaffelt
 * hinterher); Klick daneben, Esc oder ✕ klappt sie wieder ein. Es ist immer nur eine offen.
 */
export function HomeSideDrawers() {
    const { user } = useAuth();
    const [active, setActive] = useState<"stats" | "friends" | null>(null);
    const close = useCallback(() => setActive(null), []);
    useEffect(() => {
        if (!active) return;
        const onKey = (e: KeyboardEvent) => e.key === "Escape" && setActive(null);
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [active]);

    const online = useFriendsStatus(!AUTH_DISABLED && user ? user.id : null);
    const onlineCount = online.friends.filter((f) => f.online).length;

    return (
        <>
            {active ? <div className="sdScrim" onClick={close} role="presentation" /> : null}
            {!AUTH_DISABLED && user ? (
                <Drawer side="left" icon="📊" label="Statistik" open={active === "stats"} onToggle={() => setActive(active === "stats" ? null : "stats")} onClose={close}>
                    <HomeStatsSection variant="panel" />
                </Drawer>
            ) : null}
            {!AUTH_DISABLED ? (
                <Drawer
                    side="right"
                    icon="👥"
                    label="Freunde"
                    badge={onlineCount > 0 ? String(onlineCount) : undefined}
                    open={active === "friends"}
                    onToggle={() => setActive(active === "friends" ? null : "friends")}
                    onClose={close}
                >
                    <HomeFriends inModal withOpenLobbies />
                </Drawer>
            ) : null}
            <style>{STYLES}</style>
        </>
    );
}

function Drawer({ side, icon, label, badge, open, onToggle, onClose, children }: { side: "left" | "right"; icon: string; label: string; badge?: string; open: boolean; onToggle: () => void; onClose: () => void; children: ReactNode }) {
    const { tr } = useI18n();
    // Inhalt erst beim ersten Aufklappen laden (spart Anfragen), danach bleibt er stehen
    const [loaded, setLoaded] = useState(false);
    const id = `sd-${side}`;
    return (
        <aside className={`sd ${side} ${open ? "open" : ""}`}>
            <button type="button" className="sdTab" onClick={() => {
                    setLoaded(true);
                    onToggle();
                }}
                aria-expanded={open} aria-controls={id} title={tr(label)}>
                <span className="sdTabIcon" aria-hidden>
                    {icon}
                </span>
                <span className="sdTabLabel">{tr(label)}</span>
                {badge ? <span className="sdTabBadge">{badge}</span> : null}
            </button>
            <div id={id} className="sdPanel" role="region" aria-label={tr(label)} aria-hidden={!open} inert={!open}>
                <button type="button" className="sdClose" onClick={onClose} aria-label={tr("Schließen")}>
                    ✕
                </button>
                <div className="sdBody">{loaded ? children : null}</div>
            </div>
        </aside>
    );
}

const STYLES = `
.sdScrim{ position: fixed; inset: 0; z-index: 40; background: radial-gradient(ellipse at 50% 40%, rgba(20,6,2,.12), rgba(20,6,2,.46)); animation: sdFade .35s ease both; }
@keyframes sdFade{ from{ opacity: 0; } }
.sd{ position: fixed; top: 0; bottom: 0; z-index: 45; width: 0; pointer-events: none; }
.sd.left{ left: 0; } .sd.right{ right: 0; }
.sd > *{ pointer-events: auto; }

/* Lasche am Rand: schmal, schwebt leise, rückt beim Drüberfahren etwas heraus */
.sdTab{ position: absolute; top: 50%; display: grid; justify-items: center; gap: 8px; width: 40px; padding: 14px 0 16px; border: 1px solid var(--glass-line, rgba(255,255,255,.26)); cursor: pointer; color: #fff; font: inherit;
  background: linear-gradient(180deg, rgba(60,16,6,.78), rgba(32,8,3,.82)); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
  box-shadow: 0 10px 30px rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.18);
  transition: transform .45s cubic-bezier(.16,1,.3,1), opacity .3s ease, background .25s ease, box-shadow .25s ease; animation: sdBreath 3.4s ease-in-out infinite; }
.sd.left .sdTab{ left: 0; border-left: 0; border-radius: 0 16px 16px 0; transform: translateY(-50%) translateX(-4px); }
.sd.right .sdTab{ right: 0; border-right: 0; border-radius: 16px 0 0 16px; transform: translateY(-50%) translateX(4px); }
.sd.left .sdTab:hover, .sd.left .sdTab:focus-visible{ transform: translateY(-50%) translateX(4px); background: linear-gradient(180deg, rgba(120,40,10,.9), rgba(60,16,6,.9)); }
.sd.right .sdTab:hover, .sd.right .sdTab:focus-visible{ transform: translateY(-50%) translateX(-4px); background: linear-gradient(180deg, rgba(120,40,10,.9), rgba(60,16,6,.9)); }
.sd.open .sdTab{ opacity: 0; pointer-events: none; }
@keyframes sdBreath{ 0%, 100%{ box-shadow: 0 10px 30px rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.18), 0 0 0 0 rgba(255,170,50,0); } 50%{ box-shadow: 0 10px 30px rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.18), 0 0 18px 2px rgba(255,170,50,.4); } }
.sdTabIcon{ font-size: 20px; line-height: 1; }
.sdTabLabel{ writing-mode: vertical-rl; font-family: var(--font-display); font-weight: 800; font-size: 13px; letter-spacing: 1.4px; text-transform: uppercase; opacity: .92; }
.sd.left .sdTabLabel{ transform: rotate(180deg); }
.sdTabBadge{ min-width: 20px; height: 20px; padding: 0 5px; border-radius: 999px; display: grid; place-items: center; font-size: 11.5px; font-weight: 900; color: #04210f; background: #34d399; box-shadow: 0 0 10px #34d399; }

/* Leiste: wird von der Lasche aus aufgeklappt (Beschnitt wächst vom Rand her), Inhalt rollt leicht gestaffelt ein */
.sdPanel{ position: absolute; top: 76px; width: min(390px, calc(100vw - 28px)); max-height: calc(100dvh - 104px); overflow: auto; overscroll-behavior: contain; padding: 18px 16px 16px; border-radius: 28px;
  background: linear-gradient(180deg, rgba(58,16,7,.93), rgba(30,8,4,.95)); border: 1px solid rgba(255,255,255,.2); box-shadow: 0 30px 80px rgba(0,0,0,.55), 0 0 0 1px rgba(255,170,50,.08);
  backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); visibility: hidden; opacity: 0;
  transition: clip-path .6s cubic-bezier(.16,1,.3,1), transform .6s cubic-bezier(.16,1,.3,1), opacity .35s ease, visibility 0s linear .6s; }
.sd.left .sdPanel{ left: 14px; transform: translateX(-26px) scale(.94); clip-path: inset(0 100% 0 0 round 28px); transform-origin: left center; }
.sd.right .sdPanel{ right: 14px; transform: translateX(26px) scale(.94); clip-path: inset(0 0 0 100% round 28px); transform-origin: right center; }
.sd.open .sdPanel{ visibility: visible; opacity: 1; transform: none; clip-path: inset(0 0 0 0 round 28px); transition-delay: 0s; }
.sdClose{ position: absolute; top: 12px; right: 12px; z-index: 3; width: 34px; height: 34px; border-radius: 999px; border: 1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.08); color: #fff; font-size: 14px; cursor: pointer; transition: background .2s ease, transform .3s ease; }
.sdClose:hover{ background: rgba(255,255,255,.2); transform: rotate(90deg); }
.sdBody > *{ opacity: 0; transform: translateY(10px); }
.sd.open .sdBody > *{ opacity: 1; transform: none; transition: opacity .45s ease .22s, transform .55s cubic-bezier(.16,1,.3,1) .22s; }

/* Inhalte im Panel: ohne eigene Karte/Rand, Überschrift Platz für den ✕-Knopf */
.sdPanel .statsSectionCard, .sdPanel .frSec{ margin: 0; padding: 0; background: transparent; border: 0; box-shadow: none; backdrop-filter: none; -webkit-backdrop-filter: none; animation: none; position: static; width: auto; min-height: 0; max-height: none; overflow: visible; }
.sdPanel .statsSectionHead, .sdPanel .frHead{ padding-right: 40px; }
.sdPanel .statsGrid{ grid-template-columns: 1fr 1fr; gap: 10px; }
.sdPanel .statsHeadBtn{ font-size: 20px; font-family: var(--font-display); }

@media (max-width: 520px){
  .sdTab{ width: 30px; padding: 11px 0 12px; gap: 6px; }
  .sdTabIcon{ font-size: 17px; }
  .sdTabLabel{ font-size: 11px; letter-spacing: 1px; }
  .sdPanel{ top: 64px; max-height: calc(100dvh - 84px); }
  .sd.left .sdPanel{ left: 10px; } .sd.right .sdPanel{ right: 10px; }
}
@media (prefers-reduced-motion: reduce){
  .sdTab{ animation: none; }
  .sdPanel, .sd.open .sdPanel, .sdBody > *, .sd.open .sdBody > *{ transition: none !important; clip-path: none !important; }
}
`;
