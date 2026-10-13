import { tk } from "@/lib/i18nMark";

/**
 * Alle Spielmodi (Migration 108). "potato" = heiße Kartoffel (Weitergeben), "quiz" = alle raten gleichzeitig.
 * Labels/Beschreibungen sind deutsche Schlüssel -> im UI mit tr() übersetzen.
 */
export type GameModeKey = "original" | "teleport" | "reverse" | "teams" | "artist" | "snippet" | "pick" | "buzzer" | "year" | "gap" | "duel";

export type GameModeInfo = {
    key: GameModeKey;
    icon: string;
    label: string;
    desc: string;
    kind: "potato" | "quiz";
    /** noch nicht spielbar -> "BALD" */
    soon?: boolean;
    isNew?: boolean;
};

/** Quiz-Modi freigeschaltet nach Browser-Test mit Bots (2026-10-13). Auf false = alle Quiz-Modi wieder „BALD“. */
const QUIZ_LIVE = true;

const ALL_MODES: GameModeInfo[] = [
    { key: "original", icon: "🥔", label: tk("Original"), desc: tk("Standard-Regeln. Beste Basis für alle."), kind: "potato" },
    { key: "artist", icon: "🎤", label: tk("Wer singt das?"), desc: tk("Ein Song läuft, vier Künstler stehen zur Wahl. Wer zuerst richtig tippt, bekommt am meisten Punkte."), kind: "quiz", isNew: true },
    { key: "snippet", icon: "⚡", label: tk("Blitz-Schnipsel"), desc: tk("Erst 1 Sekunde, dann 2, 4 und 8. Je früher du den Song erkennst, desto mehr Punkte."), kind: "quiz", isNew: true },
    { key: "pick", icon: "🎯", label: tk("Songwahl"), desc: tk("Reihum sucht einer einen Song aus, alle anderen raten. Der Wähler punktet, wenn manche ihn erkennen, aber nicht alle."), kind: "quiz", isNew: true },
    { key: "buzzer", icon: "🔔", label: tk("Buzzer"), desc: tk("Wer zuerst buzzert, darf antworten. Falsch? Dann bist du für diesen Song raus."), kind: "quiz", isNew: true },
    { key: "gap", icon: "🧩", label: tk("Lückentitel"), desc: tk("Der Titel steht da, aber ein Wort fehlt. Tippe das fehlende Wort."), kind: "quiz", isNew: true },
    { key: "duel", icon: "⚔️", label: tk("Duell"), desc: tk("Zwei treten gegeneinander an, wer zuerst zwei Songs errät, gewinnt. Alle anderen wetten auf den Sieger."), kind: "quiz", isNew: true },
    { key: "year", icon: "📅", label: tk("Jahr raten"), desc: tk("In welchem Jahr kam der Song raus? Je näher du dran bist, desto mehr Punkte."), kind: "quiz", isNew: true },
    { key: "teams", icon: "🤝", label: tk("Teams"), desc: tk("Team Rot gegen Team Blau: Die Kartoffel geht immer ins andere Team. Ist ein Team komplett raus, hat das andere gewonnen."), kind: "potato", isNew: true },
    { key: "teleport", icon: "🌀", label: tk("Teleport"), desc: tk("Die Kartoffel springt bei jedem Pass zu einem zufälligen Spieler."), kind: "potato", soon: true },
    { key: "reverse", icon: "🔁", label: tk("Reverse"), desc: tk("Die Richtung wechselt gelegentlich. Mehr Chaos, mehr Lacher."), kind: "potato", soon: true },
];

export const GAME_MODES: GameModeInfo[] = ALL_MODES.map((m) => (m.kind === "quiz" && !QUIZ_LIVE ? { ...m, soon: true, isNew: false } : m));

export const GAME_MODE_BY_KEY: Record<string, GameModeInfo> = Object.fromEntries(GAME_MODES.map((m) => [m.key, m]));

export function gameModeInfo(key: string | null | undefined): GameModeInfo {
    return GAME_MODE_BY_KEY[key ?? "original"] ?? GAME_MODE_BY_KEY.original;
}

export function isQuizMode(key: string | null | undefined): boolean {
    return GAME_MODE_BY_KEY[key ?? ""]?.kind === "quiz";
}
