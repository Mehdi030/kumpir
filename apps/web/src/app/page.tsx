"use client";

import Link from "next/link";
import Image from "next/image";
import { supabase } from "@/lib/supabaseClient";
console.log(!!supabase);

export default function Home() {
    return (
        <main className="container">
            {/* Brand Logo: immer zurück zur Landing Page */}
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


            {/* Centered block: metaBar + card aligned */}
            <div className="landingWrap">
                {/* Meta-Pills: direkt über der Card, gleiche Breite */}
                <div className="metaBar" aria-hidden>
                    <div className="metaLeft">
                        <span className="metaPill">👥 2–10 Spieler</span>
                        <span className="metaPill">⚡ Live</span>
                        <span className="metaPill">🔒 Privat</span>
                    </div>
                    <div className="metaRight">
                        <span className="metaPill">v0 • lokal</span>
                    </div>
                </div>

                <section className="card">
                    <div className="heroRow">
                        <div className="brandRow">
                            <div>
                                <h1 className="h1">Kumpir</h1>
                                <p className="p subline">Das Spiel, bei dem Geben dein Leben rettet.</p>
                            </div>
                        </div>
                    </div>

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
                        <Link href="/host" className="btn btnPrimary">
                            Host starten
                        </Link>
                        <Link href="/join" className="btn btnSecondary">
                            Beitreten
                        </Link>
                    </div>
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
