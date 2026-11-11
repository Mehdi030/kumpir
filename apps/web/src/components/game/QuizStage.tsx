"use client";

import { BuzzerArena } from "@/components/quiz/BuzzerArena";
import { YearTimeline } from "@/components/quiz/YearTimeline";
import { LetterRoulette } from "@/components/quiz/LetterRoulette";
import { BattleArena } from "@/components/quiz/BattleArena";
import type { QuizLobby, QuizPlayer } from "@/components/quiz/useQuiz";

export type { QuizLobby, QuizPlayer };

/** Wählt die Oberfläche passend zum Modus: Buzzer-Arena, Zeitreise (Jahr raten), Roulette (Buchstabe + Kategorien) oder Hit oder Flop (Song-Battle mit Jury). Jeder Modus hat sein eigenes Spielfeld. */
export function QuizStage(props: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (msg: string, ms?: number) => void }) {
    if (props.lobby.game_mode === "year") return <YearTimeline {...props} />;
    if (props.lobby.game_mode === "letters") return <LetterRoulette {...props} />;
    if (props.lobby.game_mode === "battle") return <BattleArena {...props} />;
    return <BuzzerArena {...props} />;
}
