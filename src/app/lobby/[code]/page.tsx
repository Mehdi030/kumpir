type Props = {
    params: { code: string };
};

export default function LobbyPage({ params }: Props) {
    return (
        <main style={{ padding: 24, maxWidth: 720, margin: "0 auto" }}>
            <h1 style={{ fontSize: 28, fontWeight: 800 }}>Lobby</h1>
            <p style={{ marginTop: 8 }}>
                Lobby‑Code: <strong>{params.code}</strong>
            </p>

            <p style={{ marginTop: 16, opacity: 0.8 }}>
                Warte auf Spieler…
            </p>
        </main>
    );
}
