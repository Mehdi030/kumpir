import { tk } from "@/lib/i18nMark";

/**
 * Die drei Spielmodi (Wunsch Mehdi 2026-10-14: wenige Modi, jeder mit eigener Oberfläche, eigener Aufstellung
 * der Spieler und klar festgelegtem Ziel). Labels/Texte sind deutsche Schlüssel -> im UI mit tr() übersetzen.
 *
 *  original – Heiße Kartoffel: alle sitzen am runden Tisch, die Kumpir wandert, wer sie beim Knall hält, fliegt.
 *  buzzer   – Buzzer-Arena: Game-Show-Pulte, die mit den Punkten wachsen; wer zuerst das Ziel erreicht, gewinnt.
 *  year     – Zeitreise: alle ziehen ihre Figur auf einer Zeitleiste zum Erscheinungsjahr des Songs.
 *  letters  – Roulette: ein Buchstabe + drei Kategorien, jeder tippt in 45 s so viele passende Begriffe wie möglich.
 */
export type GameModeKey = "original" | "buzzer" | "year" | "letters";

export type GameModeInfo = {
    key: GameModeKey;
    icon: string;
    label: string;
    /** Kurzbeschreibung (Kacheln beim Hosten, Tooltip in der Lobby) */
    desc: string;
    /** Das Ziel in einem Satz – steht auch im Spiel oben */
    goal: string;
    /** "potato" = Kumpir wird weitergegeben, "quiz" = alle raten gleichzeitig */
    kind: "potato" | "quiz";
    /** Drei kurze Stichpunkte für die Kacheln beim Hosten (statt langer Beschreibung) */
    steps: { icon: string; text: string }[];
    /** Regeln für „So wird gespielt“ */
    rules: { icon: string; text: string }[];
    soon?: boolean;
    isNew?: boolean;
};

