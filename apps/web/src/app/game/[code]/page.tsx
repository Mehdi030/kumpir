"use client";

import { useEffect } from "react";
import { useParams, useRouter } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { AuthMini } from "@/components/AuthMini";

export default function GamePage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();
    const router = useRouter();
    const { user, loading } = useAuth();

    useEffect(() => {
        if (loading) return;
        if (!user) router.replace(`/login?next=${encodeURIComponent(`/game/${code}`)}`);
    }, [loading, user, router, code]);

    if (loading) return null;
    if (!user) return null;

    return (
        <div className="p-6">
            <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                <div className="text-2xl font-semibold">Game</div>
                <AuthMini nextPath={`/game/${code}`} variant="header" />
            </div>

            <div className="opacity-70">Lobby: {code}</div>
            <div className="mt-4 opacity-70">Next: Timer / Pass / Elimination</div>
        </div>
    );
}
