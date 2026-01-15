import Link from "next/link";

export default function Home() {
    return (
        <main className="container">
            <section className="card">
                {/* Header */}
                <div className="row" style={{ justifyContent: "space-between", gap: 14 }}>
                    <div className="row" style={{ gap: 12 }}>
                        <div
                            aria-hidden
                            style={{
                                width: 54,
                                height: 54,
                                borderRadius: 16,
                                background:
                                    "radial-gradient(circle at 30% 30%, rgba(167,139,250,.95), transparent 55%), radial-gradient(circle at 70% 70%, rgba(34,211,238,.75), transparent 55%), rgba(255,255,255,.06)",
                                border: "1px solid rgba(255,255,255,.16)",
                                boxShadow: "0 14px 40px rgba(0,0,0,.35)",
                            }}
                        />
                        <div>
                            <h1 className="h1">[NAME]</h1>
                            <p className="p" style={{ fontStyle: "italic" }}>
                                [Slogan kommt später]
                            </p>
                        </div>
                    </div>
                </div>

                {/* Infos */}
                <div style={{ marginTop: 18, display: "grid", gap: 10 }}>
                    <div className="row">
                        <div className="pill">👥 2–10 Spieler</div>
                        <div className="pill">⏱️ schnelle Runden</div>
                        <div className="pill">⚡ Realtime</div>
                        <div className="pill">🔒 Privat</div>
                    </div>

                    <p className="p" style={{ marginTop: 4 }}>
                        [Kurzbeschreibung kommt später]
                    </p>
                </div>

                {/* Actions */}
                <div className="row" style={{ marginTop: 20 }}>
                    <Link href="/host" className="btn btnPrimary">
                        Host starten
                    </Link>
                    <Link href="/join" className="btn btnSecondary">
                        Beitreten
                    </Link>

                    <span style={{ marginLeft: "auto", color: "rgba(255,255,255,.60)", fontSize: 13 }}>
            v0 • lokal
          </span>
                </div>
            </section>
        </main>
    );
}
