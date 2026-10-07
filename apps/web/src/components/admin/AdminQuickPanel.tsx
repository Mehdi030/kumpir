"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useProfile } from "@/hooks/useProfile";
import {
    adminErrorText,
    supabaseAdminApi,
    type AdminLobby,
    type AdminOverview,
    type AdminUserRow,
    type OnlinePlayer,
} from "@/lib/adminApi";
import { emailLabel } from "@/lib/accountSettings";

/**
 * Admin-Schnellmenü: kleines Pop-up außerhalb der normalen Seiten – für Admins und Supporter.
 * Öffnen/Schließen mit Alt + A (Esc schließt). Standard-Ansicht: wer ist gerade online.
 * Alle Aktionen laufen über dieselben geprüften Datenbank-Funktionen wie das Admin-Panel.
 */

type View = "online" | "accounts" | "lobbies";
const VIEW_KEY = "kumpir_quick_view";
const BTN_KEY = "kumpir_quick_btn";
const REFRESH_MS = 8000;

const PHASE_LABEL: Record<string, string> = {
    waiting: "Lobby",
    lobby: "Lobby",
    topic_vote: "Abstimmung",
    countdown: "Countdown",
    running: "läuft",
    set_summary: "Zwischenstand",
    finished: "beendet",
    rematch_wait: "Revanche",
};

function readLS(key: string): string | null {
    try {
        return window.localStorage.getItem(key);
    } catch {
        return null;
    }
}
function writeLS(key: string, value: string) {
    try {
        window.localStorage.setItem(key, value);
    } catch {
        /* privater Modus */
    }
}

function Confirm({ label, danger, disabled, onYes, title }: { label: string; danger?: boolean; disabled?: boolean; onYes: () => void; title?: string }) {
    const [armed, setArmed] = useState(false);
    useEffect(() => {
        if (!armed) return;
        const t = window.setTimeout(() => setArmed(false), 3000);
        return () => window.clearTimeout(t);
    }, [armed]);
    return (
        <button
            type="button"
            className={`aqBtn ${danger ? "danger" : ""} ${armed ? "armed" : ""}`}
            disabled={disabled}
            title={title}
            onClick={() => {
                if (armed) {
                    setArmed(false);
                    onYes();
                } else setArmed(true);
            }}
        >
            {armed ? "Sicher?" : label}
        </button>
    );
}

