"use client";

import { useEffect } from "react";
import { useParams, useRouter } from "next/navigation";

/**
 * Die Einstellungen (Max. Spieler, Modus, Thema, ...) leben jetzt direkt im
 * Admin Panel (/lobby/[code]/admin) -- vorher war diese Seite von nirgends
 * verlinkt und damit für den Host praktisch unauffindbar. Alter Link/
 * Lesezeichen landet hier weiterhin, wird aber sofort weitergeleitet.
 */
export default function LobbySettingsRedirect() {
    const params = useParams<{ code: string }>();
    const router = useRouter();
    const code = String(params.code ?? "").toUpperCase();

    useEffect(() => {
        router.replace(`/lobby/${encodeURIComponent(code)}/admin`);
    }, [code, router]);

    return null;
}
