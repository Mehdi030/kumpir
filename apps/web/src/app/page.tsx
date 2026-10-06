"use client";

import Link from "next/link";
import Image from "next/image";
import { Suspense } from "react";
import { AuthMini } from "@/components/AuthMini";
import { LobbyExitNotice } from "@/components/LobbyExitNotice";
import { HomeStatsSection } from "@/components/HomeStatsSection";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

const STEPS = [
    { icon: "🎲", title: "Lobby öffnen", text: "Einer hostet, alle anderen kommen mit einem 4-stelligen Code dazu." },
    { icon: "🎧", title: "Song erkennen", text: "Ein Song läuft. Wer die Kumpir hat, tippt den Titel und gibt sie weiter." },
    { icon: "💥", title: "Nicht erwischen lassen", text: "Die Zündschnur wird kürzer. Wer sie beim Knall hält, fliegt raus." },
];

export default function Home() {
    return (
        <main className="container">
            <div className="landingWrap landingWrapDecor">
                <div className="potatoBg" aria-hidden="true">
                    <Image src="/HGLogo.webp" alt="" width={900} height={600} priority quality={80} className="potatoBgImg" />
                </div>

                <section className="card homeCard" aria-label="Kumpir Startseite">
                    <Suspense fallback={null}>
                        <LobbyExitNotice />
                    </Suspense>

                    <div className="homeTop">
                        <span className="homeBadge">👥 2–12 Spieler</span>
                        <div className="homeTopRight">
                            <Link href="/leaderboard" className="homeLink">
                                🏆 Bestenliste
                            </Link>
                            {!AUTH_DISABLED ? <AuthMini nextPath="/host" variant="header" /> : null}
                        </div>
                    </div>

                    <header className="homeHero">
                        <h1 className="h1 homeTitle">Kumpir</h1>
                        <p className="homeTagline">Die heiße Kartoffel mit Musik. Song erkennen, weitergeben, überleben.</p>
                    </header>

                    <div className="ctaRow homeCta">
                        <Link href="/solo" className="btn btnPrimary btnXL">
                            🤖 Solo ausprobieren
                        </Link>
                        <Link href="/host" className="btn btnSecondary btnXL">
                            🚀 Mit Freunden spielen
                        </Link>
                        <Link href="/join" className="btn btnSecondary btnXL">
                            Mit Code beitreten
                        </Link>
                    </div>
                    <p className="homeFree">Kein Download · Kein Konto nötig · „Solo ausprobieren“ startet in Sekunden</p>

                    <div className="homeSteps">
                        {STEPS.map((s, i) => (
                            <div key={s.title} className="homeStep">
                                <div className="homeStepIcon" aria-hidden>
                                    {s.icon}
                                </div>
                                <div className="homeStepTitle">
                                    {i + 1}. {s.title}
                                </div>
                                <div className="homeStepText">{s.text}</div>
                            </div>
                        ))}
                    </div>

                    <HomeStatsSection />
                </section>

                <footer className="homeFooter">v{process.env.NEXT_PUBLIC_BUILD_SHA ?? "dev"}</footer>
            </div>
        </main>
    );
}