export const GAME_MODES: GameModeInfo[] = [
    {
        key: "original",
        icon: "🥔",
        label: tk("Original"),
        desc: tk("Heiße Kartoffel: Song erkennen, Kumpir weitergeben, nicht erwischen lassen. Alle sitzen am runden Tisch."),
        goal: tk("Als Letzter noch im Spiel sein"),
        kind: "potato",
        steps: [
            { icon: "🎧", text: tk("Song erkennen") },
            { icon: "🥔", text: tk("Kumpir weitergeben") },
            { icon: "💥", text: tk("Wer sie beim Knall hält, fliegt") },
        ],
        rules: [
            { icon: "🎧", text: tk("Ein Song läuft: Titel (1 Punkt), Künstler (½) oder beides zusammen (1,5 Punkte) tippen und die Kumpir weitergeben. Feature-Partner zählen auch.") },
            { icon: "🔥", text: tk("Wer sie beim Knall hält, fliegt raus – die Zündschnur wird jede Runde kürzer.") },
            { icon: "⏱️", text: tk("Richtige Antworten, schwere Songs und Treffer in Folge geben Bonuszeit.") },
            { icon: "🛡️", text: tk("Schutzzeit: Wer die Kumpir bekommt, hat immer mindestens 6–9 Sekunden – auch wenn sie in letzter Sekunde kam.") },
            { icon: "⚡", text: tk("Schnell abgeben lohnt sich: unter 5 Sekunden gibt es +5 Punkte.") },
            { icon: "🏆", text: tk("Wer zuletzt übrig bleibt, gewinnt. Bei mehreren Runden zählt die Summe.") },
        ],
    },
    {
        key: "buzzer",
        icon: "🔔",
        label: tk("Buzzer"),
        desc: tk("Game-Show: Ein Song läuft, wer ihn erkennt, buzzert zuerst. Dein Pult wächst mit jedem Punkt."),
        goal: tk("Wer zuerst 10 Punkte hat, gewinnt"),
        kind: "quiz",
        isNew: true,
        steps: [
            { icon: "🔔", text: tk("Als Erster buzzern") },
            { icon: "✍️", text: tk("Titel oder Künstler tippen") },
            { icon: "🔒", text: tk("Falsch = für den Song gesperrt") },
        ],
        rules: [
            { icon: "🔔", text: tk("Ein Song läuft. Wer ihn erkennt, drückt den Buzzer (Leertaste) – wer zuerst drückt, darf antworten.") },
            { icon: "✍️", text: tk("Titel richtig: 2 Punkte. Nur der Künstler richtig: 1 Punkt. Du hast 7 Sekunden zum Tippen.") },
            { icon: "🔒", text: tk("Falsch oder zu langsam? Dann bist du für diesen Song raus, die anderen dürfen weiter buzzern.") },
            { icon: "🏁", text: tk("Wer zuerst 10 Punkte hat, gewinnt sofort. Nach 20 Songs gewinnt, wer vorn liegt.") },
        ],
    },
    {
        key: "year",
        icon: "📅",
        label: tk("Jahr raten"),
        desc: tk("Zeitreise: Zieh deine Figur auf der Zeitleiste zum Erscheinungsjahr. Je näher, desto mehr Punkte."),
        goal: tk("Nach 8 Songs gewinnt, wer die meisten Punkte hat"),
        kind: "quiz",
        isNew: true,
        steps: [
            { icon: "🎧", text: tk("Song hören") },
            { icon: "📅", text: tk("Figur aufs Jahr ziehen") },
            { icon: "🎯", text: tk("Je näher, desto mehr Punkte") },
        ],
        rules: [
            { icon: "🎧", text: tk("Ein Song läuft. Zieh deine Figur auf der Zeitleiste auf das Jahr, in dem er erschienen ist, und gib deinen Tipp ab.") },
            { icon: "🎯", text: tk("Genau richtig: 5 Punkte. Ein Jahr daneben: 3. Zwei Jahre: 2. Bis fünf Jahre: 1.") },
            { icon: "👀", text: tk("Die Tipps der anderen siehst du erst bei der Auflösung – dann springen alle Figuren auf ihr Jahr.") },
            { icon: "🏆", text: tk("Nach 8 Songs gewinnt, wer die meisten Punkte hat. Bei Gleichstand zählen mehr Volltreffer.") },
        ],
    },
    {
        key: "letters",
        icon: "🎰",
        label: tk("Roulette"),
        desc: tk("Buchstaben-Roulette: Ein Buchstabe, drei Kategorien – tippe so viele passende Begriffe wie möglich."),
        goal: tk("Nach 3 Kategorien gewinnt, wer die meisten richtigen Begriffe hat"),
        kind: "quiz",
        isNew: true,
        steps: [
            { icon: "🎰", text: tk("Roulette zieht einen Buchstaben") },
            { icon: "⌨️", text: tk("Passende Begriffe eintippen") },
            { icon: "✅", text: tk("Richtige zählen, die Rangliste läuft von unten") },
        ],
        rules: [
            { icon: "🎰", text: tk("Das Roulette läuft von A bis Z und bleibt bei einem Buchstaben stehen. Dazu kommen drei Kategorien, z. B. Rapper, Schauspieler, Länder.") },
            { icon: "⌨️", text: tk("Pro Kategorie hast du 45 Sekunden: tippe so viele Begriffe mit diesem Anfangsbuchstaben ein wie möglich (Enter = abgeben). Du siehst nur deine eigenen Eingaben.") },
            { icon: "✅", text: tk("Danach werden alle Eingaben geprüft: erkannte werden grün, nicht erkannte rot, doppelte zählen nur einmal. Kleine Tippfehler sind okay.") },
            { icon: "📊", text: tk("Die Rangliste läuft von unten nach oben – wer die meisten richtigen Begriffe hatte, kommt zuletzt. Nach 3 Kategorien gewinnt die Gesamtsumme.") },
        ],
    },
];

export const GAME_MODE_BY_KEY: Record<string, GameModeInfo> = Object.fromEntries(GAME_MODES.map((m) => [m.key, m]));

export function gameModeInfo(key: string | null | undefined): GameModeInfo {
    return GAME_MODE_BY_KEY[key ?? "original"] ?? GAME_MODE_BY_KEY.original;
}

export function isQuizMode(key: string | null | undefined): boolean {
    return GAME_MODE_BY_KEY[key ?? ""]?.kind === "quiz";
}
