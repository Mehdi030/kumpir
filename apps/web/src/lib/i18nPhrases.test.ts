import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { PHRASES_EN } from "./i18nPhrasesEn";
import { PHRASES_FR } from "./i18nPhrasesFr";
import { trIn } from "./i18n";

// Alle tr("…") / trNow("…")-Texte im Code einsammeln (nur doppelte Anführungszeichen)
function walk(dir: string, out: string[] = []): string[] {
    for (const name of readdirSync(dir)) {
        const p = join(dir, name);
        if (statSync(p).isDirectory()) walk(p, out);
        else if (/\.(tsx?|mts)$/.test(name) && !/\.test\./.test(name)) out.push(p);
    }
    return out;
}

const SRC = join(__dirname, "..");
const used = new Map<string, string>();
for (const file of walk(SRC)) {
    const code = readFileSync(file, "utf8");
    for (const m of code.matchAll(/\b(?:tr|trNow|tk)\(\s*"((?:[^"\\]|\\.)*)"/g)) {
        const text = JSON.parse(`"${m[1]}"`) as string;
        if (!used.has(text)) used.set(text, file.slice(SRC.length + 1));
    }
}

describe("Übersetzungen (tr)", () => {
    it("findet Texte im Code", () => {
        expect(used.size).toBeGreaterThan(0);
    });

    it("jeder tr()-Text hat eine englische Übersetzung", () => {
        const missing = [...used].filter(([t]) => !(t in PHRASES_EN)).map(([t, f]) => `${f}: ${t}`);
        expect(missing).toEqual([]);
    });

    it("jeder tr()-Text hat eine französische Übersetzung", () => {
        const missing = [...used].filter(([t]) => !(t in PHRASES_FR)).map(([t, f]) => `${f}: ${t}`);
        expect(missing).toEqual([]);
    });

    it("Platzhalter stimmen überein", () => {
        const ph = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");
        const bad: string[] = [];
        for (const [t] of used) {
            for (const [lang, dict] of [["en", PHRASES_EN], ["fr", PHRASES_FR]] as const) {
                if (dict[t] != null && ph(dict[t]) !== ph(t)) bad.push(`${lang}: ${t}`);
            }
        }
        expect(bad).toEqual([]);
    });

    it("ersetzt Platzhalter und fällt auf Deutsch zurück", () => {
        expect(trIn("de", "Hallo {n}", { n: 2 })).toBe("Hallo 2");
        expect(trIn("fr", "__gibt_es_nicht__")).toBe("__gibt_es_nicht__");
    });
});
