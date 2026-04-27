import { describe, it, expect } from "vitest";
import {
    pickLobbyExplodeSeconds,
    calculateExplodeSeconds,
    GAME_MODES,
    ROUND_SPEEDS,
} from "./gameConfig";

describe("ROUND_SPEEDS", () => {
    it("hat alle drei Speed-Varianten mit gültigen Ranges", () => {
        for (const key of ["fast", "normal", "calm"] as const) {
            const s = ROUND_SPEEDS[key];
            const [min, max] = s.explodeRangeSec;
            expect(min).toBeGreaterThan(0);
            expect(max).toBeGreaterThan(min);
        }
    });

    it("fast ist schneller als normal, normal schneller als calm", () => {
        expect(ROUND_SPEEDS.fast.explodeRangeSec[1]).toBeLessThanOrEqual(ROUND_SPEEDS.normal.explodeRangeSec[1]);
        expect(ROUND_SPEEDS.normal.explodeRangeSec[1]).toBeLessThanOrEqual(ROUND_SPEEDS.calm.explodeRangeSec[1]);
    });
});

describe("GAME_MODES", () => {
    it("definiert alle 5 Modi mit Label und Icon", () => {
        const modes = ["original", "teleport", "reverse", "last_clock_standing", "topic_shuffle"] as const;
        for (const m of modes) {
            expect(GAME_MODES[m]).toBeDefined();
            expect(GAME_MODES[m].label.length).toBeGreaterThan(0);
            expect(GAME_MODES[m].icon.length).toBeGreaterThan(0);
        }
    });

    it("markiert nur 'original' als featured", () => {
        const featured = (Object.keys(GAME_MODES) as Array<keyof typeof GAME_MODES>).filter(
            (k) => GAME_MODES[k].featured
        );
        expect(featured).toEqual(["original"]);
    });
});

describe("pickLobbyExplodeSeconds", () => {
    it("liegt für rng=0 nahe am Minimum (auf step gerundet)", () => {
        const v = pickLobbyExplodeSeconds("normal", { rng: () => 0, quantizeStepSec: 0.5 });
        expect(v).toBe(14); // baseMin = 14
    });

    it("liegt für rng→1 nahe am Maximum", () => {
        const v = pickLobbyExplodeSeconds("normal", { rng: () => 0.9999, quantizeStepSec: 0.5 });
        expect(v).toBeGreaterThanOrEqual(25);
        expect(v).toBeLessThanOrEqual(26);
    });

    it("respektiert clampMinSec auch bei tiefem RNG", () => {
        const v = pickLobbyExplodeSeconds("fast", { rng: () => 0, clampMinSec: 12, quantizeStepSec: 0.5 });
        expect(v).toBeGreaterThanOrEqual(12);
    });

    it("rundet auf den Quantize-Step", () => {
        const step = 0.5;
        for (let i = 0; i < 50; i++) {
            const v = pickLobbyExplodeSeconds("calm", { quantizeStepSec: step });
            // toBeCloseTo to handle floating-point modulo edge cases
            expect(((v / step) % 1)).toBeCloseTo(0, 6);
        }
    });
});

describe("calculateExplodeSeconds", () => {
    it("gibt einen positiven Wert über clampMinSec zurück", () => {
        const v = calculateExplodeSeconds("normal", 4);
        expect(v).toBeGreaterThanOrEqual(3);
    });

    it("wird mit höherem roundIndex tendenziell kürzer (deterministisch via fixed rng)", () => {
        const rng = () => 0.5;
        const r0 = calculateExplodeSeconds("normal", 4, { rng, roundIndex: 0 });
        const r10 = calculateExplodeSeconds("normal", 4, { rng, roundIndex: 10 });
        expect(r10).toBeLessThanOrEqual(r0);
    });

    it("respektiert roundDecayMax", () => {
        const rng = () => 0.5;
        const r5 = calculateExplodeSeconds("normal", 4, {
            rng,
            roundIndex: 5,
            roundDecayPerRound: 0.05,
            roundDecayMax: 0.1,
        });
        const r20 = calculateExplodeSeconds("normal", 4, {
            rng,
            roundIndex: 20,
            roundDecayPerRound: 0.05,
            roundDecayMax: 0.1,
        });
        // Ab roundIndex 2 ist die cap (0.1) erreicht, danach keine weitere Verkürzung
        expect(r20).toBeCloseTo(r5, 1);
    });

    it("wird mit mehr Spielern tendenziell kürzer (Player-Skalierung)", () => {
        const rng = () => 0.5;
        const few = calculateExplodeSeconds("normal", 2, { rng });
        const many = calculateExplodeSeconds("normal", 12, { rng });
        expect(many).toBeLessThan(few);
    });
});
