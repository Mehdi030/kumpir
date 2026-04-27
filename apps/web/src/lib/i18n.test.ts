import { describe, it, expect } from "vitest";
import { translate } from "./i18n";

describe("translate", () => {
    it("liefert deutsche Übersetzung für 'de'", () => {
        expect(translate("de", "landing.hostBtn")).toBe("🚀 Spiel hosten");
    });

    it("liefert englische Übersetzung für 'en'", () => {
        expect(translate("en", "landing.hostBtn")).toBe("🚀 Host a game");
    });

    it("fällt für unbekannten Key auf den Key selbst zurück", () => {
        // Intentionally invalid key — runtime fallback path
        const result = translate("de", "nonexistent.key" as Parameters<typeof translate>[1]);
        expect(result).toBe("nonexistent.key");
    });

    it("hat sowohl de als auch en Übersetzungen für Kern-UI-Strings", () => {
        for (const key of ["landing.hostBtn", "landing.joinBtn", "common.back", "game.rematch"] as const) {
            expect(translate("de", key)).not.toBe(key);
            expect(translate("en", key)).not.toBe(key);
        }
    });
});
