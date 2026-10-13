"use client";

import { useEffect } from "react";
import { HomeButton } from "@/components/BackButton";
import { useI18n } from "@/lib/i18n";

export default function GlobalError({
    error,
    reset,
}: {
    error: Error & { digest?: string };
    reset: () => void;
}) {
    const { tr } = useI18n();
    useEffect(() => {
        console.error("Unhandled app error:", error);
    }, [error]);

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label={tr("Fehler")}>
                    <HomeButton corner />
                    <h1 className="h1" style={{ marginBottom: 10 }}>{tr("😵 Etwas ist schiefgelaufen")}</h1>
                    <p className="p hostSub" style={{ marginTop: 0 }}>
                        {tr("Die Seite ist abgestürzt. Dein Platz im Spiel ist gespeichert – Neuladen bringt dich meistens direkt zurück.")}
                    </p>
                    <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginTop: 18 }}>
                        <button type="button" className="btn btnPrimary" onClick={() => reset()}>
                            {tr("🔄 Erneut versuchen")}
                        </button>
                        <button
                            type="button"
                            className="btn btnSecondary"
                            onClick={() => window.location.reload()}
                        >
                            {tr("⟳ Seite neu laden")}
                        </button>
                    </div>
                </section>
            </div>
        </main>
    );
}
