"use client";

type PlayerRow = {
    player_id: string;
    name: string;
    ready: boolean | null;
};

type Props = {
    players: PlayerRow[];
    mePlayerId: string | null;
    hostPlayerId: string | null;
    loading?: boolean;
};

export function LobbyPlayersTable({
                                      players,
                                      mePlayerId,
                                      hostPlayerId,
                                      loading,
                                  }: Props) {
    return (
        <div style={{ overflowX: "auto" }}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead>
                <tr style={{ textAlign: "left", opacity: 0.75 }}>
                    <th style={{ padding: "10px 8px" }}>#</th>
                    <th style={{ padding: "10px 8px" }}>Name</th>
                    <th style={{ padding: "10px 8px", textAlign: "right" }}>
                        Zustand
                    </th>
                </tr>
                </thead>

                <tbody>
                {loading && players.length === 0 ? (
                    <tr>
                        <td
                            colSpan={3}
                            style={{ padding: "12px 8px", opacity: 0.75 }}
                        >
                            Lädt…
                        </td>
                    </tr>
                ) : null}

                {players.map((p, idx) => {
                    const isMe =
                        !!mePlayerId && p.player_id === mePlayerId;
                    const isHost =
                        !!hostPlayerId &&
                        p.player_id === hostPlayerId;

                    return (
                        <tr
                            key={p.player_id}
                            style={{
                                borderTop:
                                    "1px solid rgba(255,255,255,0.08)",
                                opacity: isMe ? 1 : 0.95,
                                background: isHost
                                    ? "rgba(255,255,255,0.07)"
                                    : "transparent",
                            }}
                        >
                            <td style={{ padding: "10px 8px" }}>
                                {idx + 1}
                            </td>

                            <td
                                style={{
                                    padding: "10px 8px",
                                    fontWeight: 900,
                                }}
                            >
                                {p.name}
                                {isMe ? (
                                    <span style={{ opacity: 0.6 }}>
                                            {" "}
                                        (du)
                                        </span>
                                ) : null}

                                {isHost ? (
                                    <span
                                        style={{
                                            marginLeft: 10,
                                            fontWeight: 950,
                                            padding: "4px 10px",
                                            borderRadius: 999,
                                            background:
                                                "rgba(255,255,255,0.08)",
                                            border:
                                                "1px solid rgba(255,255,255,0.10)",
                                        }}
                                    >
                                            👑 Host
                                        </span>
                                ) : null}
                            </td>

                            <td
                                style={{
                                    padding: "10px 8px",
                                    textAlign: "right",
                                    fontWeight: 950,
                                }}
                            >
                                {p.ready ? "✅ Bereit" : "⏳ nicht bereit"}
                            </td>
                        </tr>
                    );
                })}

                {!loading && players.length === 0 ? (
                    <tr>
                        <td
                            colSpan={3}
                            style={{ padding: "12px 8px", opacity: 0.75 }}
                        >
                            Noch niemand beigetreten.
                        </td>
                    </tr>
                ) : null}
                </tbody>
            </table>
        </div>
    );
}
