"use client";

import { useParams } from "next/navigation";

export default function GamePage() {
    const params = useParams<{ code: string }>();
    return (
        <div className="p-6">
            <div className="text-2xl font-semibold">Game</div>
            <div className="opacity-70">Lobby: {params.code}</div>
            <div className="mt-4 opacity-70">Next: Timer/Pass/Elimination</div>
        </div>
    );
}
