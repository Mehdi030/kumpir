"use client";

import { useParams, useRouter } from "next/navigation";
import { AuthMini } from "@/components/AuthMini";

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();
    const router = useRouter();

    return (
        <div className="p-6">
            <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                <div className="text-2xl font-semibold">Lobby</div>
                <AuthMini nextPath={`/lobby/${code}`} variant="header" />
            </div>

            <div className="opacity-70 mt-2">Code: {code}</div>

            <div className="mt-6 opacity-70">
                Waiting Room: Playerliste, Ready, Start kommt als nächstes.
            </div>

            <div className="mt-6" style={{ display: "flex", gap: 12 }}>
                <button className="btn btnPrimary" onClick={() => router.push(`/game/${code}`)}>
                    Start (Dummy)
                </button>
                <button className="btn btnSecondary" onClick={() => router.push(`/join?code=${code}`)}>
                    Invite / Join testen
                </button>
            </div>
        </div>
    );
}
