"use client";

import Link from "next/link";
import { useCallback, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { useFriends } from "@/hooks/useFriends";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

function friendError(err: string): string {
    if (err.includes("user_not_found")) return "Benutzername nicht gefunden.";
    if (err.includes("cannot_befriend_self")) return "Dich selbst kannst du nicht anfreunden.";
    if (err.includes("rate")) return "Zu viele Anfragen – bitte später wieder.";
    return err;
}

/**
 * Freunde-Dock am rechten Bildschirmrand (auf dem Handy unter der Karte):
 * Freund per Benutzername hinzufügen, Anfragen annehmen, Freundesliste.
 * Gäste sehen nur einen Hinweis (Freunde gibt es nur mit Konto).
 */
export function HomeFriendsDock() {
    const { user, loading } = useAuth();
    const friends = useFriends(user?.id ?? null);
    const [name, setName] = useState("");
    const [busy, setBusy] = useState(false);
    const [fb, setFb] = useState<{ ok: boolean; msg: string } | null>(null);
    const [all, setAll] = useState(false);

    const add = useCallback(async () => {
        const n = name.trim();
        if (!n || busy) return;
        setBusy(true);
        const err = await friends.sendRequest(n);
        setBusy(false);
        if (err) setFb({ ok: false, msg: friendError(err) });
        else {
            setName("");
            setFb({ ok: true, msg: `Anfrage an ${n} geschickt.` });
        }
        window.setTimeout(() => setFb(null), 3500);
    }, [name, busy, friends]);

    if (GUEST_ONLY || loading) return null;

    if (!user) {
        return (
            <aside className="sideDock sideDockRight" aria-label="Freunde">
                <div className="sideDockHead static">
                    <span>👥 Freunde</span>
                </div>
                <div className="sideDockNote">Freunde hinzufügen geht mit einem Konto – oben rechts anmelden oder registrieren.</div>
            </aside>
        );
    }

    const shown = all ? friends.accepted : friends.accepted.slice(0, 5);

    return (
        <aside className="sideDock sideDockRight open" aria-label="Freunde">
            <div className="sideDockHead static">
                <span>👥 Freunde</span>
                {friends.incoming.length ? <span className="sideDockBadge">{friends.incoming.length} neu</span> : null}
            </div>

            <div className="sideDockAdd">
                <input
                    className="sideDockInput"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    onKeyDown={(e) => {
                        if (e.key === "Enter") void add();
                    }}
                    placeholder="Benutzername hinzufügen"
                    maxLength={40}
                    autoComplete="off"
                    aria-label="Benutzername des Freundes"
                />
                <button type="button" className="btn btnPrimary btnSmall" onClick={() => void add()} disabled={busy || !name.trim()}>
                    {busy ? "…" : "＋"}
                </button>
            </div>
            {fb ? <div className={`sideDockFb ${fb.ok ? "ok" : "err"}`}>{fb.msg}</div> : null}

            {friends.incoming.length ? (
                <div className="sideDockList">
                    <div className="sideDockSub">Anfragen</div>
                    {friends.incoming.map((f) => (
                        <div key={f.user_id} className="sideDockFriend">
                            <span className="sideDockName">{f.friend_username}</span>
                            <span className="sideDockBtns">
                                <button type="button" className="btn btnReadyOn btnSmall" onClick={() => void friends.acceptRequest(f.user_id)} title="Annehmen">
                                    ✅
                                </button>
                                <button type="button" className="btn btnReadyOff btnSmall" onClick={() => void friends.removeFriend(f.user_id)} title="Ablehnen">
                                    ❌
                                </button>
                            </span>
                        </div>
                    ))}
                </div>
            ) : null}

            <div className="sideDockList">
                <div className="sideDockSub">Deine Freunde ({friends.accepted.length})</div>
                {friends.loading ? (
                    <div className="sideDockNote">Lade…</div>
                ) : friends.accepted.length === 0 ? (
                    <div className="sideDockNote">Noch keine – gib oben einen Benutzernamen ein.</div>
                ) : (
                    shown.map((f) => (
                        <div key={f.friend_user_id} className="sideDockFriend">
                            <span className="sideDockName">{f.friend_username}</span>
                        </div>
                    ))
                )}
                {friends.accepted.length > 5 ? (
                    <button type="button" className="sideDockHint" onClick={() => setAll((v) => !v)}>
                        {all ? "Weniger anzeigen" : `Alle ${friends.accepted.length} anzeigen`}
                    </button>
                ) : null}
                {friends.outgoing.length ? <div className="sideDockNote">Wartet auf Antwort: {friends.outgoing.map((o) => o.friend_username).join(", ")}</div> : null}
            </div>

            <Link href="/friends" className="sideDockLink">
                Freunde verwalten →
            </Link>
        </aside>
    );
}
