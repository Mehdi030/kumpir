"use client";

import Link from "next/link";
import Image from "next/image";

export default function Home() {
    return (
        <main className="container">
            {/* Brand Logo */}
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image
                    src="/logo.png"
                    alt="Kumpir Maskottchen"
                    width={160}
                    height={160}
                    priority
                    className="brandLogoImg"
                />
            </Link>

            <div className="landingWrap">
                {/* Meta-Pills */}
                <div className="metaBar">
                    <div className="metaLeft">
                        <span className="metaPill">👥 2–10 Spieler</span>
                        <span className="metaPill">⚡ Live</span>
                        <span className="metaPill">🔒 Privat</span>
                    </div>
                    <div className="metaRight">
                        <span className="metaPill">v0 • lokal</span>
                    </div>
                </div>

                <section className="card" aria-label="Kumpir Landing Card">
                    <header className="heroRow">
                        <div className="brandRow">
                            <h1 className="h1">Kumpir</h1>
                        </div>
                    </header>

                    <div className="heroCopy">
                        <p className="p">
                            Die Zeit läuft. Einer hält.
                            <br />
                            Gib weiter, bevor der Countdown endet.
                            <br />
                            Wer zu lange hält, ist raus.
                        </p>
                    </div>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">So funktioniert’s</div>
                            <div className="stepsList">
                                <Step n="1" title="Starten" text="Host erstellt eine Lobby." />
                                <Step n="2" title="Mitspielen" text="Alle treten bei und sind bereit." />
                                <Step n="3" title="Weitergeben" text="Gib weiter – bevor es zu spät ist." />
                            </div>
                        </div>
                    </div>

                    <div className="ctaRow">
                        <div className="ctaStack">
                            <Link href="/host" className="btn btnPrimary">
                                Spiel hosten
                            </Link>
                            <div className="ctaHint">Erstellt eine Lobby für Freunde</div>
                        </div>

                        <div className="ctaStack">
                            <Link href="/join" className="btn btnSecondary">
                                Mit Code beitreten
                            </Link>
                            <div className="ctaHint">Ohne Account spielbar</div>
                        </div>
                    </div>

                    <p className="trustLine">
                        Kein Download. Kein Account nötig. Läuft direkt im Browser.
                    </p>
                </section>
            </div>
        </main>
    );
}

function Step({ n, title, text }: { n: string; title: string; text: string }) {
    return (
        <div className="stepRow">
            <div className="stepBadge" aria-hidden>
                {n}
            </div>
            <div className="stepBody">
                <div className="stepTitle">{title}</div>
                <div className="stepText">{text}</div>
            </div>
        </div>
    );
}
