"use client";

import React from "react";
import type { RealtimeStatus } from "@/hooks/useLobbyRealtime";

const MAP: Record<RealtimeStatus, { label: string; color: string; title: string } | null> = {
    idle: null, // hide
    connecting: { label: "● Verbinde…", color: "rgba(255,214,10,0.85)", title: "Realtime wird aufgebaut" },
    live: { label: "● Live", color: "rgba(52,199,89,0.86)", title: "Realtime aktiv" },
    reconnecting: { label: "● Reconnect", color: "rgba(255,149,0,0.90)", title: "Verbindung verloren – Polling aktiv" },
    offline: { label: "● Offline", color: "rgba(255,69,58,0.90)", title: "Realtime offline – Polling aktiv" },
};

type Props = {
    status: RealtimeStatus;
    /** When true, only show pill if status is non-live (less visual noise). */
    onlyOnIssue?: boolean;
};

export function ConnectionPill({ status, onlyOnIssue = false }: Props) {
    const cfg = MAP[status];
    if (!cfg) return null;
    if (onlyOnIssue && status === "live") return null;

    return (
        <span
            role="status"
            aria-live="polite"
            title={cfg.title}
            style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 6,
                padding: "5px 10px",
                borderRadius: 999,
                fontSize: 12,
                fontWeight: 950,
                letterSpacing: 0.3,
                background: cfg.color,
                color: "white",
                border: "1px solid rgba(255,255,255,0.18)",
                boxShadow: "inset 0 1px 0 rgba(255,255,255,0.12)",
                userSelect: "none",
            }}
        >
            {cfg.label}
        </span>
    );
}
