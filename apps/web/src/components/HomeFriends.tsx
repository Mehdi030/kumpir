"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { useFriends } from "@/hooks/useFriends";
import { useFriendsStatus, type FriendStatus } from "@/hooks/useFriendsStatus";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

const PALETTE = ["#f59e0b", "#ef4444", "#8b5cf6", "#06b6d4", "#22c55e", "#ec4899", "#3b82f6", "#f97316"];
function colorFor(name: string): string {
    let h = 0;
    for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return PALETTE[h % PALETTE.length]!;
}

function friendError(err: string): string {
    if (err.includes("user_not_found")) return "Diesen Benutzernamen gibt es nicht.";
    if (err.includes("cannot_befriend_self")) return "Dich selbst kannst du nicht hinzufügen.";
    if (err.includes("already") || err.includes("duplicate")) return "Ihr seid schon befreundet oder die Anfrage läuft.";
    if (err.includes("rate")) return "Zu viele Anfragen – bitte später noch einmal.";
    return err;
}

function lastSeenText(iso: string | null): string {
    if (!iso) return "Noch nie gesehen";
    const mins = Math.max(1, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
    if (mins < 60) return `Zuletzt vor ${mins} Min.`;
    const h = Math.round(mins / 60);
    if (h < 48) return `Zuletzt vor ${h} Std.`;
    return `Zuletzt vor ${Math.round(h / 24)} Tagen`;
}

type Filter = "all" | "online";

/**
 * Freunde im Hauptmenü: Karten mit Avatar und Online-Status, Online-Freunde zuerst,
 * Filter "Alle / Online", Freund per Benutzername hinzufügen, Anfragen annehmen.
 */
export function HomeFriends() {
    const { user, loading } = useAuth();
    const friendsApi = useFriends(user?.id ?? null);
    const status = useFriendsStatus(user?.id ?? null);

    const [filter, setFilter] = useState<Filter>(() => {
        try {
            return window.localStorage.getItem("kumpir_friends_filter") === "online" ? "online" : "all";
        } catch {
            return "all";
        }
    });
    const [adding, setAdding] = useState(false);
    const [name, setName] = useState("");
    const [busy, setBusy] = useState(false);
    const [fb, setFb] = useState<{ ok: boolean; msg: string } | null>(null);
    const [confirmRemove, setConfirmRemove] = useState<string | null>(null);

    useEffect(() => {
        if (!confirmRemove) return;
        const t = window.setTimeout(() => setConfirmRemove(null), 3000);
        return () => window.clearTimeout(t);
    }, [confirmRemove]);

    const pickFilter = useCallback((f: Filter) => {
        setFilter(f);
        try {
            window.localStorage.setItem("kumpir_friends_filter", f);
        } catch {
            /* privater Modus */
        }
    }, []);

    const add = useCallback(async () => {
        const n = name.trim();
        if (!n || busy) return;
        setBusy(true);
        const err = await friendsApi.sendRequest(n);
        setBusy(false);
        if (err) setFb({ ok: false, msg: friendError(err) });
        else {
            setName("");
            setFb({ ok: true, msg: `Anfrage an ${n} geschickt.` });
        }
        window.setTimeout(() => setFb(null), 4000);
    }, [name, busy, friendsApi]);

    const onlineCount = status.friends.filter((f) => f.online).length;
    const shown = useMemo(() => status.friends.filter((f) => filter === "all" || f.online), [status.friends, filter]);

    if (GUEST_ONLY || loading) return null;

    if (!user) {
        return (
            <section className="frSec" aria-label="Freunde">
                <div className="frHead">
                    <h2 className="frTitle">👥 Freunde</h2>
                </div>
                <p className="frLocked">Mit einem Konto siehst du hier deine Freunde, wer gerade online ist, und kannst sie direkt in ihre Lobby begleiten. Oben rechts anmelden oder registrieren.</p>
                <style>{STYLES}</style>
            </section>
        );
    }

    return (
        <section className="frSec" aria-label="Freunde">
            <div className="frHead">
                <h2 className="frTitle">
                    👥 Freunde <span className="frCount">{status.friends.length}</span>
                </h2>
                <div className="frTools">
                    <div className="frFilter" role="tablist" aria-label="Freunde filtern">
                        <button type="button" role="tab" aria-selected={filter === "all"} className={filter === "all" ? "on" : ""} onClick={() => pickFilter("all")}>
                            Alle
                        </button>
                        <button type="button" role="tab" aria-selected={filter === "online"} className={filter === "online" ? "on" : ""} onClick={() => pickFilter("online")}>
                            <span className="frDot" aria-hidden /> Online <b>{onlineCount}</b>
                        </button>
                    </div>
                    <button type="button" className="btn btnPrimary btnSmall" onClick={() => setAdding((v) => !v)} aria-expanded={adding}>
                        {adding ? "Schließen" : "＋ Freund hinzufügen"}
                    </button>
                </div>
            </div>

            {adding ? (
                <div className="frAdd">
                    <input
                        className="frInput"
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        onKeyDown={(e) => {
                            if (e.key === "Enter") void add();
                        }}
                        placeholder="Benutzername deines Freundes"
                        maxLength={40}
                        autoComplete="off"
                        autoFocus
                        aria-label="Benutzername deines Freundes"
                    />
                    <button type="button" className="btn btnPrimary" onClick={() => void add()} disabled={busy || !name.trim()}>
                        {busy ? "…" : "Anfrage senden"}
                    </button>
                    {fb ? <div className={`frFb ${fb.ok ? "ok" : "err"}`}>{fb.msg}</div> : null}
                </div>
            ) : null}

            {friendsApi.incoming.length ? (
                <div className="frReqs">
                    <div className="frReqsTitle">📥 {friendsApi.incoming.length === 1 ? "1 neue Freundschaftsanfrage" : `${friendsApi.incoming.length} neue Freundschaftsanfragen`}</div>
                    {friendsApi.incoming.map((r) => (
                        <div key={r.user_id} className="frReq">
                            <span className="frAvatar sm" style={{ background: colorFor(r.friend_username) }} aria-hidden>
                                {r.friend_username.slice(0, 1).toUpperCase()}
                            </span>
                            <b className="frReqName">{r.friend_username}</b>
                            <span className="frReqBtns">
                                <button
                                    type="button"
                                    className="btn btnReadyOn btnSmall"
                                    onClick={() => void friendsApi.acceptRequest(r.user_id).then(() => status.refresh())}
                                >
                                    ✅ Annehmen
                                </button>
                                <button type="button" className="btn btnReadyOff btnSmall" onClick={() => void friendsApi.removeFriend(r.user_id)}>
                                    ❌
                                </button>
                            </span>
                        </div>
                    ))}
                </div>
            ) : null}

            {status.error ? <p className="frLocked">Freunde gerade nicht erreichbar. Bitte später nochmal schauen.</p> : null}

            {!status.error && shown.length === 0 ? (
                <div className="frEmpty">
                    {status.loading ? "Lade…" : status.friends.length === 0 ? "Noch keine Freunde – füge deinen ersten mit „＋ Freund hinzufügen“ hinzu." : "Gerade ist keiner deiner Freunde online."}
                </div>
            ) : null}

            <div className="frGrid">
                {shown.map((f) => (
                    <FriendCard
                        key={f.userId}
                        f={f}
                        confirming={confirmRemove === f.userId}
                        onRemoveClick={() => {
                            if (confirmRemove === f.userId) {
                                setConfirmRemove(null);
                                void friendsApi.removeFriend(f.userId).then(() => status.refresh());
                            } else setConfirmRemove(f.userId);
                        }}
                    />
                ))}
            </div>
            <style>{STYLES}</style>
        </section>
    );
}

function FriendCard({ f, confirming, onRemoveClick }: { f: FriendStatus; confirming: boolean; onRemoveClick: () => void }) {
    const shownName = f.displayName || f.username;
    return (
        <article className={`frCard ${f.online ? "online" : ""}`}>
            <div className="frAvatar" style={{ background: f.avatarColor || colorFor(f.username) }} aria-hidden>
                {f.avatarEmoji || shownName.slice(0, 1).toUpperCase()}
                {f.online ? <span className="frAvatarDot" /> : null}
            </div>
            <div className="frName" title={shownName}>
                {shownName}
            </div>
            {f.displayName ? <div className="frUser">@{f.username}</div> : null}
            <div className={`frStatus ${f.online ? "on" : ""}`}>
                {f.lobbyCode ? `🎮 In Lobby ${f.lobbyCode}` : f.online ? "🟢 Online" : lastSeenText(f.lastSeen)}
            </div>
            <div className="frActions">
                {f.joinable && f.lobbyCode ? (
                    <Link href={`/join?code=${encodeURIComponent(f.lobbyCode)}`} className="btn btnPrimary btnSmall">
                        Beitreten
                    </Link>
                ) : null}
                <button type="button" className={`frRemove ${confirming ? "armed" : ""}`} onClick={onRemoveClick} title="Freundschaft beenden">
                    {confirming ? "Sicher?" : "Entfernen"}
                </button>
            </div>
        </article>
    );
}

const STYLES = `
.frSec{ margin-top:6px; padding:18px; border-radius:26px; background:rgba(20,8,4,.5); border:1px solid var(--glass-line); backdrop-filter: blur(10px); box-shadow:0 18px 50px rgba(0,0,0,.25); display:grid; gap:14px; }
.frHead{ display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; }
.frTitle{ margin:0; font-size:24px; display:flex; align-items:center; gap:10px; }
.frCount{ font-size:14px; font-weight:900; padding:2px 10px; border-radius:999px; background:rgba(255,255,255,.16); }
.frTools{ display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
.frFilter{ display:inline-flex; padding:4px; border-radius:999px; background:rgba(0,0,0,.3); border:1px solid rgba(255,255,255,.14); }
.frFilter button{ border:0; background:transparent; color:#fff; font:inherit; font-weight:800; font-size:14px; padding:7px 14px; border-radius:999px; cursor:pointer; display:inline-flex; align-items:center; gap:6px; }
.frFilter button.on{ background:#ffd23f; color:#2b0f04; }
.frDot{ width:9px; height:9px; border-radius:999px; background:#34d399; box-shadow:0 0 8px #34d399; }
.frAdd{ display:flex; gap:10px; flex-wrap:wrap; align-items:center; padding:12px; border-radius:18px; background:rgba(255,255,255,.07); border:1px dashed rgba(255,255,255,.3); }
.frInput{ flex:1 1 220px; min-width:0; padding:12px 14px; border-radius:14px; font:inherit; font-size:16px; color:#fff; background:rgba(0,0,0,.32); border:1px solid rgba(255,255,255,.25); }
.frInput::placeholder{ color:rgba(255,255,255,.5); }
.frFb{ flex-basis:100%; font-weight:700; font-size:13.5px; }
.frFb.ok{ color:#86efac; }
.frFb.err{ color:#fca5a5; }
.frReqs{ display:grid; gap:8px; padding:12px; border-radius:18px; background:rgba(255,210,63,.14); border:1px solid rgba(255,210,63,.5); }
.frReqsTitle{ font-weight:900; }
.frReq{ display:flex; align-items:center; gap:10px; }
.frReqName{ flex:1; font-size:17px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.frReqBtns{ display:flex; gap:6px; }
.frGrid{ display:grid; grid-template-columns:repeat(auto-fill, minmax(190px, 1fr)); gap:14px; }
.frCard{ position:relative; display:grid; justify-items:center; gap:4px; padding:20px 14px 14px; border-radius:24px; text-align:center;
  background:linear-gradient(180deg, rgba(255,255,255,.12), rgba(255,255,255,.05)); border:1px solid rgba(255,255,255,.2);
  box-shadow:0 12px 30px rgba(0,0,0,.25); transition: transform .15s ease, box-shadow .15s ease, border-color .15s ease; opacity:.9; }
.frCard:hover{ transform:translateY(-4px); box-shadow:0 18px 40px rgba(0,0,0,.35); }
.frCard.online{ opacity:1; border-color:rgba(52,211,153,.8); background:linear-gradient(180deg, rgba(52,211,153,.24), rgba(255,255,255,.06)); box-shadow:0 0 0 1px rgba(52,211,153,.3), 0 14px 36px rgba(16,185,129,.28); }
.frAvatar{ position:relative; width:76px; height:76px; border-radius:999px; display:grid; place-items:center; font-size:38px; font-weight:900; color:#fff; border:3px solid rgba(255,255,255,.5); box-shadow:0 8px 20px rgba(0,0,0,.3); }
.frAvatar.sm{ width:38px; height:38px; font-size:18px; border-width:2px; }
.frAvatarDot{ position:absolute; right:2px; bottom:2px; width:18px; height:18px; border-radius:999px; background:#34d399; border:3px solid #1f3d33; box-shadow:0 0 10px #34d399; }
.frName{ margin-top:6px; font-family:var(--font-display); font-size:20px; font-weight:800; max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.frUser{ font-size:12px; opacity:.65; margin-top:-3px; }
.frStatus{ font-size:13.5px; font-weight:700; opacity:.78; margin:2px 0 6px; }
.frStatus.on{ opacity:1; color:#a7f3d0; }
.frActions{ display:flex; gap:8px; align-items:center; justify-content:center; flex-wrap:wrap; min-height:34px; }
.frRemove{ border:0; background:transparent; color:rgba(255,255,255,.55); font:inherit; font-size:12px; cursor:pointer; text-decoration:underline; text-underline-offset:3px; padding:4px 6px; }
.frRemove:hover{ color:#fff; }
.frRemove.armed{ color:#fff; background:#ff5a46; border-radius:8px; text-decoration:none; font-weight:800; }
.frEmpty, .frLocked{ margin:0; padding:18px 8px; text-align:center; opacity:.85; font-size:15px; line-height:1.5; }
@media (max-width: 620px){ .frGrid{ grid-template-columns:repeat(2, 1fr); gap:10px; } .frAvatar{ width:64px; height:64px; font-size:32px; } .frName{ font-size:17px; } }
`;
