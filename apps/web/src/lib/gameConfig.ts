// gameRules.ts (oder wo du deine Constants/Helpers hast)

export type RoundSpeed = "fast" | "normal" | "calm";

export type GameMode =
    | "original"
    | "teleport"
    | "reverse"
    | "last_clock_standing"
    | "topic_shuffle";

/**
 * UI + Meta für GameModes (DB: lobbies.game_mode)
 * -> hier packst du alles rein, was du im Frontend anzeigen willst (label/icon/desc/hint)
 */
export const GAME_MODES: Record<
    GameMode,
    { label: string; icon: string; desc: string; hint: string; featured?: boolean }
> = {
    original: {
        label: "Original",
        icon: "🥔",
        desc: "Standard-Regeln. Beste Basis für alle.",
        hint: "Standardmodus.",
        featured: true,
    },
    teleport: {
        label: "Teleport",
        icon: "🌀",
        desc: "Kartoffel springt unerwartet.",
        hint: "Kartoffel springt zufällig.",
    },
    reverse: {
        label: "Reverse",
        icon: "🔁",
        desc: "Richtung kann wechseln.",
        hint: "Richtung wechselt.",
    },
    last_clock_standing: {
        label: "Last Clock Standing",
        icon: "⏱️",
        desc: "Jeder hat eine eigene Uhr. Überlebe länger als alle anderen.",
        hint: "Eigene Uhr. Überlebe länger als alle anderen.",
    },
    topic_shuffle: {
        label: "Topic Shuffle",
        icon: "🎲",
        desc: "Nach jeder Runde ein neues Thema. Schnell anpassen.",
        hint: "Nach jeder Runde neues Thema.",
    },
};

/**
 * UI + Timing für RoundSpeed (DB: lobbies.round_speed)
 */
export const ROUND_SPEEDS: Record<
    RoundSpeed,
    { label: string; icon: string; desc: string; explodeRangeSec: [number, number] }
> = {
    fast: {
        label: "Blitz",
        icon: "⚡",
        desc: "Schneller, direkter, mehr Druck.",
        explodeRangeSec: [9, 16],
    },
    normal: {
        label: "Normal",
        icon: "🎯",
        desc: "Guter Standard.",
        explodeRangeSec: [14, 26],
    },
    calm: {
        label: "Casual",
        icon: "🧊",
        desc: "Entspannt und locker.",
        explodeRangeSec: [22, 40],
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
 * - scales by alive player count (more players => slightly shorter)
 * - NEW: scales by roundIndex (each round slightly faster, with cap)
 */
export function calculateExplodeSeconds(
    speed: RoundSpeed,
    aliveCount: number,
    opts?: {
        exponent?: number; // randomness bias
        clampMinSec?: number;
        quantizeStepSec?: number;
        rng?: () => number;

        // NEW: round progression
        roundIndex?: number;          // 0-based: 0 = erste Runde
        roundDecayPerRound?: number;  // e.g. 0.015 = -1.5% pro Runde
        roundDecayMax?: number;       // e.g. 0.25 = max -25%
    }
) {
    const exponent = opts?.exponent ?? 1.9;
    const clampMin = opts?.clampMinSec ?? 3;
    const step = opts?.quantizeStepSec ?? 0.5;
    const rng = opts?.rng ?? Math.random;

    const [baseMin, baseMax] = ROUND_SPEEDS[speed].explodeRangeSec;

    // 1) Scale by player count (more players = slightly shorter rounds)
    const scalePlayers = clamp(0.75, 1.25, 1.15 - aliveCount * 0.035);

    // 2) NEW: Scale by round index (each round a bit faster, with cap)
    const roundIndex = Math.max(0, opts?.roundIndex ?? 0);
    const decayPerRound = opts?.roundDecayPerRound ?? 0.015; // 1.5% per round
    const decayMax = opts?.roundDecayMax ?? 0.25;            // cap at 25%

    const totalDecay = Math.min(decayMax, roundIndex * decayPerRound);
    const scaleRounds = 1 - totalDecay; // smaller => faster

    const minSec = Math.max(clampMin, baseMin * scalePlayers * scaleRounds);
    const maxSec = Math.max(minSec + 1, baseMax * scalePlayers * scaleRounds);

    const u = rng();
    const biased = Math.pow(u, exponent);
    const raw = minSec + biased * (maxSec - minSec);

    const quantized = Math.round(raw / step) * step;
    return Math.max(clampMin, quantized);
}

function clamp(min: number, max: number, v: number) {
    return Math.max(min, Math.min(max, v));
}

/**
 * OPTIONAL: Helper arrays für UI (Dropdowns etc.)
 */
export const GAME_MODE_LIST = (Object.keys(GAME_MODES) as GameMode[]).map((k) => ({
    key: k,
    ...GAME_MODES[k],
}));

export const ROUND_SPEED_LIST = (Object.keys(ROUND_SPEEDS) as RoundSpeed[]).map((k) => ({
    key: k,
    ...ROUND_SPEEDS[k],
}));