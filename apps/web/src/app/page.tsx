"use client";

import Link from "next/link";
import Image from "next/image";
import { AuthMini } from "@/components/AuthMini";
import { PublicLobbiesPanel } from "@/components/PublicLobbiesPanel";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

export default function Home() {
    return (
        <main className="container">
            <div
                className="landingWrap landingWrapDecor"
                style={{ display: "flex", alignItems: "flex-start", gap: 20, justifyContent: "center", flexWrap: "wrap" }}
            >
                {/* Decor / Mascot – hangs over the card */}
                <div className="potatoBg" aria-hidden="true">
                    <Image
                        src="/HGLogo.png"
                        alt=""
                        width={900}
                        height={600}
                        priority
                        quality={100}
                        className="potatoBgImg"
                    />
                </div>

                {/* FOREGROUND card */}
                <section className="card" aria-label="Kumpir Landing Card">
                    <div className="metaBar metaBarInCard">
                        <div className="metaLeft">
                            <span className="metaPill">👥 2–10 Spieler</span>
                        </div>
                        <div className="metaRight" style={{ display: "flex", alignItems: "center", gap: 10 }}>
                            {AUTH_DISABLED ? (
                                <span className="metaPill">v0 • Gast-Modus</span>
                            ) : (
                                <AuthMini nextPath="/host" variant="header" />
                            )}
                        </div>
                    </div>

                    <header className="heroRow">
                        <div className="brandRow">
                            <h1 className="h1">Kumpir</h1>
                        </div>
                    </header>

                    <div className="heroCopy">
                        <p className="p">
                            Die Kumpir wandert.<br />
                            Der Timer kennt kein Mitleid.<br />
                            Wer zögert verliert.
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

                    <p className="trustLine">Kein Download · Kein Account · Startet in Sekunden</p>
                </section>

                <PublicLobbiesPanel />
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
