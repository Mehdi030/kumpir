import { describe, it, expect } from "vitest";
import { validatePlayerName } from "./profanity";

describe("validatePlayerName", () => {
    it("erlaubt normale Namen", () => {
        const v = validatePlayerName("Medo");
        expect(v.ok).toBe(true);
        if (v.ok) expect(v.clean).toBe("Medo");
    });

    it("trimmt Whitespace", () => {
        const v = validatePlayerName("   Sero   ");
        expect(v.ok).toBe(true);
        if (v.ok) expect(v.clean).toBe("Sero");
    });

    it("blockt zu kurze Namen", () => {
        const v = validatePlayerName("a");
        expect(v.ok).toBe(false);
        if (!v.ok && "reason" in v) expect(v.reason).toBe("tooShort");
    });

    it("blockt zu lange Namen", () => {
        const v = validatePlayerName("x".repeat(30));
        expect(v.ok).toBe(false);
        if (!v.ok && "reason" in v) expect(v.reason).toBe("tooLong");
    });

    it("blockt leere Namen", () => {
        const v = validatePlayerName("   ");
        expect(v.ok).toBe(false);
        if (!v.ok && "reason" in v) expect(v.reason).toBe("empty");
    });

    it("blockt offensichtliche Profanity (DE)", () => {
        const v = validatePlayerName("Wichser");
        expect(v.ok).toBe(false);
        if (!v.ok && "reason" in v) expect(v.reason).toBe("profane");
    });

    it("blockt l33t-substitutions (0 -> o)", () => {
        // 'f0tze' -> 'fotze' (in banned list)
        const v = validatePlayerName("f0tze");
        expect(v.ok).toBe(false);
        if (!v.ok && "reason" in v) expect(v.reason).toBe("profane");
    });

    it("erlaubt unverdaechtige Substrings (Scunthorpe-Problem)", () => {
        // 'cum' substring matched aber nur whole-word, also okay
        const v = validatePlayerName("Scumtest");
        expect(v.ok).toBe(true);
    });
});
