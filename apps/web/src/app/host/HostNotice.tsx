"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

export function HostNotice() {
    const router = useRouter();
    const sp = useSearchParams();

    const [topToast, setTopToast] = useState<string>("");

    const dismissTopToast = useCallback(() => {
        setTopToast("");
    }, []);

    useEffect(() => {
        const kicked = sp.get("kicked");
        const left = sp.get("left");

        if (kicked === "1") setTopToast("⛔ Du wurdest gekickt.");
        else if (left === "1") setTopToast("ℹ️ Du hast die Lobby verlassen.");

        // cleanup URL so message doesn't re-trigger on refresh
        if (kicked === "1" || left === "1") {
            router.replace("/host");
        }
    }, [sp, router]);

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
