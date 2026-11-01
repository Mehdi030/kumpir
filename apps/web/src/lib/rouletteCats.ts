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
    Berufe: "👷",
    Sportarten: "🏅",
    Getränke: "🥤",
    "Essen & Gerichte": "🍝",
    Farben: "🎨",
    Kleidung: "👕",
    Musikinstrumente: "🎸",
    Körperteile: "🦶",
    Vornamen: "🪪",
    Filme: "🎬",
};

export const catIcon = (name: string) => CAT_ICON[name] ?? "🎯";

/** Einstellungen des Roulettes (Host, Migration 130) */
export type CustomCat = { name: string; n: number };
export type LettersCfg = { cats: number; secs: number; off: string[]; /** eigene Kategorien dieser Lobby (nur Name + Anzahl; die Begriffe bleiben auf dem Server) */ custom: CustomCat[] };
/** Eintrag zum Speichern der eigenen Kategorien: neu (name + terms) oder bestehende behalten (keep) */
export type CustomItem = { name: string; terms?: string[]; keep?: boolean };
export const LETTERS_DEFAULT: LettersCfg = { cats: 3, secs: 45, off: [], custom: [] };
export const LETTERS_CATS = [1, 2, 3, 4, 5];
export const LETTERS_SECS = [30, 45, 60, 90];

export function lettersCfgOf(raw: { cats?: number; secs?: number; off?: string[]; custom?: CustomCat[] } | null | undefined): LettersCfg {
    return {
        cats: raw?.cats && LETTERS_CATS.includes(raw.cats) ? raw.cats : LETTERS_DEFAULT.cats,
        secs: raw?.secs && LETTERS_SECS.includes(raw.secs) ? raw.secs : LETTERS_DEFAULT.secs,
        off: Array.isArray(raw?.off) ? raw!.off!.filter((x) => typeof x === "string") : [],
        custom: Array.isArray(raw?.custom) ? raw!.custom!.filter((c) => c && typeof c.name === "string").map((c) => ({ name: c.name, n: Number(c.n) || 0 })) : [],
    };
}
