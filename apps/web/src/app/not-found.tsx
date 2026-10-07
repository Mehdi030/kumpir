import Link from "next/link";

export const metadata = { title: "Seite nicht gefunden" };

/** Eigene 404-Seite im Kumpir-Stil (statt der schwarzen englischen Standardseite). */
export default function NotFound() {
    return (
        <main className="container">
            <div className="landingWrap" style={{ width: "min(560px, 100%)" }}>
                <section className="card nfCard" aria-label="Seite nicht gefunden">
                    <div className="nfPotato" aria-hidden>
                        🥔
                    </div>
                    <div className="nfCode">404</div>
                    <h1 className="h1 nfTitle">Hier ist nichts heiß.</h1>
                    <p className="p hostSub nfText">Diese Seite gibt es nicht – vielleicht ein alter Link oder ein Tippfehler. Die Kartoffel wartet woanders auf dich.</p>
                    <div className="ctaRow nfActions">
                        <Link href="/" className="btn btnPrimary">
                            🏠 Zur Startseite
                        </Link>
                        <Link href="/join" className="btn btnSecondary">
                            Mit Code beitreten
                        </Link>
                    </div>
                </section>
            </div>
        </main>
    );
}
