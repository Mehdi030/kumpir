import { describe, it, expect } from "vitest";
import { translate } from "./i18n";

describe("translate", () => {
    it("liefert deutsche Übersetzung für 'de'", () => {
        expect(translate("de", "home.host")).toBe("🚀 Mit Freunden spielen");
    });

    it("liefert englische Übersetzung für 'en'", () => {
        expect(translate("en", "home.host")).toBe("🚀 Play with friends");
    });

    it("ersetzt Platzhalter", () => {
        expect(translate("en", "fin.match", { n: 3 })).toBe("Match over · 3 rounds");
        expect(translate("de", "fin.me", { place: 2, score: 17 })).toBe("Dein Ergebnis: Platz 2 · 17 Punkte");
    });

    it("fällt für unbekannten Key auf den Key selbst zurück", () => {
        // Intentionally invalid key — runtime fallback path
        const result = translate("de", "nonexistent.key" as Parameters<typeof translate>[1]);
        expect(result).toBe("nonexistent.key");
    });

    it("hat sowohl de als auch en Übersetzungen für Kern-UI-Strings", () => {
        for (const key of ["home.solo", "home.host", "home.join", "join.btn", "common.back", "fin.again"] as const) {
            expect(translate("de", key)).not.toBe(key);
            expect(translate("en", key)).not.toBe(key);
            expect(translate("en", key)).not.toBe(translate("de", key));
        }
    });
});
