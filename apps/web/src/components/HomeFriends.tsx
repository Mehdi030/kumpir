"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { useAuth } from "@/components/AuthProvider";
import { useFriends } from "@/hooks/useFriends";
import { useFriendsStatus, type FriendStatus } from "@/hooks/useFriendsStatus";
import { FRIENDS_CHANGED } from "@/components/Notifications";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { errorText } from "@/lib/errorText";
import { dateLocale, trNow, useI18n } from "@/lib/i18n";
import { OpenLobbies } from "@/components/OpenLobbies";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";
const FIRST = 5; // so viele Freunde stehen immer da, der Rest per "Alle anzeigen"

const PALETTE = ["#f59e0b", "#ef4444", "#8b5cf6", "#06b6d4", "#22c55e", "#ec4899", "#3b82f6", "#f97316"];
function colorFor(name: string): string {
    let h = 0;
    for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return PALETTE[h % PALETTE.length]!;
}

function friendError(err: string): string {
    if (err.includes("user_not_found")) return trNow("⚠️ Diesen Benutzernamen gibt es nicht. Bitte genau so schreiben wie im Profil.");
    if (err.includes("already_friends")) return trNow("Ihr seid schon befreundet.");
    if (err.includes("already_requested")) return trNow("Die Anfrage läuft schon – warte, bis sie angenommen wird.");
    if (err.includes("cannot_befriend_self")) return trNow("Dich selbst kannst du nicht hinzufügen.");
    if (err.includes("already") || err.includes("duplicate")) return trNow("Ihr seid schon befreundet oder die Anfrage läuft.");
    if (err.includes("rate")) return trNow("Zu viele Anfragen – bitte später noch einmal.");
    return errorText(err);
}

// Zuletzt da (Migration 102: Online-Anzeige, sonst letztes Match, sonst letzte Anmeldung) – als Tag
function lastSeenText(iso: string | null): string {
    if (!iso) return trNow("Noch nicht gespielt");
    const loc = dateLocale();
    const d = new Date(iso);
    const mins = Math.max(1, Math.round((Date.now() - d.getTime()) / 60000));
    if (mins < 60) return trNow("Zuletzt vor {n} Min.", { n: mins });
    const startOfDay = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const days = Math.round((startOfDay(new Date()) - startOfDay(d)) / 86400000);
    const time = d.toLocaleTimeString(loc, { hour: "2-digit", minute: "2-digit" });
    if (days === 0) return trNow("Zuletzt heute, {time} Uhr", { time });
    if (days === 1) return trNow("Zuletzt gestern, {time} Uhr", { time });
    if (days < 7) return trNow("Zuletzt am {day}", { day: d.toLocaleDateString(loc, { weekday: "long" }) });
    return trNow("Zuletzt am {day}", { day: d.toLocaleDateString(loc, { day: "numeric", month: "numeric", year: days > 300 ? "numeric" : undefined }) });
}

type Filter = "all" | "online";

/**
 * Schmalere Bildschirme (Hauptmenü ohne Scrollen): statt der Liste unter der Karte ein Knopf in der Karte
 * ("Freunde · 2 online"), der die ganze Freunde-Liste als Fenster öffnet.
 */
