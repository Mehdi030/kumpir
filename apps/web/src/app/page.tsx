import Link from "next/link";
import { supabase } from "@/lib/supabaseClient";
console.log(!!supabase);

export default function Home() {
    return (
        <main className="container">
            {/* Technische Infos bewusst AUSSERHALB der Card */}
            <div className="metaFloat metaLeft">
                <span className="metaPill">👥 2–10 Spieler</span>
                <span className="metaPill">⚡ Live</span>
                <span className="metaPill">🔒 Privat</span>
            </div>
            <div className="metaFloat metaRight">
                <span className="metaPill">v0 • lokal</span>
            </div>

            <section className="card">
                {/* HERO */}
                <div className="row" style={{ justifyContent: "space-between", gap: 14, alignItems: "flex-start" }}>
                    <div className="row" style={{ gap: 12, alignItems: "center" }}>
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

                {/* Kurzbeschreibung (kürzer + leichter zu scannen) */}
                <div style={{ marginTop: 16 }}>
                    <p className="p" style={{ maxWidth: 640 }}>
                        Die Zeit läuft. Einer hält.
                        <br />
                        Gib weiter, bevor der Countdown endet.
                        <br />
                        Wer zu lange hält, ist raus.
                    </p>
                </div>

                {/* So funktioniert’s (reduziert) */}
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

                {/* Actions (ohne Tipp/Technik, ohne Modi/Coming Soon) */}
                <div className="row" style={{ marginTop: 16, gap: 10 }}>
                    <Link href="/host" className="btn btnPrimary">
                        Host starten
                    </Link>
                    <Link href="/join" className="btn btnSecondary">
                        Beitreten
                    </Link>
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
            <div>
                <div className="stepTitle">{title}</div>
                <div className="stepText">{text}</div>
            </div>
        </div>
    );
}
