export type RoundSpeed = "fast" | "normal" | "calm";
export type GameMode =
    | "original"
    | "blitz"
    | "casual"
    | "teleport"
    | "reverse";

type SecondsRange = readonly [minSeconds: number, maxSeconds: number];

export const ROUND_SPEEDS: Record<
    RoundSpeed,
    {
        label: string;
        explodeRangeSec: SecondsRange;
        hint: string;
    }
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

export const MODES: Record<
    GameMode,
    { label: string; icon: string; desc: string; featured?: boolean }
> = {
    original: {
        label: "Original",
        icon: "🥔",
        desc: "Standard-Regeln. Beste Basis für alle.",
        featured: true,
    },
    blitz: {
        label: "Blitz",
        icon: "⚡",
        desc: "Schneller, direkter, mehr Druck.",
    },
    casual: {
        label: "Casual",
        icon: "🧊",
        desc: "Entspannt und locker.",
    },
    teleport: {
        label: "Teleport",
        icon: "🌀",
        desc: "Kartoffel springt unerwartet.",
    },
    reverse: {
        label: "Reverse",
        icon: "🔁",
        desc: "Richtung kann wechseln.",
    },
};

/**
 * Picks a single "bomb explodes after X seconds" value.
 * - quantizeStepSec: rounds to steps (e.g. 0.5s) so it feels less robotic
 * - clampMinSec: safety minimum so rounds never become too short
 */
export function pickLobbyExplodeSeconds(
    speed: RoundSpeed,
    opts?: {
        rng?: () => number;
        quantizeStepSec?: number;
        clampMinSec?: number;
    }
) {
    const rng = opts?.rng ?? Math.random;
    const step = opts?.quantizeStepSec ?? 0.5;
    const clampMin = opts?.clampMinSec ?? 3;

    const [min, max] = ROUND_SPEEDS[speed].explodeRangeSec;

    const raw = min + rng() * (max - min);
    const quantized = Math.round(raw / step) * step;

    return Math.max(clampMin, quantized);
}

/**
 * Advanced explode calculation used by startGame / tickGame.
 * Scales timing slightly depending on number of alive players.
 */
export function calculateExplodeSeconds(
    speed: RoundSpeed,
    aliveCount: number,
    opts?: {
        exponent?: number;          // randomness bias
        clampMinSec?: number;
        quantizeStepSec?: number;
    }
) {
    const exponent = opts?.exponent ?? 1.9;
    const clampMin = opts?.clampMinSec ?? 3;
    const step = opts?.quantizeStepSec ?? 0.5;

    const [baseMin, baseMax] = ROUND_SPEEDS[speed].explodeRangeSec;

    // Scale by player count (more players = slightly shorter rounds)
    const scale = clamp(0.75, 1.25, 1.15 - aliveCount * 0.035);

    const minSec = Math.max(clampMin, baseMin * scale);
    const maxSec = Math.max(minSec + 1, baseMax * scale);

    const u = Math.random();
    const biased = Math.pow(u, exponent);
    const raw = minSec + biased * (maxSec - minSec);

    const quantized = Math.round(raw / step) * step;
    return Math.max(clampMin, quantized);
}

function clamp(min: number, max: number, v: number) {
    return Math.max(min, Math.min(max, v));
}