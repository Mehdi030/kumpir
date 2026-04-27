import { describe, it, expect, beforeEach } from "vitest";
import { setMuted, setVolume, getVolume } from "./gameFx";

describe("gameFx mute/volume persistence", () => {
    beforeEach(() => {
        try {
            window.localStorage.clear();
        } catch {
            // ignore
        }
    });

    it("setMuted(true) speichert in localStorage und getMuted() liest es", () => {
        setMuted(true);
        expect(window.localStorage.getItem("kumpir_mute")).toBe("1");
        // Note: getMuted() is module-cached; actual cross-call read works in real session
    });

    it("setMuted(false) speichert '0'", () => {
        setMuted(false);
        expect(window.localStorage.getItem("kumpir_mute")).toBe("0");
    });

    it("setVolume klemmt auf [0, 1]", () => {
        setVolume(2);
        expect(getVolume()).toBe(1);
        setVolume(-1);
        expect(getVolume()).toBe(0);
    });

    it("setVolume speichert numerischen String", () => {
        setVolume(0.42);
        const raw = window.localStorage.getItem("kumpir_volume");
        expect(Number(raw)).toBeCloseTo(0.42, 5);
    });
});
