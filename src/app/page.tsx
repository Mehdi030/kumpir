import Link from "next/link";

export default function Home() {
    return (
        <main style={{ padding: 24, maxWidth: 720, margin: "0 auto" }}>
            <h1 style={{ fontSize: 34, fontWeight: 800 }}>RELAY</h1>
            <p style={{ marginTop: 8, opacity: 0.8 }}>
                Browser‑Partyspiel mit 4‑stelligem Lobby‑Code.
            </p>

            <div style={{ display: "flex", gap: 12, marginTop: 20 }}>
                <Link href="/host">Host</Link>
                <Link href="/join">Join</Link>
            </div>
        </main>
    );
}
