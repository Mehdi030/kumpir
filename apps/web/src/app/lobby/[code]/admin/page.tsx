"use client";

import { useEffect } from "react";
import { useParams, useRouter } from "next/navigation";

/**
 * Früher eigene Einstellungen-Seite. Seit 2026-10-13 ändert der Host alles direkt in der Lobby
 * (Kacheln oben + Playlists + Spieler-Knöpfe). Alte Links landen hier und werden weitergeleitet.
 */
export default function LobbySettingsRedirect() {
    const params = useParams<{ code: string }>();
    const router = useRouter();
    const code = String(params.code ?? "").toUpperCase();

    useEffect(() => {
        router.replace(`/lobby/${encodeURIComponent(code)}`);
    }, [code, router]);

    return null;
}
