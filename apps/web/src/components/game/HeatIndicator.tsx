"use client";

type HeatLevel = "low" | "mid" | "high";

type HeatIndicatorProps = {
    level: HeatLevel;
};

const HEAT_MAP: Record<
    HeatLevel,
    { label: string; color: string; glow: string }
> = {
    low: {
        label: "🟢 Ruhig",
        color: "rgba(52,199,89,0.85)",
        glow: "0 0 12px rgba(52,199,89,0.35)",
    },
    mid: {
        label: "🟠 Heiß",
        color: "rgba(255,149,0,0.9)",
        glow: "0 0 18px rgba(255,149,0,0.45)",
    },
    high: {
        label: "🔴 KRITISCH",
        color: "rgba(255,69,58,0.95)",
        glow: "0 0 26px rgba(255,69,58,0.6)",
    },
};

export function HeatIndicator({ level }: HeatIndicatorProps) {
    const cfg = HEAT_MAP[level];

    return (
        <div
            title="Gefahr"
            style={{
                padding: "6px 14px",
                borderRadius: 999,
                fontWeight: 950,
                fontSize: 14,
                letterSpacing: 0.3,
                border: "1px solid rgba(255,255,255,0.14)",
                background: cfg.color,
                boxShadow: cfg.glow,
                userSelect: "none",
            }}
        >
            {cfg.label}
        </div>
    );
}
