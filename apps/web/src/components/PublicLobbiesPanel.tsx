"use client";

import { useRouter } from "next/navigation";
import { usePublicLobbies, type PublicLobby } from "@/hooks/usePublicLobbies";

const MODE_ICON: Record<string, string> = {
    original: "🥔",
    teleport: "🌀",
    reverse: "🔁",
};

const SPEED_ICON: Record<string, { icon: string; label: string }> = {
    fast: { icon: "⚡", label: "Blitz" },
    normal: { icon: "🎯", label: "Standard" },
    calm: { icon: "🧊", label: "Casual" },
};

/**
 * Panel mit aktiven öffentlichen Lobbies. Wird auf der Landing-Page
 * rechts neben der Hero-Card angezeigt (auf mobile: darunter).
 */
export function PublicLobbiesPanel() {
    const router = useRouter();
    const { rows, loading, error } = usePublicLobbies(5000);

    return (
        <aside
            className="publicLobbies"
            aria-label="Öffentliche Lobbies"
            style={{
                width: "min(320px, 96vw)",
                borderRadius: 22,
                padding: 16,
                background: "rgba(0,0,0,0.22)",
                border: "1px solid rgba(255,255,255,0.14)",
                backdropFilter: "blur(12px)",
                WebkitBackdropFilter: "blur(12px)",
                boxShadow: "0 18px 70px rgba(0,0,0,0.28), inset 0 1px 0 rgba(255,255,255,0.10)",
                color: "white",
            }}
        >
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10 }}>
                <div style={{ fontWeight: 1000, fontSize: 14, letterSpacing: 0.8, textTransform: "uppercase", opacity: 0.92 }}>
                    🌐 Public Lobbies
                </div>
                <div style={{ fontSize: 11, opacity: 0.7, fontWeight: 800 }}>
                    {rows.length > 0 ? `${rows.length} offen` : ""}
                </div>
            </div>

            <div style={{ fontSize: 11, opacity: 0.7, marginBottom: 10, lineHeight: 1.4 }}>
                Hier kannst du fremden Spielern beitreten — keine Anmeldung, einfach klicken.
            </div>

            {loading ? (
                <div style={{ opacity: 0.6, fontSize: 13, padding: 12, textAlign: "center" }}>Lade…</div>
            ) : rows.length === 0 ? (
                <div
                    style={{
                        opacity: 0.55,
                        fontSize: 12,
                        padding: 16,
                        textAlign: "center",
                        background: "rgba(255,255,255,0.03)",
                        borderRadius: 12,
                        border: "1px dashed rgba(255,255,255,0.08)",
                    }}
                >
                    Gerade keine offenen Lobbies.<br />
                    Sei der Erste — Lobby hosten + Public wählen!
                </div>
            ) : (
                <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                    {rows.map((row) => (
                        <PublicLobbyCard
                            key={row.code}
                            row={row}
                            onJoin={() => router.push(`/join?code=${row.code}`)}
                        />
                    ))}
                </div>
            )}

            {error ? (
                <div style={{ fontSize: 10, opacity: 0.5, marginTop: 8 }}>
                    (Public-Lobbies View nicht verfügbar — Migration 009 ausführen)
                </div>
            ) : null}
        </aside>
    );
}

function PublicLobbyCard({ row, onJoin }: { row: PublicLobby; onJoin: () => void }) {
    const mode = MODE_ICON[row.game_mode] ?? "🥔";
    const speed = SPEED_ICON[row.round_speed] ?? { icon: "🎯", label: "Standard" };
    const isFull = row.player_count >= row.max_players;

    return (
        <button
            type="button"
            onClick={onJoin}
            disabled={isFull}
            style={{
                display: "flex",
                flexDirection: "column",
                gap: 6,
                padding: "10px 12px",
                borderRadius: 14,
                background: isFull ? "rgba(255,255,255,0.03)" : "rgba(255,255,255,0.07)",
                border: "1px solid rgba(255,255,255,0.08)",
                color: "white",
                textAlign: "left",
                cursor: isFull ? "not-allowed" : "pointer",
                opacity: isFull ? 0.5 : 1,
                transition: "background .15s, transform .12s",
                width: "100%",
            }}
            onMouseEnter={(e) => {
                if (!isFull) (e.currentTarget.style.background = "rgba(255,255,255,0.12)");
            }}
            onMouseLeave={(e) => {
                e.currentTarget.style.background = isFull ? "rgba(255,255,255,0.03)" : "rgba(255,255,255,0.07)";
            }}
        >
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <div style={{ fontWeight: 1000, fontSize: 17, letterSpacing: 1.5 }}>
                    {row.code}
                </div>
                <div style={{ fontSize: 12, fontWeight: 800, opacity: 0.85 }}>
                    👥 {row.player_count}/{row.max_players}
                </div>
            </div>
            <div style={{ display: "flex", gap: 8, fontSize: 11, fontWeight: 700, opacity: 0.85 }}>
                <span>{mode} {row.game_mode}</span>
                <span style={{ opacity: 0.5 }}>·</span>
                <span>{speed.icon} {speed.label}</span>
                {isFull ? (
                    <>
                        <span style={{ opacity: 0.5 }}>·</span>
                        <span style={{ color: "#ff453a", fontWeight: 950 }}>VOLL</span>
                    </>
                ) : null}
            </div>
        </button>
    );
}
