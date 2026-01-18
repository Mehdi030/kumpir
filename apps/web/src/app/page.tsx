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
                <Image src="/Logo.png" alt="Kumpir Logo" width={160} height={160} priority />
            </Link>

            <div className="landingWrap">
                {/* Meta-Pills: direkt über der Card */}
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
                    {/* HERO */}
                    <div style={{ display: "flex", justifyContent: "space-between", gap: 14, alignItems: "flex-start" }}>
                        <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
                            <div className="logoIcon" aria-hidden />
                            <div>
                                <h1 className="h1" style={{ lineHeight: 1.05 }}>
                                    Kumpir
                                </h1>
                                <p className="p" style={{ fontStyle: "italic", marginTop: 6 }}>
                                    Das Spiel, bei dem Geben dein Leben rettet.
                                </p>
                            </div>
                        </div>
                    </div>

                    {/* Kurzbeschreibung */}
                    <div style={{ marginTop: 16 }}>
                        <p className="p" style={{ maxWidth: 640 }}>
                            Die Zeit läuft. Einer hält.
                            <br />
                            Gib weiter, bevor der Countdown endet.
                            <br />
                            Wer zu lange hält, ist raus.
                        </p>
                    </div>

                    {/* So funktioniert’s */}
                    <div style={{ marginTop: 16 }}>
                        <div className="stepsBox">
                            <div className="stepsTitle">So funktioniert’s</div>
                            <div style={{ display: "grid", gap: 6 }}>
                                <Step n="1" title="Starten" text="Host erstellt eine Lobby." />
                                <Step n="2" title="Mitspielen" text="Alle treten bei und sind bereit." />
                                <Step n="3" title="Weitergeben" text="Gib weiter – bevor es zu spät ist." />
                            </div>
                        </div>
                    </div>

                    {/* Actions */}
                    <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginTop: 16 }}>
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
            <div>
                <div className="stepTitle">{title}</div>
                <div className="stepText">{text}</div>
            </div>
        </div>
    );
}
