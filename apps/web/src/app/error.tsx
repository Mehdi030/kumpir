"use client";

import { useEffect } from "react";

export default function GlobalError({
    error,
    reset,
}: {
    error: Error & { digest?: string };
    reset: () => void;
}) {
    useEffect(() => {
        console.error("Unhandled app error:", error);
    }, [error]);

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Fehler">
                    <h1 className="h1" style={{ marginBottom: 10 }}>😵 Etwas ist schiefgelaufen</h1>
                    <p className="p hostSub" style={{ marginTop: 0 }}>
                        Die Seite ist abgestürzt. Deine Spieler-Identität ist lokal gespeichert — ein Neuladen
                        bringt dich in der Regel zurück ins Spiel.
                    </p>
                    <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginTop: 18 }}>
                        <button type="button" className="btn btnPrimary" onClick={() => reset()}>
                            🔄 Erneut versuchen
                        </button>
                        <button
                            type="button"
                            className="btn btnSecondary"
                            onClick={() => window.location.reload()}
                        >
                            ⟳ Seite neu laden
                        </button>
                        <a href="/host" className="btn btnSecondary">
                            ← Hauptmenü
                        </a>
                    </div>
                </section>
            </div>
        </main>
    );
}
