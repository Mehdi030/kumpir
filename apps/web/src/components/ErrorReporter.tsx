"use client";

import { useEffect } from "react";
import { track } from "@/lib/track";

const IGNORE = /ResizeObserver loop|^Script error\.?$|Non-Error promise rejection|AbortError|Load failed|Failed to fetch|NetworkError/i;
const MAX_PER_PAGE = 5;

/** Meldet unbehandelte Browser-Fehler anonym (Ereignis "client_error", Migration 138), damit Abstürze auffallen. */
export function reportClientError(message: string): void {
    const m = message.replace(/\s+/g, " ").trim().slice(0, 160);
    if (!m || IGNORE.test(m)) return;
    track("client_error", { m, p: window.location.pathname.replace(/\/[A-Z0-9]{4,8}$/i, "/:code").slice(0, 60) });
}

export function ErrorReporter() {
    useEffect(() => {
        let sent = 0;
        const send = (msg: string) => {
            if (sent >= MAX_PER_PAGE) return;
            sent++;
            reportClientError(msg);
        };
        const onError = (e: ErrorEvent) => send(e.message || String(e.error ?? ""));
        const onRejection = (e: PromiseRejectionEvent) => {
            const r = e.reason as unknown;
            send(r instanceof Error ? r.message : typeof r === "string" ? r : "");
        };
        window.addEventListener("error", onError);
        window.addEventListener("unhandledrejection", onRejection);
        return () => {
            window.removeEventListener("error", onError);
            window.removeEventListener("unhandledrejection", onRejection);
        };
    }, []);
    return null;
}
