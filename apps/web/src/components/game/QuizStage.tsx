"use client";

import { BuzzerArena } from "@/components/quiz/BuzzerArena";
import { YearTimeline } from "@/components/quiz/YearTimeline";
import type { QuizLobby, QuizPlayer } from "@/components/quiz/useQuiz";

export type { QuizLobby, QuizPlayer };

/** Wählt die Oberfläche passend zum Modus: Buzzer-Arena oder Zeitreise (Jahr raten). Jeder Modus hat sein eigenes Spielfeld. */
export function QuizStage(props: { lobby: QuizLobby; players: QuizPlayer[]; mePlayerId: string | null; onToast: (msg: string, ms?: number) => void }) {
    return props.lobby.game_mode === "year" ? <YearTimeline {...props} /> : <BuzzerArena {...props} />;
}
