"use client";

import Link from "next/link";
import { HomeButton } from "@/components/BackButton";
import { useI18n } from "@/lib/i18n";

/** Freundliche Fehlerseite, wenn ein Lobby-Code nicht (mehr) existiert. */
export function LobbyNotFound({ code }: { code?: string }) {
    const { tr } = useI18n();
    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" style={{ textAlign: "center" }} aria-label={tr("Lobby nicht gefunden")}>
                    <HomeButton corner />
                    <div style={{ fontSize: 44 }} aria-hidden>
                        🔍
                    </div>
                    <h1 className="h1" style={{ fontSize: 36, marginTop: 6 }}>
                        {tr("Lobby nicht gefunden")}
                    </h1>
                    <p className="p" style={{ margin: "10px auto 0", maxWidth: 420 }}>
                        {code ? (
                            <>
                                {tr("Zum Code {code} gibt es keine offene Lobby.", { code })} {tr("Vielleicht ist der Code falsch oder die Lobby wurde schon geschlossen.")}
                            </>
                        ) : (
                            tr("Vielleicht ist der Code falsch oder die Lobby wurde schon geschlossen.")
                        )}
                    </p>
                    <div className="ctaRow" style={{ marginTop: 20 }}>
                        <Link href="/join" className="btn btnPrimary btnXL">
                            {tr("Anderen Code eingeben")}
                        </Link>
                        <Link href="/host" className="btn btnSecondary btnXL">
                            {tr("Neue Lobby erstellen")}
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
