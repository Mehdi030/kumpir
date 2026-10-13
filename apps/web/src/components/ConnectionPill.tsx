"use client";

import React from "react";
import type { RealtimeStatus } from "@/hooks/useLobbyRealtime";
import { tk, useI18n } from "@/lib/i18n";

const MAP: Record<RealtimeStatus, { label: string; color: string; title: string } | null> = {
    idle: null, // hide
    connecting: { label: tk("● Verbinde…"), color: "rgba(255,214,10,0.85)", title: tk("Live-Verbindung wird aufgebaut") },
    live: { label: tk("● Live"), color: "rgba(52,199,89,0.86)", title: tk("Live-Verbindung aktiv") },
    reconnecting: { label: tk("● Verbinde neu"), color: "rgba(255,149,0,0.90)", title: tk("Verbindung verloren – frage regelmäßig nach") },
    offline: { label: tk("● Offline"), color: "rgba(255,69,58,0.90)", title: tk("Live-Verbindung weg – frage regelmäßig nach") },
};

type Props = {
    status: RealtimeStatus;
    /** When true, only show pill if status is non-live (less visual noise). */
    onlyOnIssue?: boolean;
};

export function ConnectionPill({ status, onlyOnIssue = false }: Props) {
    const { tr } = useI18n();
    const cfg = MAP[status];
    if (!cfg) return null;
    if (onlyOnIssue && status === "live") return null;

    return (
        <span
            role="status"
            aria-live="polite"
            title={tr(cfg.title)}
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
            {tr(cfg.label)}
        </span>
    );
}
