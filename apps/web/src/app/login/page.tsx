"use client";

import Link from "next/link";

export default function LoginPage() {
    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Login deaktiviert">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Login deaktiviert</h1>
                        </div>
                        <p className="p hostSub">
                            Auth ist aktuell im Dev-Modus aus. Du kannst als Gast spielen.
                        </p>
                    </header>

                    <div className="panel">
                        <div className="previewCard">
                            <div className="fieldHelp" style={{ opacity: 0.92 }}>
                                Später kannst du diese Seite wieder aktivieren, ohne irgendwas zu löschen.
                            </div>

                            <div className="actionsRow" style={{ marginTop: 14 }}>
                                <Link href="/" className="btn btnPrimary">
                                    Zur Startseite
                                </Link>
                                <Link href="/join" className="btn btnSecondary">
                                    Lobby beitreten
                                </Link>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
