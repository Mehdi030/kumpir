import { tk } from "@/lib/i18nMark";

/** „Hit oder Flop“ (Migration 143): nach welchem Prinzip entscheidet die Jury? */
export type BattleCriterion = "nostalgia" | "sound" | "lyrics" | "hit" | "random";

export const BATTLE_CRITERIA: { key: BattleCriterion; icon: string; label: string; hint: string }[] = [
    { key: "hit", icon: "🔥", label: tk("Hit-Faktor"), hint: tk("Welcher Song ist der größere Hit?") },
    { key: "nostalgia", icon: "🕰️", label: tk("Nostalgie"), hint: tk("Welcher Ausschnitt weckt mehr Erinnerungen?") },
    { key: "sound", icon: "🎧", label: tk("Sound"), hint: tk("Welcher Ausschnitt klingt krasser – Beat, Stimme, Produktion?") },
    { key: "lyrics", icon: "✍️", label: tk("Reime & Lines"), hint: tk("Welche Zeilen sitzen mehr – Reime, Flow, Aussage?") },
    { key: "random", icon: "🎲", label: tk("Wechselt jedes Duell"), hint: tk("Das Prinzip wird pro Duell ausgelost.") },
];

export const criterionInfo = (key: string | null | undefined) => BATTLE_CRITERIA.find((c) => c.key === key) ?? BATTLE_CRITERIA[0];

export const BATTLE_DEFAULT: { criterion: BattleCriterion } = { criterion: "hit" };

export type BattlePick = { songId: string | null; title: string; artist: string | null; start: number; free: boolean };
export type BattleDuel = { n: number; jury: string; a: string; b: string; crit: string; clip: number; picks: { a?: BattlePick; b?: BattlePick } };
export type BattleReveal = {
    winner: "a" | "b" | null;
    winnerId: string | null;
    jury: string;
    crit: string;
    n: number;
    a: BattlePick & { playerId: string };
    b: BattlePick & { playerId: string };
};
