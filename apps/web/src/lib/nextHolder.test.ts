import { describe, it, expect } from "vitest";
import { nextHolderId } from "./nextHolder";

const mk = (ids: string, teams?: (number | null)[]) => ids.split("").map((id, i) => ({ player_id: id, team: teams ? teams[i] : undefined }));

describe("nextHolderId", () => {
    it("normal: nächster in Sitzreihenfolge, am Ende wieder vorn", () => {
        const a = mk("ABCD");
        expect(nextHolderId(a, "A", 1)).toBe("B");
        expect(nextHolderId(a, "D", 1)).toBe("A");
    });
    it("Rückwärts (Rache-Pass)", () => {
        const a = mk("ABCD");
        expect(nextHolderId(a, "A", -1)).toBe("D");
        expect(nextHolderId(a, "C", -1)).toBe("B");
    });
    it("Teams: springt zum nächsten aus dem anderen Team", () => {
        // A(rot) B(blau) C(rot) D(blau)
        const a = mk("ABCD", [0, 1, 0, 1]);
        expect(nextHolderId(a, "A", 1)).toBe("B");
        expect(nextHolderId(a, "B", 1)).toBe("C");
        // B und D ausgeschieden-ähnlich: A(rot) C(rot) D(blau) -> von A zu D, von D zu A
        const b = mk("ACD", [0, 0, 1]);
        expect(nextHolderId(b, "A", 1)).toBe("D");
        expect(nextHolderId(b, "D", 1)).toBe("A");
        expect(nextHolderId(b, "D", -1)).toBe("C");
    });
    it("Teams: ungerade Aufteilung", () => {
        const a = mk("ABCDE", [0, 1, 0, 1, 0]);
        expect(nextHolderId(a, "E", 1)).toBe("B");
        expect(nextHolderId(a, "C", -1)).toBe("B");
    });
    it("einer allein oder unbekannter Halter: niemand", () => {
        expect(nextHolderId(mk("A"), "A", 1)).toBeNull();
        expect(nextHolderId(mk("AB"), "X", 1)).toBeNull();
    });
});
