"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

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

    // Soll kurz stehen und von selbst wieder verschwinden, statt bis zum
    // manuellen Wegklicken hängen zu bleiben.
    useEffect(() => {
        if (!initialReason) return;
        const t = window.setTimeout(() => setReason(null), 4000);
        return () => window.clearTimeout(t);
    }, [initialReason]);

    const topToast =
        reason === "kicked"
            ? "⛔ Du wurdest gekickt."
            : reason === "left"
                ? "ℹ️ Du hast die Lobby verlassen."
                : "";

    if (!topToast) return null;

    return (
        <div
            className="pillChip"
            style={{
                marginBottom: 12,
                fontWeight: 950,
                opacity: 0.96,
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                gap: 12,
                padding: "10px 12px",
            }}
            role="status"
            aria-live="polite"
        >
            <span>{topToast}</span>
            <button
                type="button"
                onClick={dismissTopToast}
                className="btn btnSecondary btnSmall"
                style={{ padding: "6px 10px" }}
                aria-label="Hinweis schließen"
                title="Schließen"
            >
                ✕
            </button>
        </div>
    );
}
