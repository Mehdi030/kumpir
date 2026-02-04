"use client";

import { useParams } from "next/navigation";

export default function GamePage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    return (
        <div className="p-6">
            <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                <div className="text-2xl font-semibold">Game</div>
            </div>

            <div className="opacity-70">Lobby: {code}</div>
            <div className="mt-4 opacity-70">Next: Timer / Pass / Elimination</div>
        </div>
    );
}