export function AdminQuickPanel() {
    const { user, profile } = useProfile();
    const api = useMemo(() => supabaseAdminApi(), []);
    const isStaff = !!user && !!profile?.isStaff;
    const isAdmin = profile?.role === "admin";

    const [open, setOpen] = useState(false);
    // Beides aus dem Browser-Speicher; gerendert wird erst, wenn das Konto geladen ist (also nie vor der Hydration)
    const [showBtn, setShowBtn] = useState(() => (typeof window === "undefined" ? true : readLS(BTN_KEY) !== "hidden"));
    const [view, setViewState] = useState<View>(() => {
        const v = typeof window === "undefined" ? null : readLS(VIEW_KEY);
        return v === "accounts" || v === "lobbies" ? v : "online";
    });
    const [search, setSearch] = useState("");
    const [overview, setOverview] = useState<AdminOverview | null>(null);
    const [online, setOnline] = useState<OnlinePlayer[] | null>(null);
    const [accounts, setAccounts] = useState<AdminUserRow[] | null>(null);
    const [lobbies, setLobbies] = useState<AdminLobby[] | null>(null);
    const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
    const [busy, setBusy] = useState(false);
    const msgTimer = useRef<number | null>(null);

    const setView = useCallback((v: View) => {
        setViewState(v);
        writeLS(VIEW_KEY, v);
    }, []);

    const flash = useCallback((ok: boolean, text: string) => {
        setMsg({ ok, text });
        if (msgTimer.current) window.clearTimeout(msgTimer.current);
        msgTimer.current = window.setTimeout(() => setMsg(null), 3500);
    }, []);

    // Tastenkürzel: Alt + A öffnet/schließt, Esc schließt
    useEffect(() => {
        if (!isStaff) return;
        const onKey = (e: KeyboardEvent) => {
            if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyA") {
                e.preventDefault();
                setOpen((o) => !o);
            } else if (e.key === "Escape") {
                setOpen((o) => (o ? false : o));
            }
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [isStaff]);

    const load = useCallback(async () => {
        const ov = await api.overview();
        if (ov.data) setOverview(ov.data);
        if (view === "online") {
            const r = await api.onlinePlayers();
            if (r.error) flash(false, adminErrorText(r.error));
            else setOnline(r.data ?? []);
        } else if (view === "accounts") {
            const r = await api.listUsers(search.trim(), "all");
            if (r.error) flash(false, adminErrorText(r.error));
            else setAccounts(r.data ?? []);
        } else {
            const r = await api.listLobbies();
            if (r.error) flash(false, adminErrorText(r.error));
            else setLobbies(r.data ?? []);
        }
    }, [api, view, search, flash]);

    // Laden beim Öffnen, bei Ansichts-/Suchwechsel und regelmäßig, solange offen
    useEffect(() => {
        if (!open || !isStaff) return;
        const first = window.setTimeout(() => void load(), search ? 250 : 0);
        const loop = window.setInterval(() => void load(), REFRESH_MS);
        return () => {
            window.clearTimeout(first);
            window.clearInterval(loop);
        };
    }, [open, isStaff, load, search]);

    const act = useCallback(
        async (fn: () => Promise<{ error?: string }>, okText: string) => {
            if (busy) return;
            setBusy(true);
            const r = await fn();
            setBusy(false);
            if (r.error) flash(false, adminErrorText(r.error));
            else {
                flash(true, okText);
                void load();
            }
        },
        [busy, flash, load]
    );

    if (!isStaff) return null;

    const c = overview?.counts;
    const onlineFiltered = (online ?? []).filter((p) => {
        const q = search.trim().toLowerCase();
        return !q || p.name.toLowerCase().includes(q) || (p.username ?? "").toLowerCase().includes(q) || p.lobbyCode.toLowerCase().includes(q);
    });

    return (
        <>
            {!open && showBtn ? (
                <button type="button" className="aqFab" onClick={() => setOpen(true)} title="Admin-Schnellmenü (Alt + A)" aria-label="Admin-Schnellmenü öffnen">
                    🛡️
                </button>
            ) : null}

            {open ? (
                <div className="aqPanel" role="dialog" aria-label="Admin-Schnellmenü">
                    <div className="aqHead">
                        <div>
                            <b>🛡️ Schnellmenü</b>
                            <span className="aqKbd">Alt + A</span>
                        </div>
                        <button type="button" className="aqClose" onClick={() => setOpen(false)} aria-label="Schließen">
                            ✕
                        </button>
                    </div>

                    <div className="aqChips">
                        <button type="button" className={`aqChip ${view === "online" ? "on" : ""}`} onClick={() => setView("online")}>
                            🟢 Online <b>{online ? online.length : "–"}</b>
                        </button>
                        <button type="button" className={`aqChip ${view === "lobbies" ? "on" : ""}`} onClick={() => setView("lobbies")}>
                            🎮 Lobbys <b>{c ? c.activeLobbies : "–"}</b>
                        </button>
                        <button type="button" className={`aqChip ${view === "accounts" ? "on" : ""}`} onClick={() => setView("accounts")}>
                            👥 Konten <b>{c ? c.users : "–"}</b>
                        </button>
                    </div>

                    {c && (c.deletionRequests > 0 || c.suspended > 0) ? (
                        <div className="aqAlerts">
                            {c.deletionRequests > 0 ? (
                                <Link href="/admin?tab=deletion" className="aqAlert warn" onClick={() => setOpen(false)}>
                                    🗑️ {c.deletionRequests} Löschantrag{c.deletionRequests === 1 ? "" : "räge"}
                                </Link>
                            ) : null}
                            {c.suspended > 0 ? (
                                <Link href="/admin?tab=users" className="aqAlert" onClick={() => setOpen(false)}>
                                    ⛔ {c.suspended} gesperrt
                                </Link>
                            ) : null}
                        </div>
                    ) : null}

                    {view !== "lobbies" ? (
                        <input
                            className="aqSearch"
                            value={search}
                            onChange={(e) => setSearch(e.target.value)}
                            placeholder={view === "online" ? "Online-Spieler suchen …" : "Konto suchen (Name, E-Mail) …"}
                            aria-label="Suchen"
                        />
                    ) : null}

                    {msg ? <div className={`aqMsg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div> : null}

                    <div className="aqList">
                        {view === "online" ? (
                            online === null ? (
                                <div className="aqEmpty">Lade …</div>
                            ) : onlineFiltered.length === 0 ? (
                                <div className="aqEmpty">{search ? "Kein Treffer." : "Gerade ist niemand in einer Lobby."}</div>
                            ) : (
                                onlineFiltered.map((p) => {
                                    const isStaffTarget = p.role === "admin" || p.role === "supporter";
                                    const canBan = !!p.userId && p.userId !== user?.id && p.role !== "admin" && !(p.role === "supporter" && !isAdmin) && p.accountStatus !== "suspended";
                                    const canKick = !(p.role === "admin" && !isAdmin);
                                    return (
                                        <div key={p.playerId} className="aqRow">
                                            <div className="aqInfo">
                                                <div className="aqName">
                                                    {p.name}
                                                    {p.isHost ? <span title="Host"> 👑</span> : null}
                                                    {isStaffTarget ? <span className="aqTag">{p.role === "admin" ? "Admin" : "Supporter"}</span> : null}
                                                </div>
                                                <div className="aqSub">
                                                    {p.username ? `@${p.username}` : "Gast"} · Lobby {p.lobbyCode} · {PHASE_LABEL[p.phase] ?? p.phase}
                                                </div>
                                            </div>
                                            <div className="aqActions">
                                                <Confirm label="👢" title="Aus der Lobby werfen" disabled={busy || !canKick} onYes={() => void act(() => api.kickPlayer(p.lobbyId, p.playerId), `${p.name} gekickt.`)} />
                                                {canBan ? (
                                                    <Confirm
                                                        label="⛔"
                                                        danger
                                                        title="Konto sperren (meldet überall ab) und rauswerfen"
                                                        disabled={busy}
                                                        onYes={() =>
                                                            void act(async () => {
                                                                const s = await api.setStatus(p.userId!, "suspended", "Schnellmenü");
                                                                if (s.error) return s;
                                                                const k = await api.kickPlayer(p.lobbyId, p.playerId);
                                                                return k.error && !k.error.includes("player_not_found") ? k : {};
                                                            }, `${p.username ?? p.name} gesperrt und rausgeworfen.`)
                                                        }
                                                    />
                                                ) : null}
                                                {p.username ? (
                                                    <Link href={`/admin?tab=users&q=${encodeURIComponent(p.username)}`} className="aqBtn" title="Im Admin-Panel öffnen" onClick={() => setOpen(false)}>
                                                        ↗
                                                    </Link>
                                                ) : null}
                                            </div>
                                        </div>
                                    );
                                })
                            )
                        ) : null}

                        {view === "accounts" ? (
                            accounts === null ? (
                                <div className="aqEmpty">Lade …</div>
                            ) : accounts.length === 0 ? (
                                <div className="aqEmpty">Kein Treffer.</div>
                            ) : (
                                accounts.map((u) => {
                                    const staffTarget = u.role === "admin" || u.role === "supporter";
                                    const canAct = u.id !== user?.id && u.role !== "admin" && !(u.role === "supporter" && !isAdmin);
                                    return (
                                        <div key={u.id} className="aqRow">
                                            <div className="aqInfo">
                                                <div className="aqName">
                                                    {u.username ?? "?"}
                                                    {staffTarget ? <span className="aqTag">{u.role === "admin" ? "Admin" : "Supporter"}</span> : null}
                                                    {u.status === "suspended" ? <span className="aqTag bad">gesperrt</span> : null}
                                                    {u.status === "deletion_requested" ? <span className="aqTag bad">Löschantrag</span> : null}
                                                </div>
                                                <div className="aqSub">{emailLabel(u.email)}</div>
                                            </div>
                                            <div className="aqActions">
                                                {canAct && u.status === "suspended" ? (
                                                    <Confirm label="✅" title="Entsperren" disabled={busy} onYes={() => void act(() => api.setStatus(u.id, "active"), `${u.username} entsperrt.`)} />
                                                ) : null}
                                                {canAct && u.status === "active" ? (
                                                    <Confirm label="⛔" danger title="Sperren (meldet überall ab)" disabled={busy} onYes={() => void act(() => api.setStatus(u.id, "suspended", "Schnellmenü"), `${u.username} gesperrt.`)} />
                                                ) : null}
                                                <Link href={`/admin?tab=users&q=${encodeURIComponent(u.username ?? "")}`} className="aqBtn" title="Im Admin-Panel öffnen" onClick={() => setOpen(false)}>
                                                    ↗
                                                </Link>
                                            </div>
                                        </div>
                                    );
                                })
                            )
                        ) : null}

                        {view === "lobbies" ? (
                            lobbies === null ? (
                                <div className="aqEmpty">Lade …</div>
                            ) : lobbies.length === 0 ? (
                                <div className="aqEmpty">Keine Lobbys offen.</div>
                            ) : (
                                lobbies.map((l) => (
                                    <div key={l.id} className="aqRow">
                                        <div className="aqInfo">
                                            <div className="aqName">
                                                {l.code} <span className="aqSub inline">· {PHASE_LABEL[l.phase] ?? l.phase}</span>
                                            </div>
                                            <div className="aqSub">
                                                Host {l.host ?? "?"} · {l.humans} Mensch{l.humans === 1 ? "" : "en"}
                                                {l.bots ? ` + ${l.bots} Bot${l.bots === 1 ? "" : "s"}` : ""}
                                            </div>
                                        </div>
                                        <div className="aqActions">
                                            <Confirm label="🚪" danger title="Lobby sofort für alle schließen" disabled={busy} onYes={() => void act(() => api.closeLobby(l.id), `Lobby ${l.code} geschlossen.`)} />
                                        </div>
                                    </div>
                                ))
                            )
                        ) : null}
                    </div>

                    <div className="aqFoot">
                        <Link href="/admin" onClick={() => setOpen(false)}>
                            Admin-Panel
                        </Link>
                        <Link href="/admin?tab=audit" onClick={() => setOpen(false)}>
                            Protokoll
                        </Link>
                        {isAdmin ? (
                            <Link href="/admin/stats" onClick={() => setOpen(false)}>
                                Statistik
                            </Link>
                        ) : null}
                        <button
                            type="button"
                            className="aqLinkBtn"
                            onClick={() => {
                                setShowBtn((v) => {
                                    writeLS(BTN_KEY, v ? "hidden" : "shown");
                                    return !v;
                                });
                            }}
                            title="Der Knopf unten links ist nur eine Abkürzung – Alt + A funktioniert immer"
                        >
                            {showBtn ? "Knopf ausblenden" : "Knopf einblenden"}
                        </button>
                    </div>
                </div>
            ) : null}

            <style>{STYLES}</style>
        </>
    );
}

const STYLES = `
.aqFab{ animation: aqFab .4s cubic-bezier(.34,1.56,.64,1) .3s both; transition: transform .25s cubic-bezier(.34,1.56,.64,1), opacity .2s ease; position:fixed; left:12px; bottom:12px; z-index:3000; width:38px; height:38px; border-radius:999px; border:1px solid rgba(255,255,255,.3); background:rgba(20,8,4,.72); color:#fff; font-size:18px; cursor:pointer; opacity:.55; backdrop-filter: blur(6px); }
.aqFab:hover{ opacity:1; transform: scale(1.12) rotate(-6deg); }
@keyframes aqIn{ from{ opacity:0; transform: translateX(28px) scale(.97); } to{ opacity:1; transform:none; } }
@keyframes aqFab{ from{ opacity:0; transform: scale(.4); } to{ opacity:.55; transform:none; } }
.aqPanel{ animation: aqIn .34s cubic-bezier(.16,1,.3,1) both; position:fixed; right:12px; top:12px; z-index:3000; width:min(390px, calc(100vw - 24px)); max-height:calc(100vh - 24px); display:flex; flex-direction:column; gap:8px; padding:12px; border-radius:20px; color:#fff;
  background:rgba(24,10,6,.94); border:1px solid rgba(255,255,255,.22); box-shadow:0 24px 70px rgba(0,0,0,.5); backdrop-filter: blur(12px); font-size:13px; }
.aqHead{ display:flex; justify-content:space-between; align-items:center; gap:8px; }
.aqKbd{ margin-left:8px; font-size:10.5px; font-weight:800; padding:2px 7px; border-radius:6px; background:rgba(255,255,255,.14); }
.aqClose{ width:28px; height:28px; border-radius:999px; border:0; background:rgba(255,255,255,.12); color:#fff; cursor:pointer; font-weight:900; }
.aqChips{ display:flex; gap:6px; flex-wrap:wrap; }
.aqChip{ border:1px solid rgba(255,255,255,.22); background:rgba(255,255,255,.06); color:#fff; border-radius:999px; padding:5px 10px; font:inherit; font-weight:700; font-size:12px; cursor:pointer; }
.aqChip.on{ background:#ffd23f; color:#2b0f04; border-color:#ffd23f; }
.aqChip b{ margin-left:3px; }
.aqAlerts{ display:flex; gap:6px; flex-wrap:wrap; }
.aqAlert{ font-size:12px; font-weight:800; padding:4px 10px; border-radius:999px; background:rgba(255,255,255,.1); color:#fff; text-decoration:none; }
.aqAlert.warn{ background:rgba(255,120,90,.28); }
.aqSearch{ width:100%; padding:8px 10px; border-radius:12px; font:inherit; font-size:13px; color:#fff; background:rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.22); }
.aqSearch::placeholder{ color:rgba(255,255,255,.5); }
.aqMsg{ padding:6px 10px; border-radius:10px; font-weight:700; font-size:12px; }
.aqMsg.ok{ background:rgba(80,200,120,.25); }
.aqMsg.err{ background:rgba(255,90,70,.3); }
.aqList{ overflow:auto; display:grid; gap:6px; min-height:60px; max-height:50vh; padding-right:2px; }
.aqEmpty{ opacity:.7; padding:14px 6px; text-align:center; }
.aqRow{ display:flex; justify-content:space-between; align-items:center; gap:8px; padding:8px 10px; border-radius:12px; background:rgba(255,255,255,.07); }
.aqInfo{ min-width:0; }
.aqName{ font-weight:800; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.aqSub{ font-size:11.5px; opacity:.72; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.aqSub.inline{ display:inline; }
.aqTag{ margin-left:6px; font-size:10px; font-weight:900; padding:1px 6px; border-radius:999px; background:rgba(255,255,255,.18); }
.aqTag.bad{ background:rgba(255,90,70,.4); }
.aqActions{ display:flex; gap:4px; flex-shrink:0; }
.aqBtn{ transition: transform .2s cubic-bezier(.34,1.56,.64,1), background .15s ease; min-width:32px; height:30px; padding:0 8px; display:inline-grid; place-items:center; border-radius:10px; border:1px solid rgba(255,255,255,.22); background:rgba(255,255,255,.1); color:#fff; font:inherit; font-weight:800; font-size:13px; cursor:pointer; text-decoration:none; }
.aqBtn:hover:not(:disabled){ background:rgba(255,255,255,.2); transform: translateY(-2px); }
.aqBtn.danger{ border-color:rgba(255,120,100,.5); }
.aqBtn.armed{ background:#ff5a46; border-color:#ff5a46; }
.aqBtn:disabled{ opacity:.4; cursor:not-allowed; }
.aqFoot{ display:flex; gap:12px; flex-wrap:wrap; align-items:center; font-size:12px; padding-top:2px; }
.aqFoot a{ color:#fff; font-weight:800; text-decoration:underline; text-underline-offset:3px; }
.aqLinkBtn{ margin-left:auto; border:0; background:transparent; color:rgba(255,255,255,.6); font:inherit; font-size:11px; cursor:pointer; text-decoration:underline; }
`;