export function HomeFriendsButton() {
    const { user, loading } = useAuth();
    const { tr } = useI18n();
    const status = useFriendsStatus(user?.id ?? null);
    const [open, setOpen] = useState(false);
    useEffect(() => {
        if (!open) return;
        const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [open]);
    if (GUEST_ONLY || loading || !user) return null;
    const online = status.friends.filter((f) => f.online).length;
    return (
        <>
            <button type="button" className="homeChip" onClick={() => setOpen(true)} title={tr("Freunde anzeigen")}>
                <span className="homeChipIcon" aria-hidden>
                    👥
                </span>
                <span className="homeChipText">
                    <b>{tr("Freunde")}</b>
                    <span>{status.loading ? "…" : online > 0 ? tr("{n} online", { n: online }) : tr("{n} insgesamt", { n: status.friends.length })}</span>
                </span>
                {online > 0 ? <span className="homeChipDot" aria-hidden /> : null}
                <span className="homeChipArrow" aria-hidden>
                    ›
                </span>
            </button>
            {open
                ? createPortal(
                      <div className="frModalBack" onClick={() => setOpen(false)} role="presentation">
                          <div className="frModal" role="dialog" aria-modal="true" aria-label={tr("Freunde")} onClick={(e) => e.stopPropagation()}>
                              <button type="button" className="frModalClose" onClick={() => setOpen(false)} aria-label={tr("Schließen")}>
                                  ✕
                              </button>
                              <HomeFriends inModal />
                          </div>
                          <style>{`
                            .frModalBack{ position: fixed; inset: 0; z-index: 4000; background: rgba(10,4,2,.62); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); display: grid; place-items: center; padding: 14px; }
                            .frModal{ position: relative; width: min(520px, 100%); max-height: calc(100dvh - 28px); overflow: auto; overscroll-behavior: contain; border-radius: 28px; }
                            .frModal .frSec{ margin: 0; background: linear-gradient(180deg, rgba(60,18,8,.97), rgba(32,10,6,.98)); }
                            .frModalClose{ position: absolute; top: 14px; right: 14px; z-index: 2; width: 38px; height: 38px; border-radius: 999px; border: 1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.08); color: #fff; font-size: 15px; cursor: pointer; }
                          `}</style>
                      </div>,
                      document.body
                  )
                : null}
        </>
    );
}

/**
 * Freunde im Hauptmenü: auf breiten Bildschirmen eine hohe Leiste rechts neben der Hauptkarte
 * (berührt sie nicht), sonst unter der Karte. Liste mit Avatar und Online-Status (Online zuerst),
 * die ersten 5 immer sichtbar, der Rest aufklappbar. Filter "Alle / Online", Freund hinzufügen,
 * Anfragen annehmen.
 */
export function HomeFriends({ inviteCode, withOpenLobbies = false, inModal = false }: { inviteCode?: string; withOpenLobbies?: boolean; inModal?: boolean } = {}) {
    const { user, loading } = useAuth();
    const { tr } = useI18n();
    // Hauptmenü (breit): offene Lobbys stehen unten in der Freunde-Leiste (Wunsch Mehdi 2026-10-12)
    const lobbies = withOpenLobbies ? (
        <div className="frLobbies">
            <OpenLobbies variant="side" />
        </div>
    ) : null;
    const friendsApi = useFriends(user?.id ?? null);
    const status = useFriendsStatus(user?.id ?? null);

    // Standard: nur wer online ist ("Alle" daneben); gemerkt wird die eigene Wahl
    const [filter, setFilter] = useState<Filter>(() => {
        try {
            return window.localStorage.getItem("kumpir_friends_filter2") === "all" ? "all" : "online";
        } catch {
            return "online";
        }
    });
    // In der Lobby: Freunde einladen (Migration 092)
    const [invited, setInvited] = useState<Record<string, "busy" | "ok" | string>>({});
    const invite = useCallback(
        async (friendId: string) => {
            if (!inviteCode) return;
            setInvited((m) => ({ ...m, [friendId]: "busy" }));
            const { error } = await getSupabaseClient().rpc("rpc_invite_friend", { p_lobby_code: inviteCode, p_friend_user_id: friendId });
            setInvited((m) => ({ ...m, [friendId]: error ? errorText(error.message) : "ok" }));
            window.setTimeout(() => setInvited((m) => {
                const n = { ...m };
                delete n[friendId];
                return n;
            }), error ? 4000 : 15000);
        },
        [inviteCode]
    );

    // Nach Annehmen/Ablehnen in einer Benachrichtigung sofort neu laden
    const refreshAll = useRef(() => {});
    useEffect(() => {
        refreshAll.current = () => {
            void friendsApi.refresh();
            void status.refresh();
        };
    }, [friendsApi, status]);
    useEffect(() => {
        const on = () => refreshAll.current();
        window.addEventListener(FRIENDS_CHANGED, on);
        return () => window.removeEventListener(FRIENDS_CHANGED, on);
    }, []);
    const [adding, setAdding] = useState(false);
    const [name, setName] = useState("");
    const [busy, setBusy] = useState(false);
    const [fb, setFb] = useState<{ ok: boolean; msg: string } | null>(null);
    const [confirmRemove, setConfirmRemove] = useState<string | null>(null);
    const [showAll, setShowAll] = useState(false);
    // Hauptmenü: bei weniger als 3 Freunden online klein eingeklappt (Wunsch Mehdi 2026-10-12); null = automatisch
    const [openPref, setOpenPref] = useState<boolean | null>(null);

    useEffect(() => {
        if (!confirmRemove) return;
        const t = window.setTimeout(() => setConfirmRemove(null), 3000);
        return () => window.clearTimeout(t);
    }, [confirmRemove]);

    const pickFilter = useCallback((f: Filter) => {
        setFilter(f);
        try {
            window.localStorage.setItem("kumpir_friends_filter2", f);
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
        // Fehler bleibt stehen, bis man weitertippt (vorher nach 4 s weg und leicht zu übersehen)
        if (err) setFb({ ok: false, msg: friendError(err) });
        else {
            setName("");
            setFb({ ok: true, msg: tr("✅ Anfrage an {name} geschickt.", { name: n }) });
            window.setTimeout(() => setFb(null), 4000);
        }
    }, [name, busy, friendsApi, tr]);

    const onlineCount = status.friends.filter((f) => f.online).length;
    const filtered = useMemo(() => status.friends.filter((f) => filter === "all" || f.online), [status.friends, filter]);
    // In der Lobby kleiner: erst 2 Freunde, Rest per "Alle anzeigen" (Wunsch Mehdi 2026-10-13)
    const firstN = inviteCode ? 2 : FIRST;
    const shown = showAll ? filtered : filtered.slice(0, firstN);
    const hiddenCount = filtered.length - shown.length;

    if (GUEST_ONLY || loading) return null;

    if (!user) {
        return (
            <section className="frSec frGuest" aria-label={tr("Freunde")}>
                <div className="frHead">
                    <h2 className="frTitle">👥 {tr("Freunde")}</h2>
                </div>
                <p className="frLocked">{tr("Mit einem Konto siehst du hier deine Freunde, wer gerade online ist, und kannst sie direkt in ihre Lobby begleiten. Oben rechts anmelden oder registrieren.")}</p>
                {lobbies}
                <style>{STYLES}</style>
            </section>
        );
    }

    const collapsible = !inviteCode && !inModal && !status.loading && !status.error;
    const collapsed = collapsible && !adding && friendsApi.incoming.length === 0 && (openPref === null ? onlineCount < 3 : !openPref);
    if (collapsed) {
        const onlineFriends = status.friends.filter((f) => f.online);
        return (
            <section className={`frSec frCollapsed ${withOpenLobbies ? "frWithLobbies" : ""}`} aria-label={tr("Freunde")}>
                <div className="frHead">
                    <h2 className="frTitle">
                        👥 {tr("Freunde")} <span className="frCount">{status.friends.length}</span>
                    </h2>
                    <button type="button" className="frToggle" onClick={() => setOpenPref(true)} aria-expanded={false}>
                        {tr("Aufklappen ▾")}
                    </button>
                </div>
                {onlineFriends.length === 0 ? (
                    <div className="frMiniNone">{tr("Gerade ist niemand online.")}</div>
                ) : (
                    <div className="frList">
                        {onlineFriends.map((f) => (
                            <FriendRow key={f.userId} f={f} confirming={false} inviteState={null} onInvite={() => {}} onRemoveClick={() => setOpenPref(true)} />
                        ))}
                    </div>
                )}
                {lobbies}
                <style>{STYLES}</style>
            </section>
        );
    }

    return (
        <section className={`frSec ${withOpenLobbies ? "frWithLobbies" : ""} ${inviteCode ? "frInLobby" : ""}`} aria-label={tr("Freunde")}>
            <div className="frHead">
                <h2 className="frTitle">
                    👥 {tr("Freunde")} <span className="frCount">{status.friends.length}</span>
                </h2>
                {collapsible ? (
                    <button type="button" className="frToggle" onClick={() => setOpenPref(false)} aria-expanded title={tr("Einklappen")}>
                        ▴
                    </button>
                ) : null}
                <button type="button" className="btn btnPrimary btnSmall" onClick={() => setAdding((v) => !v)} aria-expanded={adding} title={tr("Freund hinzufügen")}>
                    {adding ? "✕" : "＋"}
                    <span className="frAddLabel"> {adding ? tr("Schließen") : tr("Hinzufügen")}</span>
                </button>
            </div>
            <div className="frFilter" role="tablist" aria-label={tr("Freunde filtern")}>
                <button type="button" role="tab" aria-selected={filter === "online"} className={filter === "online" ? "on" : ""} onClick={() => pickFilter("online")}>
                    <span className="frDot" aria-hidden /> {tr("Online")} <b>{onlineCount}</b>
                </button>
                <button type="button" role="tab" aria-selected={filter === "all"} className={filter === "all" ? "on" : ""} onClick={() => pickFilter("all")}>
                    {tr("Alle")} <b>{status.friends.length}</b>
                </button>
            </div>

            {adding ? (
                <div className="frAdd">
                    <input
                        className="frInput"
                        value={name}
                        onChange={(e) => {
                            setName(e.target.value);
                            if (fb && !fb.ok) setFb(null);
                        }}
                        onKeyDown={(e) => {
                            if (e.key === "Enter") void add();
                        }}
                        placeholder={tr("Benutzername")}
                        maxLength={40}
                        autoComplete="off"
                        autoFocus
                        aria-label={tr("Benutzername deines Freundes")}
                    />
                    <button type="button" className="btn btnPrimary btnSmall" onClick={() => void add()} disabled={busy || !name.trim()}>
                        {busy ? "…" : tr("Senden")}
                    </button>
                    {fb ? <div className={`frFb ${fb.ok ? "ok" : "err"}`}>{fb.msg}</div> : null}
                </div>
            ) : null}

            {friendsApi.incoming.length ? (
                <div className="frReqs">
                    <div className="frReqsTitle">📥 {friendsApi.incoming.length === 1 ? tr("1 neue Anfrage") : tr("{n} neue Anfragen", { n: friendsApi.incoming.length })}</div>
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
                                    onClick={() => void friendsApi.acceptRequest(r.user_id).then(() => window.dispatchEvent(new Event(FRIENDS_CHANGED)))}
                                    title={tr("Annehmen")}
                                >
                                    {tr("✅ Annehmen")}
                                </button>
                                <button type="button" className="btn btnReadyOff btnSmall" onClick={() => void friendsApi.removeFriend(r.user_id).then(() => window.dispatchEvent(new Event(FRIENDS_CHANGED)))} title={tr("Ablehnen")}>
                                    ✕
                                </button>
                            </span>
                        </div>
                    ))}
                </div>
            ) : null}

            {status.error ? <p className="frLocked">{tr("Freunde gerade nicht erreichbar. Bitte später nochmal schauen.")}</p> : null}

            {!status.error && filtered.length === 0 ? (
                <div className="frEmpty">
                    {status.loading ? tr("Lade…") : status.friends.length === 0 ? tr("Noch keine Freunde – füge deinen ersten mit „＋ Hinzufügen“ hinzu.") : tr("Gerade ist keiner deiner Freunde online.")}
                </div>
            ) : null}

            <div className="frList">
                {shown.map((f) => (
                    <FriendRow
                        key={f.userId}
                        f={f}
                        confirming={confirmRemove === f.userId}
                        inviteState={inviteCode && f.online && f.lobbyCode !== inviteCode ? invited[f.userId] ?? "ready" : null}
                        inLobby={inviteCode}
                        onInvite={() => void invite(f.userId)}
                        onRemoveClick={() => {
                            if (confirmRemove === f.userId) {
                                setConfirmRemove(null);
                                void friendsApi.removeFriend(f.userId).then(() => status.refresh());
                            } else setConfirmRemove(f.userId);
                        }}
                    />
                ))}
            </div>
            {hiddenCount > 0 || (showAll && filtered.length > firstN) ? (
                <button type="button" className="frMore" onClick={() => setShowAll((v) => !v)} aria-expanded={showAll}>
                    {showAll ? tr("Weniger anzeigen ▴") : tr("Alle anzeigen (+{n}) ▾", { n: hiddenCount })}
                </button>
            ) : null}
            {lobbies}
            <style>{STYLES}</style>
        </section>
    );
}

