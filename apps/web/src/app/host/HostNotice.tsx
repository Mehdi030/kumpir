"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

export function HostNotice() {
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
            router.replace("/host");
        }
    }, [initialReason, router]);

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
