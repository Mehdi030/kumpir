/** Symbole der Roulette-Kategorien (Abstimmung im Spiel und Einstellungen in der Lobby). Unbekannte Kategorien bekommen 🎯. */
export const CAT_ICON: Record<string, string> = {
    Rapper: "🎤",
    Schauspieler: "🎬",
    Länder: "🌍",
    Städte: "🏙️",
    Hauptstädte: "🏛️",
    Sänger: "🎵",
    Bands: "🎸",
    Fußballspieler: "⚽",
    Fußballvereine: "🏟️",
    Flüsse: "🌊",
    Serien: "📺",
    Tiere: "🐾",
    "Obst & Gemüse": "🍎",
    Automarken: "🚗",
};

export const catIcon = (name: string) => CAT_ICON[name] ?? "🎯";

/** Einstellungen des Roulettes (Host, Migration 130) */
export type LettersCfg = { cats: number; secs: number; off: string[] };
export const LETTERS_DEFAULT: LettersCfg = { cats: 3, secs: 45, off: [] };
export const LETTERS_CATS = [1, 2, 3, 4, 5];
export const LETTERS_SECS = [30, 45, 60, 90];

export function lettersCfgOf(raw: { cats?: number; secs?: number; off?: string[] } | null | undefined): LettersCfg {
    return {
        cats: raw?.cats && LETTERS_CATS.includes(raw.cats) ? raw.cats : LETTERS_DEFAULT.cats,
        secs: raw?.secs && LETTERS_SECS.includes(raw.secs) ? raw.secs : LETTERS_DEFAULT.secs,
        off: Array.isArray(raw?.off) ? raw!.off!.filter((x) => typeof x === "string") : [],
    };
}