function FriendRow({
    f,
    confirming,
    onRemoveClick,
    inviteState,
    onInvite,
    inLobby,
}: {
    f: FriendStatus;
    confirming: boolean;
    onRemoveClick: () => void;
    /** null = kein Einladen-Knopf (nicht in einer Lobby / Freund offline / schon hier) */
    inviteState: "ready" | "busy" | "ok" | string | null;
    onInvite: () => void;
    /** Code der Lobby, in der ich gerade bin (dort kein "Beitreten" anzeigen) */
    inLobby?: string;
}) {
    const { tr } = useI18n();
    const shownName = f.displayName || f.username;
    return (
        <article className={`frRow ${f.online ? "online" : ""}`}>
            <div className="frAvatar frAvatarFig" style={{ background: f.avatarColor || colorFor(f.username) }} aria-hidden>
                <PlayerAvatar seed={shownName} config={f.avatarConfig ?? null} size={46} />
                {f.online ? <span className="frAvatarDot" /> : null}
            </div>
            <div className="frInfo">
                <div className="frName" title={shownName}>
                    {shownName}
                </div>
                <div className={`frStatus ${f.online ? "on" : ""}`}>{f.lobbyCode ? tr("🎮 In Lobby {code}", { code: f.lobbyCode }) : f.online ? tr("Online") : lastSeenText(f.lastSeen)}</div>
            </div>
            <div className="frActions">
                {inviteState ? (
                    inviteState === "ok" ? (
                        <span className="frInvited">{tr("✓ Eingeladen")}</span>
                    ) : inviteState === "ready" || inviteState === "busy" ? (
                        <button type="button" className="btn btnPrimary btnSmall" disabled={inviteState === "busy"} onClick={onInvite} title={tr("In diese Lobby einladen")}>
                            {inviteState === "busy" ? "…" : tr("＋ Einladen")}
                        </button>
                    ) : (
                        <span className="frInviteErr" title={inviteState}>
                            ⚠️
                        </span>
                    )
                ) : f.joinable && f.lobbyCode && f.lobbyCode !== inLobby ? (
                    <Link href={`/join?code=${encodeURIComponent(f.lobbyCode)}`} className="btn btnPrimary btnSmall">
                        {tr("Beitreten")}
                    </Link>
                ) : null}
                <button
                    type="button"
                    className={`frRemove ${confirming ? "armed" : ""}`}
                    onClick={onRemoveClick}
                    title={tr("Freundschaft beenden")}
                    aria-label={confirming ? tr("Wirklich entfernen?") : tr("{name} entfernen", { name: shownName })}
                >
                    {confirming ? tr("Sicher?") : "✕"}
                </button>
            </div>
        </article>
    );
}

