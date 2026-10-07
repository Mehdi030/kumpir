"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

/** Alter Link "Solo gegen Bots": jetzt eine Kategorie auf /host (Bots und Stärke vor dem Start wählbar). */
export default function SoloPage() {
    const router = useRouter();
    useEffect(() => {
        router.replace("/host?modus=bots");
    }, [router]);
    return null;
}
