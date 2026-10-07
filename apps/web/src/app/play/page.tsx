"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

/** Früher Auswahl "Solo / Mit Freunden" – beides steht jetzt direkt auf /host (Kategorien). */
export default function PlayPage() {
    const router = useRouter();
    useEffect(() => {
        router.replace("/host");
    }, [router]);
    return null;
}
