import Link from "next/link";
import { supabase } from "@/lib/supabaseClient";
console.log(!!supabase);

export default function Home() {
    return (
        <main className="container">
            {/* Meta Pills (optional – bleiben wie bei dir) */}
            <div className="metaFloat metaLeft" aria-hidden>
                <span className="metaPill">👥 2–10 Spieler</span>
                <span className="metaPill">⚡ Live</span>
                <span className="metaPill">🔒 Privat</span>
            </div>
            <div className="metaFloat metaRight" aria-hidden>
                <span className="metaPill">v0 • lokal</span>
            </div>

            {/* ONE PREMIUM CARD – truly centered */}
            <section className="card cardLanding">
                {/* HERO */}
                <div className="heroTop">
                    <div className="brandRow">
                        <div className="logoIcon" aria-hidden />
                        <div>
                            <h1 className="h1">Kumpir</h1>
                            <p className="subline">Das Spiel, bei dem Geben dein Leben rettet.</p>
                        </div>
                    </div>

                    <p className="p heroCopy">
                        Die Zeit läuft. Einer hält.
                        <br />
                        Gib weiter, bevor der Countdown endet.
                        <br />
                        Wer zu lange hält, ist raus.
                    </p>

                    <div className="ctaRow">
                        <Link href="/host" className="btn btnPrimary">
                            Host starten
                        </Link>
                        <Link href="/join" className="btn btnSecondary">
                            Beitreten
                        </Link>
                    </div>

                    <div className="microHint">
                        Kein Account. Nur Name + Code. Perfekt für schnelle Runden.
                    </div>
                </div>

                {/* DIVIDER */}
                <div className="dividerSoft" />

                {/* CONTENT GRID: How it works + Features */}
                <div className="landingGrid">
                    {/* Steps */}
                    <div className="stepsPanel">
                        <div className="stepsTitle">So funktioniert’s</div>
                        <div className="stepsList">
                            <Step n="1" title="Starten" text="Host erstellt eine Lobby." />
                            <Step n="2" title="Mitspielen" text="Alle treten bei und sind bereit." />
                            <Step n="3" title="Weitergeben" text="Gib weiter – bevor es zu spät ist." />
                        </div>
                    </div>

                    {/* Features */}
                    <div className="featurePanel">
                        <div className="stepsTitle">Features</div>
                        <div className="featureGrid">
                            <Feature icon="⚡" title="Realtime" text="Lobby-Updates ohne Refresh." />
                            <Feature icon="🔒" title="Privat" text="Join per 4-Stelliger Code." />
                            <Feature icon="⏱️" title="Schnell" text="Runden: 15s / 20s / 30s." />
                        </div>

                        <div className="comingRow">
                            <span className="tagPill">Classic</span>
                            <span className="tagPill">Reverse (später)</span>
                            <span className="tagPill">Teleport (später)</span>
                        </div>
                    </div>
                </div>
            </section>
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

function Feature({ icon, title, text }: { icon: string; title: string; text: string }) {
    return (
        <div className="featureCard">
            <div className="featureHead">
                <div className="featureIcon" aria-hidden>
                    {icon}
                </div>
                <div className="featureTitle">{title}</div>
            </div>
            <div className="featureText">{text}</div>
        </div>
    );
}
