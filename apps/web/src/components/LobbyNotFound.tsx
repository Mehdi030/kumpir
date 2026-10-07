"use client";

import Link from "next/link";
import { HomeButton } from "@/components/BackButton";

/** Freundliche Fehlerseite, wenn ein Lobby-Code nicht (mehr) existiert. */
export function LobbyNotFound({ code }: { code?: string }) {
    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" style={{ textAlign: "center" }} aria-label="Lobby nicht gefunden">
                    <HomeButton corner />
                    <div style={{ fontSize: 44 }} aria-hidden>
                        🔍
                    </div>
                    <h1 className="h1" style={{ fontSize: 36, marginTop: 6 }}>
                        Lobby nicht gefunden
                    </h1>
                    <p className="p" style={{ margin: "10px auto 0", maxWidth: 420 }}>
                        {code ? (
                            <>
                                Zum Code <b>{code}</b> gibt es keine offene Lobby. Vielleicht ist der Code falsch oder die Lobby wurde schon geschlossen.
                            </>
                        ) : (
                            "Vielleicht ist der Code falsch oder die Lobby wurde schon geschlossen."
                        )}
                    </p>
                    <div className="ctaRow" style={{ marginTop: 20 }}>
                        <Link href="/join" className="btn btnPrimary btnXL">
                            Anderen Code eingeben
                        </Link>
                        <Link href="/host" className="btn btnSecondary btnXL">
                            Neue Lobby erstellen
                        </Link>
                    </div>
                </section>
            </div>
        </main>
    );
}

/** Rohe Datenbank-Fehlertexte in verständliche Sätze übersetzen. */
export function isNotFoundError(message: string | null | undefined): boolean {
    const m = (message ?? "").toLowerCase();
    return m.includes("coerce") || m.includes("nicht gefunden") || m.includes("not found") || m.includes("0 rows");
}
