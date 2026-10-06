import { describe, it, expect } from "vitest";
import { fmtSeconds, hitRate, seasonLabel, strongestPlaylist, titleRate } from "./profileStats";

describe("profileStats", () => {
    it("Trefferquote zählt Titel und Interpret als richtig", () => {
        expect(hitRate(6, 2, 2)).toBe(80);
        expect(hitRate(0, 0, 0)).toBeNull();
    });

    it("Titel-Quote zählt nur volle Titel", () => {
        expect(titleRate(6, 2, 2)).toBe(60);
    });

    it("Monatsname aus Saison-Schlüssel", () => {
        expect(seasonLabel("2026-10")).toBe("Oktober 2026");
        expect(seasonLabel("2027-01")).toBe("Januar 2027");
    });

    it("stärkste Playlist braucht mind. 5 Versuche", () => {
        const rows = [
            { playlist: "Rock", rounds: 1, titles: 2, artists: 0, wrong: 0, wins: 0 }, // nur 2 Versuche
            { playlist: "80er", rounds: 3, titles: 6, artists: 1, wrong: 3, wins: 1 }, // 60 %
            { playlist: "Pop", rounds: 3, titles: 4, artists: 0, wrong: 1, wins: 0 }, // 80 %
        ];
        expect(strongestPlaylist(rows)).toBe("Pop");
        expect(strongestPlaylist([rows[0]])).toBeNull();
    });

    it("Sekunden mit Komma", () => {
        expect(fmtSeconds(2340)).toBe("2,3 s");
        expect(fmtSeconds(null)).toBe("–");
    });
});
