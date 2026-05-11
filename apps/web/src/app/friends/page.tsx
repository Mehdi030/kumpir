"use client";

import Link from "next/link";
import { useCallback, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { useFriends } from "@/hooks/useFriends";
import { useSavedLobbies } from "@/hooks/useSavedLobbies";
import { Spinner } from "@/components/Spinner";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

export default function FriendsPage() {
    const { user, loading: authLoading } = useAuth();
    const friends = useFriends(user?.id ?? null);
    const saved = useSavedLobbies(user?.id ?? null);

    const [usernameToAdd, setUsernameToAdd] = useState("");
    const [feedback, setFeedback] = useState<{ ok: boolean; msg: string } | null>(null);
    const [busy, setBusy] = useState(false);

    const handleAdd = useCallback(async () => {
        if (busy) return;
        const name = usernameToAdd.trim();
        if (!name) return;
        setBusy(true);
        const err = await friends.sendRequest(name);
        setBusy(false);
        if (err) {
            const msg = err.includes("user_not_found") ? "Username nicht gefunden."
                : err.includes("cannot_befriend_self") ? "Dich selbst kannst du nicht anfreunden 🙃"
                : err;
            setFeedback({ ok: false, msg });
        } else {
            setUsernameToAdd("");
            setFeedback({ ok: true, msg: `✅ Anfrage an ${name} geschickt.` });
        }
        window.setTimeout(() => setFeedback(null), 3000);
    }, [busy, usernameToAdd, friends]);

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <section className="card">
                    <h1 className="h1">Freunde</h1>
                    <p className="p hostSub">Im Gast-Modus gibt&apos;s keine Freundeslisten.</p>
                    <Link href="/" className="btn btnSecondary">← Startseite</Link>
                </section>
            </main>
        );
    }

    if (authLoading) {
        return (
            <main className="container">
                <div style={{ display: "grid", placeItems: "center", padding: 32 }}>
                    <Spinner size={28} />
                </div>
            </main>
        );
    }

    if (!user) {
        return (
            <main className="container">
                <section className="card">
                    <h1 className="h1">Freunde</h1>
                    <p className="p hostSub">Du musst eingeloggt sein.</p>
                    <Link href="/login?next=/friends" className="btn btnPrimary">🔓 Einloggen</Link>
                </section>
            </main>
        );
    }

    return (
        <main className="container">
            <section className="card" style={{ maxWidth: 820, margin: "0 auto" }}>
                <header className="hostHeader" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 12 }}>
                    <h1 className="h1">👥 Freunde</h1>
                    <Link href="/" className="btn btnSecondary btnSmall">← Startseite</Link>
                </header>

                {/* Eingehende Anfragen — ganz oben weil action required */}
                {friends.incoming.length > 0 ? (
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">📥 Eingehende Anfragen ({friends.incoming.length})</div>
                        </div>
                        <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 10 }}>
                            {friends.incoming.map((f) => (
                                <div key={f.user_id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, padding: "8px 10px", borderRadius: 10, background: "rgba(255,255,255,0.04)" }}>
                                    <div style={{ fontWeight: 900 }}>{f.friend_username}</div>
                                    <div style={{ display: "flex", gap: 6 }}>
                                        <button type="button" className="btn btnReadyOn btnSmall" onClick={() => void friends.acceptRequest(f.user_id)}>✅ Annehmen</button>
                                        <button type="button" className="btn btnReadyOff btnSmall" onClick={() => void friends.removeFriend(f.user_id)}>❌</button>
                                    </div>
                                </div>
                            ))}
                        </div>
                    </div>
                ) : null}

                {/* Username eingeben → Anfrage */}
                <div className="pillCard" style={{ marginTop: 14 }}>
                    <div className="pillCardTop">
                        <div className="pillCardTitle">Freund hinzufügen</div>
                        <div className="pillCardHint">Per Username</div>
                    </div>
                    <div style={{ display: "flex", gap: 10, marginTop: 10 }}>
                        <input
                            className="pillInput"
                            value={usernameToAdd}
                            onChange={(e) => setUsernameToAdd(e.target.value)}
                            onKeyDown={(e) => { if (e.key === "Enter") void handleAdd(); }}
                            placeholder="z.B. medo"
                            style={{ flex: 1 }}
                            maxLength={40}
                            autoComplete="off"
                        />
                        <button type="button" className="btn btnPrimary btnSmall" onClick={() => void handleAdd()} disabled={busy || !usernameToAdd.trim()}>
                            {busy ? "…" : "Anfragen"}
                        </button>
                    </div>
                    {feedback ? (
                        <div className={`fieldHelp ${feedback.ok ? "" : "fieldHelpError"}`} style={{ marginTop: 8 }}>
                            {feedback.msg}
                        </div>
                    ) : null}
                </div>

                {/* Akzeptierte Freunde */}
                <div className="pillCard" style={{ marginTop: 14 }}>
                    <div className="pillCardTop">
                        <div className="pillCardTitle">Deine Freunde ({friends.accepted.length})</div>
                    </div>
                    {friends.loading ? (
                        <div style={{ padding: 12 }}><Spinner size={18} /></div>
                    ) : friends.accepted.length === 0 ? (
                        <div className="fieldHelp" style={{ marginTop: 8, opacity: 0.8 }}>Noch keine. Schick eine Anfrage oben.</div>
                    ) : (
                        <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 10 }}>
                            {friends.accepted.map((f) => (
                                <div key={f.friend_user_id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 10px", borderRadius: 10, background: "rgba(255,255,255,0.04)" }}>
                                    <div style={{ fontWeight: 900 }}>{f.friend_username}</div>
                                    <button type="button" className="btn btnSecondary btnSmall" onClick={() => void friends.removeFriend(f.friend_user_id)} title="Freund entfernen">
                                        🗑️
                                    </button>
                                </div>
                            ))}
                        </div>
                    )}
                </div>

                {/* Ausgehende (pending) */}
                {friends.outgoing.length > 0 ? (
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">📤 Ausgehend ({friends.outgoing.length})</div>
                            <div className="pillCardHint">Warten auf Bestätigung</div>
                        </div>
                        <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 10 }}>
                            {friends.outgoing.map((f) => (
                                <div key={f.friend_user_id} style={{ display: "flex", justifyContent: "space-between", padding: "8px 10px", borderRadius: 10, background: "rgba(255,255,255,0.04)", opacity: 0.75 }}>
                                    <div style={{ fontWeight: 800 }}>{f.friend_username}</div>
                                    <button type="button" className="btn btnSecondary btnSmall" onClick={() => void friends.removeFriend(f.friend_user_id)}>Abbrechen</button>
                                </div>
                            ))}
                        </div>
                    </div>
                ) : null}

                {/* Gespeicherte Lobbies */}
                <div className="pillCard" style={{ marginTop: 14 }}>
                    <div className="pillCardTop">
                        <div className="pillCardTitle">💾 Gespeicherte Lobbies ({saved.rows.length})</div>
                        <div className="pillCardHint">Beim Spielen im Lobby-Header sichtbar</div>
                    </div>
                    {saved.loading ? (
                        <div style={{ padding: 12 }}><Spinner size={18} /></div>
                    ) : saved.rows.length === 0 ? (
                        <div className="fieldHelp" style={{ marginTop: 8, opacity: 0.8 }}>{`Noch keine. In jeder Lobby kannst du sie als „gemerkt" speichern.`}</div>
                    ) : (
                        <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 10 }}>
                            {saved.rows.map((s) => (
                                <div key={s.lobby_code} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 10px", borderRadius: 10, background: "rgba(255,255,255,0.04)" }}>
                                    <div>
                                        <div style={{ fontWeight: 900 }}>{s.nickname}</div>
                                        <div style={{ fontSize: 12, opacity: 0.7 }}>{s.lobby_code}</div>
                                    </div>
                                    <div style={{ display: "flex", gap: 6 }}>
                                        <Link href={`/join?code=${s.lobby_code}`} className="btn btnPrimary btnSmall">Beitreten</Link>
                                        <button type="button" className="btn btnSecondary btnSmall" onClick={() => void saved.unsave(s.lobby_code)} title="Löschen">🗑️</button>
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            </section>
        </main>
    );
}
