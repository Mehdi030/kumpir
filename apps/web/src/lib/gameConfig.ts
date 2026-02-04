export type RoundSpeed = "fast" | "normal" | "calm";
export type GameMode = "original" | "blitz" | "casual" | "teleport" | "reverse";

type SecondsRange = readonly [minSeconds: number, maxSeconds: number];

export const ROUND_SPEEDS: Record<
    RoundSpeed,
    { label: string; explodeRangeSec: SecondsRange; hint: string }
> = {
    fast: {
        label: "Fast",
        explodeRangeSec: [15, 30],
        hint: "Schnell, hoher Druck.",
    },
    normal: {
        label: "Normal",
        explodeRangeSec: [30, 60],
        hint: "Ausgewogen.",
    },
    calm: {
        label: "Calm",
        explodeRangeSec: [60, 90],
        hint: "Entspannt, mehr Zeit.",
    },
};

export const MODES: Record<GameMode, { label: string; icon: string; desc: string; featured?: boolean }> = {
    original: { label: "Original", icon: "🥔", desc: "Standard-Regeln. Beste Basis für alle.", featured: true },
    blitz:    { label: "Blitz",    icon: "⚡", desc: "Schneller, direkter, mehr Druck." },
    casual:   { label: "Casual",   icon: "🧊", desc: "Entspannt und locker." },
    teleport: { label: "Teleport", icon: "🌀", desc: "Kartoffel springt unerwartet." },
    reverse:  { label: "Reverse",  icon: "🔁", desc: "Richtung kann wechseln." },
};

/**
 * Picks a single "bomb explodes after X seconds" value for the whole lobby.
 * - quantizeStepSec: rounds to a step (e.g. 0.5s) so it feels less "machine precise"
 */
export function pickLobbyExplodeSeconds(
    speed: RoundSpeed,
    opts?: { rng?: () => number; quantizeStepSec?: number; clampMinSec?: number }
) {
    const rng = opts?.rng ?? Math.random;
    const step = opts?.quantizeStepSec ?? 0.5;       // ✅ good default
    const clampMin = opts?.clampMinSec ?? 3;         // ✅ safety, optional
    const [min, max] = ROUND_SPEEDS[speed].explodeRangeSec;

    const raw = min + rng() * (max - min);           // float
    const quantized = Math.round(raw / step) * step; // 0.5s steps by default
    return Math.max(clampMin, quantized);
}
