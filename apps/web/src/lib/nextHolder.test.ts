import { describe, it, expect } from "vitest";
import { nextHolderId } from "./nextHolder";

const mk = (ids: string) => ids.split("").map((id) => ({ player_id: id }));

describe("nextHolderId", () => {
    it("vorwärts: nächster in Sitzreihenfolge, am Ende wieder vorn", () => {
        const a = mk("ABCD");
        expect(nextHolderId(a, "A", 1)).toBe("B");
        expect(nextHolderId(a, "D", 1)).toBe("A");
    });
    it("rückwärts (Rache-Pass)", () => {
        const a = mk("ABCD");
        expect(nextHolderId(a, "A", -1)).toBe("D");
        expect(nextHolderId(a, "C", -1)).toBe("B");
    });
    it("einer allein oder unbekannter Halter: niemand", () => {
        expect(nextHolderId(mk("A"), "A", 1)).toBeNull();
        expect(nextHolderId(mk("AB"), "X", 1)).toBeNull();
    });
});
