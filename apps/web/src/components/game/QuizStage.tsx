"use client";

import { BuzzerArena } from "@/components/quiz/BuzzerArena";
import { YearTimeline } from "@/components/quiz/YearTimeline";
import { LetterRoulette } from "@/components/quiz/LetterRoulette";
import type { QuizLobby, QuizPlayer } from "@/components/quiz/useQuiz";

export type { QuizLobby, QuizPlayer };

/** Wählt die Oberfläche passend zum Modus: Buzzer-Arena, Zeitreise (Jahr raten) oder Roulette (Buchstabe + Kategorien). Jeder Modus hat sein eigenes Spielfeld. */
export function QuizStage(props: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (msg: string, ms?: number) => void }) {
    if (props.lobby.game_mode === "year") return <YearTimeline {...props} />;
    if (props.lobby.game_mode === "letters") return <LetterRoulette {...props} />;
    return <BuzzerArena {...props} />;
}