const STYLES = `
.frSec.frInLobby{ padding: 12px 14px; gap: 8px; border-radius: 22px; align-self: start; }
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
  .frSec.frGuest, .frSec.frCollapsed{ min-height: 0; }
}
.frLobbies{ margin-top:auto; padding-top:4px; }
.frToggle{ margin-left:auto; border:1px solid rgba(255,255,255,.22); background:rgba(255,255,255,.08); color:#fff; font:inherit; font-weight:800; font-size:13px; padding:6px 12px; border-radius:999px; cursor:pointer; white-space:nowrap; }
.frToggle:hover{ background:rgba(255,255,255,.16); }
.frCollapsed{ gap:10px; padding:14px 16px; }
.frMiniNone{ font-size:13.5px; font-weight:700; opacity:.75; }
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
.frFb.err{ color:#fff; background: rgba(220,38,38,.35); border: 1px solid rgba(252,165,165,.75); padding: 8px 10px; border-radius: 12px; font-size: 14px; }
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
.frAvatarFig{ overflow:visible; }
.frAvatarFig img{ width:46px; height:46px; border-radius:50%; }
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
.frInvited{ font-size:12.5px; font-weight:900; color:#a7f3d0; white-space:nowrap; }
.frInviteErr{ font-size:16px; cursor:help; }
.frMore{ align-self:center; border:1px solid rgba(255,255,255,.22); background:rgba(255,255,255,.08); color:#fff; font:inherit; font-weight:800; font-size:13.5px; padding:8px 16px; border-radius:999px; cursor:pointer; }
.frMore:hover{ background:rgba(255,255,255,.16); }
@container (max-width: 300px){ .frAddLabel{ display:none; } .frTitle{ font-size:19px; } }
.frEmpty, .frLocked{ margin:0; padding:16px 6px; text-align:center; opacity:.85; font-size:14.5px; line-height:1.5; }
`;
