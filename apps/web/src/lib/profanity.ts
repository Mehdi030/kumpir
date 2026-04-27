/**
 * Lightweight name validator: blocks the worst offenders client-side.
 * Backend should validate again — never trust the browser.
 *
 * Strategy:
 *  - normalize (lowercase, strip diacritics, collapse l33t-substitutions)
 *  - reject if a banned token appears as a whole-word match
 *  - allow short common substrings to slip through (e.g. "scunthorpe" problem)
 */

const BANNED_DE = [
    "arschloch",
    "fotze",
    "hure",
    "hurensohn",
    "missgeburt",
    "nazi",
    "neger",
    "schlampe",
    "schwuchtel",
    "wichser",
];

const BANNED_EN = ["bitch", "cunt", "fag", "faggot", "kike", "nigger", "nigga", "retard", "slut", "whore"];

const BANNED = [...BANNED_DE, ...BANNED_EN];

const L33T_MAP: Record<string, string> = {
    "0": "o",
    "1": "i",
    "3": "e",
    "4": "a",
    "5": "s",
    "7": "t",
    "@": "a",
    "$": "s",
    "!": "i",
};

function normalize(input: string): string {
    return input
        .toLowerCase()
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "") // strip diacritics
        .replace(/[018345@$!]/g, (c) => L33T_MAP[c] ?? c)
        .replace(/[^a-z\s]/g, "");
}

export type NameValidation =
    | { ok: true; clean: string }
    | { ok: false; reason: "tooShort" | "tooLong" | "profane" | "empty"; message: string };

export function validatePlayerName(raw: string): NameValidation {
    const trimmed = raw.trim();
    if (trimmed.length === 0) return { ok: false, reason: "empty", message: "Name darf nicht leer sein." };
    if (trimmed.length < 2) return { ok: false, reason: "tooShort", message: "Mindestens 2 Zeichen." };
    if (trimmed.length > 24) return { ok: false, reason: "tooLong", message: "Maximal 24 Zeichen." };

    const norm = normalize(trimmed);
    const tokens = new Set(norm.split(/\s+/).filter(Boolean));
    for (const bad of BANNED) {
        if (tokens.has(bad)) {
            return { ok: false, reason: "profane", message: "Bitte einen anderen Namen wählen." };
        }
    }

    return { ok: true, clean: trimmed };
}
