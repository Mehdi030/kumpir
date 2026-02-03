"use client";

import Link from "next/link";

export default function VerifiedPage() {
    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Bestätigt">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">✅ Bestätigt</h1>
                        </div>
                        <p className="p hostSub">Deine E-Mail wurde bestätigt. Du kannst jetzt fortfahren.</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                <div className="actionsRow" style={{ gap: 10 }}>
                                    <Link href="/login?next=%2Fhost" className="btn btnPrimary">
                                        Weiter zum Login
                                    </Link>
                                    <Link href="/" className="btn btnSecondary">
                                        Zur Startseite
                                    </Link>
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9 }}>
                                    Falls du dich gerade bestätigt hast: geh einfach zurück zum Login und melde dich an.
                                </div>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
