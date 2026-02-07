"use client";

import { useEffect, useState } from "react";

function readStoredPlayerId(): string | null {
    if (typeof window === "undefined") return null;
    return localStorage.getItem("kumpir_player_id") || sessionStorage.getItem("kumpir_player_id");
}

function readStoredName(): string | null {
    if (typeof window === "undefined") return null;
    return localStorage.getItem("kumpir_player_name") || sessionStorage.getItem("kumpir_player_name");
}

export function usePlayerIdentity() {
    const [mePlayerId, setMePlayerId] = useState<string | null>(null);
    const [meName, setMeName] = useState<string | null>(null);

    useEffect(() => {
        const sync = () => {
            const pid = readStoredPlayerId();
            const nm = readStoredName();
            setMePlayerId((prev) => pid ?? prev);
            setMeName((prev) => nm ?? prev);
        };

        sync();

        const onStorage = (e: StorageEvent) => {
            if (e.key === "kumpir_player_id" || e.key === "kumpir_player_name") sync();
        };

        window.addEventListener("storage", onStorage);
        window.addEventListener("focus", sync);
        document.addEventListener("visibilitychange", sync);

        const t = window.setInterval(sync, 500);

        return () => {
            window.removeEventListener("storage", onStorage);
            window.removeEventListener("focus", sync);
            document.removeEventListener("visibilitychange", sync);
            window.clearInterval(t);
        };
    }, []);

    return { mePlayerId, meName };
}
