"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { createPortal } from "react-dom";

/**
 * Zeigt "Du hast die Lobby verlassen" / "Du wurdest gekickt" auf der
 * Startseite an, nachdem lobby/[code]/page.tsx dorthin umgeleitet hat
 * (?left=1 / ?kicked=1). Lebt auf "/" statt auf "/host" -- wer nur einer
 * fremden Lobby beigetreten war, landet sonst unpassend auf der
 * "Lobby erstellen"-Seite statt im eigentlichen Hauptmenü.
 */
export function LobbyExitNotice() {
    const router = useRouter();
    const sp = useSearchParams();

    const kicked = sp.get("kicked") === "1";
    const left = sp.get("left") === "1";

    const initialReason = kicked ? "kicked" : left ? "left" : null;
    const [reason, setReason] = useState<"kicked" | "left" | null>(initialReason);

    const dismissTopToast = useCallback(() => {
        setReason(null);
    }, []);

    useEffect(() => {
        if (initialReason) {
            router.replace("/");
        }
    }, [initialReason, router]);

    // Erst nach dem Laden im Browser zeigen (Portal gibt es auf dem Server nicht)
    const [mounted, setMounted] = useState(false);
    useEffect(() => {
        const t = window.setTimeout(() => setMounted(true), 0);
        return () => window.clearTimeout(t);
    }, []);

    // Kurzes Pop-up oben in der Mitte, verschwindet nach 2,5 s von selbst
    // (hängt an "reason", nicht an der Adresse – die wird gleich auf "/" gekürzt)
    useEffect(() => {
        if (!reason) return;
        const t = window.setTimeout(() => setReason(null), 2500);
        return () => window.clearTimeout(t);
    }, [reason]);

    const topToast = reason === "kicked" ? "⛔ Du wurdest aus der Lobby entfernt." : reason === "left" ? "👋 Du hast die Lobby verlassen." : "";

    if (!topToast || !mounted) return null;

    // Direkt an <body>: die Startseiten-Karte ist animiert, darin würde "position: fixed" festhängen
    return createPortal(
        <div className="exitToast" role="status" aria-live="polite" onClick={dismissTopToast}>
            {topToast}
            <style>{`
                .exitToast{ position: fixed; top: 22px; left: 50%; transform: translateX(-50%); z-index: 4700; cursor: pointer;
                  padding: 12px 22px; border-radius: 999px; font-weight: 900; font-size: 15px; color: #fff; white-space: nowrap;
                  background: rgba(30,10,6,.92); border: 1px solid rgba(255,255,255,.25); box-shadow: 0 16px 50px rgba(0,0,0,.45);
                  animation: exitToast 2.5s cubic-bezier(.16,1,.3,1) both; }
                @keyframes exitToast{ 0%{ opacity: 0; transform: translate(-50%, -14px); } 12%, 82%{ opacity: 1; transform: translate(-50%, 0); } 100%{ opacity: 0; transform: translate(-50%, -8px); } }
            `}</style>
        </div>,
        document.body
    );
}
