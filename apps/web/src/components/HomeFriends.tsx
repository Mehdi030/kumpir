"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { useFriends } from "@/hooks/useFriends";
import { useFriendsStatus, type FriendStatus } from "@/hooks/useFriendsStatus";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";
const FIRST = 5; // so viele Freunde stehen immer da, der Rest per "Alle anzeigen"

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
 * Freunde im Hauptmenü: auf breiten Bildschirmen eine hohe Leiste rechts neben der Hauptkarte
 * (berührt sie nicht), sonst unter der Karte. Liste mit Avatar und Online-Status (Online zuerst),
 * die ersten 5 immer sichtbar, der Rest aufklappbar. Filter "Alle / Online", Freund hinzufügen,
 * Anfragen annehmen.
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
    const [showAll, setShowAll] = useState(false);

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
    const filtered = useMemo(() => status.friends.filter((f) => filter === "all" || f.online), [status.friends, filter]);
    const shown = showAll ? filtered : filtered.slice(0, FIRST);
    const hiddenCount = filtered.length - shown.length;

    if (GUEST_ONLY || loading) return null;

    if (!user) {
        return (
            <section className="frSec frGuest" aria-label="Freunde">
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
                <button type="button" className="btn btnPrimary btnSmall" onClick={() => setAdding((v) => !v)} aria-expanded={adding} title="Freund hinzufügen">
                    {adding ? "✕" : "＋"}
                    <span className="frAddLabel">{adding ? " Schließen" : " Hinzufügen"}</span>
                </button>
            </div>
            <div className="frFilter" role="tablist" aria-label="Freunde filtern">
                <button type="button" role="tab" aria-selected={filter === "all"} className={filter === "all" ? "on" : ""} onClick={() => pickFilter("all")}>
                    Alle
                </button>
                <button type="button" role="tab" aria-selected={filter === "online"} className={filter === "online" ? "on" : ""} onClick={() => pickFilter("online")}>
                    <span className="frDot" aria-hidden /> Online <b>{onlineCount}</b>
                </button>
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
                        placeholder="Benutzername"
                        maxLength={40}
                        autoComplete="off"
                        autoFocus
                        aria-label="Benutzername deines Freundes"
                    />
                    <button type="button" className="btn btnPrimary btnSmall" onClick={() => void add()} disabled={busy || !name.trim()}>
                        {busy ? "…" : "Senden"}
                    </button>
                    {fb ? <div className={`frFb ${fb.ok ? "ok" : "err"}`}>{fb.msg}</div> : null}
                </div>
            ) : null}

            {friendsApi.incoming.length ? (
                <div className="frReqs">
                    <div className="frReqsTitle">📥 {friendsApi.incoming.length === 1 ? "1 neue Anfrage" : `${friendsApi.incoming.length} neue Anfragen`}</div>
                    {friendsApi.incoming.map((r) => (
                        <div key={r.user_id} className="frReq">
                            <span className="frAvatar sm" style={{ background: colorFor(r.friend_username) }} aria-hidden>
                                {r.friend_username.slice(0, 1).toUpperCase()}
                            </span>
                            <b className="frReqName">{r.friend_username}</b>
                            <span className="frReqBtns">
                                <button type="button" className="btn btnReadyOn btnSmall" onClick={() => void friendsApi.acceptRequest(r.user_id).then(() => status.refresh())} title="Annehmen">
                                    ✅
                                </button>
                                <button type="button" className="btn btnReadyOff btnSmall" onClick={() => void friendsApi.removeFriend(r.user_id)} title="Ablehnen">
                                    ❌
                                </button>
                            </span>
                        </div>
                    ))}
                </div>
            ) : null}

            {status.error ? <p className="frLocked">Freunde gerade nicht erreichbar. Bitte später nochmal schauen.</p> : null}

            {!status.error && filtered.length === 0 ? (
                <div className="frEmpty">
                    {status.loading ? "Lade…" : status.friends.length === 0 ? "Noch keine Freunde – füge deinen ersten mit „＋ Hinzufügen“ hinzu." : "Gerade ist keiner deiner Freunde online."}
                </div>
            ) : null}

            <div className="frList">
                {shown.map((f) => (
                    <FriendRow
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
            {hiddenCount > 0 || (showAll && filtered.length > FIRST) ? (
                <button type="button" className="frMore" onClick={() => setShowAll((v) => !v)} aria-expanded={showAll}>
                    {showAll ? "Weniger anzeigen ▴" : `Alle anzeigen (+${hiddenCount}) ▾`}
                </button>
            ) : null}
            <style>{STYLES}</style>
        </section>
    );
}

function FriendRow({ f, confirming, onRemoveClick }: { f: FriendStatus; confirming: boolean; onRemoveClick: () => void }) {
    const shownName = f.displayName || f.username;
    return (
        <article className={`frRow ${f.online ? "online" : ""}`}>
            <div className="frAvatar" style={{ background: f.avatarColor || colorFor(f.username) }} aria-hidden>
                {f.avatarEmoji || shownName.slice(0, 1).toUpperCase()}
                {f.online ? <span className="frAvatarDot" /> : null}
            </div>
            <div className="frInfo">
                <div className="frName" title={shownName}>
                    {shownName}
                </div>
                <div className={`frStatus ${f.online ? "on" : ""}`}>{f.lobbyCode ? `🎮 In Lobby ${f.lobbyCode}` : f.online ? "Online" : lastSeenText(f.lastSeen)}</div>
            </div>
            <div className="frActions">
                {f.joinable && f.lobbyCode ? (
                    <Link href={`/join?code=${encodeURIComponent(f.lobbyCode)}`} className="btn btnPrimary btnSmall">
                        Beitreten
                    </Link>
                ) : null}
                <button
                    type="button"
                    className={`frRemove ${confirming ? "armed" : ""}`}
                    onClick={onRemoveClick}
                    title="Freundschaft beenden"
                    aria-label={confirming ? "Wirklich entfernen?" : `${shownName} entfernen`}
                >
                    {confirming ? "Sicher?" : "✕"}
                </button>
            </div>
        </article>
    );
}

const STYLES = `
.frSec{ container-type: inline-size; margin-top:6px; padding:18px; border-radius:26px; background:rgba(20,8,4,.5); border:1px solid var(--glass-line); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); box-shadow:0 18px 50px rgba(0,0,0,.25); display:flex; flex-direction:column; gap:12px; }
/* Ab 1300 px: hohe Leiste rechts neben der Hauptkarte (die Hauptkarte ist dort schmaler, --homeW in globals.css) */
@media (min-width: 1300px){
  .frSec{
    position: fixed; z-index: 5; margin: 0;
    right: 24px; top: 96px;
    width: clamp(240px, calc((100vw - var(--homeW, 860px)) / 2 - 56px), 400px);
    min-height: min(640px, calc(100vh - 130px)); max-height: calc(100vh - 124px);
    overflow: auto; overscroll-behavior: contain;
    animation: kmRise .7s var(--ease-out) .25s backwards;
  }
  .frSec.frGuest{ min-height: 0; }
}
.frHead{ display:flex; align-items:center; justify-content:space-between; gap:10px; }
.frTitle{ margin:0; font-size:22px; display:flex; align-items:center; gap:10px; }
.frCount{ font-size:13px; font-weight:900; padding:2px 10px; border-radius:999px; background:rgba(255,255,255,.16); }
.frFilter{ align-self:flex-start; display:inline-flex; padding:4px; border-radius:999px; background:rgba(0,0,0,.3); border:1px solid rgba(255,255,255,.14); }
.frFilter button{ border:0; background:transparent; color:#fff; font:inherit; font-weight:800; font-size:13.5px; padding:6px 13px; border-radius:999px; cursor:pointer; display:inline-flex; align-items:center; gap:6px; }
.frFilter button.on{ background:#ffd23f; color:#2b0f04; }
.frDot{ width:9px; height:9px; border-radius:999px; background:#34d399; box-shadow:0 0 8px #34d399; }
.frAdd{ display:flex; gap:8px; flex-wrap:wrap; align-items:center; padding:10px; border-radius:16px; background:rgba(255,255,255,.07); border:1px dashed rgba(255,255,255,.3); }
.frInput{ flex:1 1 140px; min-width:0; padding:10px 12px; border-radius:12px; font:inherit; font-size:15px; color:#fff; background:rgba(0,0,0,.32); border:1px solid rgba(255,255,255,.25); }
.frInput::placeholder{ color:rgba(255,255,255,.5); }
.frFb{ flex-basis:100%; font-weight:700; font-size:13px; }
.frFb.ok{ color:#86efac; }
.frFb.err{ color:#fca5a5; }
.frReqs{ display:grid; gap:8px; padding:10px; border-radius:16px; background:rgba(255,210,63,.14); border:1px solid rgba(255,210,63,.5); }
.frReqsTitle{ font-weight:900; font-size:14px; }
.frReq{ display:flex; align-items:center; gap:8px; }
.frReqName{ flex:1; font-size:15px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.frReqBtns{ display:flex; gap:6px; }
/* Liste: eine Zeile pro Freund – Platz für mindestens 5 */
.frList{ display:grid; gap:8px; align-content:start; }
.frRow{ display:grid; grid-template-columns:auto 1fr auto; align-items:center; gap:12px; padding:10px 12px; min-height:68px; border-radius:18px;
  background:linear-gradient(180deg, rgba(255,255,255,.10), rgba(255,255,255,.04)); border:1px solid rgba(255,255,255,.16);
  transition: transform .15s ease, border-color .15s ease; animation: kmRise .45s var(--ease-out) backwards; }
.frRow:nth-child(2){ animation-delay:.05s } .frRow:nth-child(3){ animation-delay:.1s } .frRow:nth-child(4){ animation-delay:.15s } .frRow:nth-child(5){ animation-delay:.2s }
.frRow:hover{ transform: translateX(-3px); border-color: rgba(255,255,255,.3); }
.frRow.online{ border-color:rgba(52,211,153,.7); background:linear-gradient(180deg, rgba(52,211,153,.2), rgba(255,255,255,.05)); }
.frAvatar{ position:relative; width:46px; height:46px; border-radius:999px; display:grid; place-items:center; font-size:23px; font-weight:900; color:#fff; border:2px solid rgba(255,255,255,.5); box-shadow:0 6px 14px rgba(0,0,0,.3); }
.frAvatar.sm{ width:34px; height:34px; font-size:16px; }
.frAvatarDot{ position:absolute; right:-1px; bottom:-1px; width:14px; height:14px; border-radius:999px; background:#34d399; border:2.5px solid #1f3d33; box-shadow:0 0 8px #34d399; }
.frInfo{ min-width:0; display:grid; gap:2px; }
.frName{ font-family:var(--font-display); font-size:17px; font-weight:800; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.frStatus{ font-size:12.5px; font-weight:700; opacity:.72; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.frStatus.on{ opacity:1; color:#a7f3d0; }
.frActions{ display:flex; gap:6px; align-items:center; }
.frRemove{ border:0; background:transparent; color:rgba(255,255,255,.45); font:inherit; font-size:13px; cursor:pointer; padding:6px 8px; border-radius:8px; }
.frRemove:hover{ color:#fff; background:rgba(255,255,255,.1); }
.frRemove.armed{ color:#fff; background:#ff5a46; font-weight:800; }
.frMore{ align-self:center; border:1px solid rgba(255,255,255,.22); background:rgba(255,255,255,.08); color:#fff; font:inherit; font-weight:800; font-size:13.5px; padding:8px 16px; border-radius:999px; cursor:pointer; }
.frMore:hover{ background:rgba(255,255,255,.16); }
@container (max-width: 300px){ .frAddLabel{ display:none; } .frTitle{ font-size:19px; } }
.frEmpty, .frLocked{ margin:0; padding:16px 6px; text-align:center; opacity:.85; font-size:14.5px; line-height:1.5; }
`;
