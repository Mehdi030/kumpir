"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useProfile } from "@/hooks/useProfile";
import {
    ACTION_LABEL,
    adminErrorText,
    supabaseAdminApi,
    type AdminMatchRow,
    type AdminOverview,
    type AdminUserDetail,
    type AdminUserRow,
    type OnlinePlayer,
} from "@/lib/adminApi";
import { emailLabel } from "@/lib/accountSettings";
import { dateLocale, tk, useI18n } from "@/lib/i18n";

/**
 * Admin-Schnellmenü für Admins und Supporter – NUR für Aktionen mit Spielern (Wunsch Mehdi 2026-10-14):
 * Alt + A öffnet/schließt (Esc schließt zuerst die Spielerkarte, dann das Menü). Das Menü ist leicht durchsichtig und
 * versperrt nichts – das Spiel dahinter läuft weiter und bleibt bedienbar, man moderiert nebenbei.
 *  - Liste: wer ist online (oder beliebiges Konto suchen)
 *  - Klick auf einen Spieler: durchsichtige Spielerkarte daneben mit Kicken / Sperren / Entsperren und
 *    Reitern Verlauf (letzte Matches) · Konto · Protokoll
 *  - Links ins Admin-Panel öffnen in einem neuen Tab, damit man das Spiel nicht verlässt
 * Alles läuft über dieselben geprüften Datenbank-Funktionen wie das Admin-Panel.
 */

type View = "online" | "accounts";
type CardTab = "history" | "account" | "log";
const VIEW_KEY = "kumpir_quick_view";
const REFRESH_MS = 8000;

const PHASE_LABEL: Record<string, string> = {
    waiting: tk("Lobby"),
    lobby: tk("Lobby"),
    topic_vote: tk("Abstimmung"),
    countdown: tk("Countdown"),
    running: tk("läuft"),
    quiz: tk("läuft"),
    set_summary: tk("Zwischenstand"),
    finished: tk("beendet"),
    rematch_wait: tk("Revanche"),
};

/** Wen die Karte gerade zeigt (aus der Online-Liste oder der Konten-Liste) */
type Focus = {
    key: string;
    name: string;
    username: string | null;
    userId: string | null;
    role: "user" | "supporter" | "admin" | null;
    status: "active" | "suspended" | "deletion_requested" | null;
    lobbyId: string | null;
    playerId: string | null;
    lobbyCode: string | null;
    phase: string | null;
    isHost: boolean;
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

function Confirm({ label, danger, disabled, onYes, title, wide }: { label: string; danger?: boolean; disabled?: boolean; onYes: () => void; title?: string; wide?: boolean }) {
    const { tr } = useI18n();
    const [armed, setArmed] = useState(false);
    useEffect(() => {
        if (!armed) return;
        const t = window.setTimeout(() => setArmed(false), 3000);
        return () => window.clearTimeout(t);
    }, [armed]);
    return (
        <button
            type="button"
            className={`aqBtn ${wide ? "wide" : ""} ${danger ? "danger" : ""} ${armed ? "armed" : ""}`}
            disabled={disabled}
            title={title}
            onClick={() => {
                if (armed) {
                    setArmed(false);
                    onYes();
                } else setArmed(true);
            }}
        >
            {armed ? tr("Sicher?") : label}
        </button>
    );
}

const fmtDate = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleString(dateLocale(), { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) : "–");

export function AdminQuickPanel() {
    const { tr } = useI18n();
    const { user, profile } = useProfile();
    const api = useMemo(() => supabaseAdminApi(), []);
    const isStaff = !!user && !!profile?.isStaff;
    const isAdmin = profile?.role === "admin";

    const [open, setOpen] = useState(false);
    // Aus dem Browser-Speicher; gerendert wird erst, wenn das Konto geladen ist (also nie vor der Hydration)
    const [view, setViewState] = useState<View>(() => {
        const v = typeof window === "undefined" ? null : readLS(VIEW_KEY);
        return v === "accounts" ? v : "online";
    });
    const [search, setSearch] = useState("");
    const [overview, setOverview] = useState<AdminOverview | null>(null);
    const [online, setOnline] = useState<OnlinePlayer[] | null>(null);
    const [accounts, setAccounts] = useState<AdminUserRow[] | null>(null);
    const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
    const [busy, setBusy] = useState(false);
    const [focus, setFocus] = useState<Focus | null>(null);
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

    // Tastenkürzel: Alt + A öffnet/schließt, Esc schließt zuerst die Spielerkarte, dann das Menü
    useEffect(() => {
        if (!isStaff) return;
        const onKey = (e: KeyboardEvent) => {
            if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyA") {
                e.preventDefault();
                setOpen((o) => !o);
            } else if (e.key === "Escape") {
                setFocus((f) => {
                    if (f) return null;
                    setOpen(false);
                    return f;
                });
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
        } else {
            const r = await api.listUsers(search.trim(), "all");
            if (r.error) flash(false, adminErrorText(r.error));
            else setAccounts(r.data ?? []);
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
        async (fn: () => Promise<{ error?: string }>, okText: string, after?: () => void) => {
            if (busy) return;
            setBusy(true);
            const r = await fn();
            setBusy(false);
            if (r.error) flash(false, adminErrorText(r.error));
            else {
                flash(true, okText);
                after?.();
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

    const focusOnline = (p: OnlinePlayer) =>
        setFocus({
            key: `o:${p.playerId}`,
            name: p.name,
            username: p.username,
            userId: p.userId,
            role: p.role,
            status: p.accountStatus,
            lobbyId: p.lobbyId,
            playerId: p.playerId,
            lobbyCode: p.lobbyCode,
            phase: p.phase,
            isHost: p.isHost,
        });
    const focusAccount = (u: AdminUserRow) => {
        // ist das Konto gerade in einer Lobby? Dann kann die Karte auch kicken
        const live = (online ?? []).find((p) => p.userId === u.id);
        setFocus({
            key: `a:${u.id}`,
            name: u.displayName || u.username || "?",
            username: u.username,
            userId: u.id,
            role: u.role,
            status: u.status,
            lobbyId: live?.lobbyId ?? null,
            playerId: live?.playerId ?? null,
            lobbyCode: live?.lobbyCode ?? null,
            phase: live?.phase ?? null,
            isHost: live?.isHost ?? false,
        });
    };

    return (
        <>
            {open ? (
                <div className="aqPanel" role="dialog" aria-label={tr("Admin-Schnellmenü")}>
                    <div className="aqHead">
                        <div>
                            <b>{tr("🛡️ Spieler-Schnellmenü")}</b>
                            <span className="aqKbd">{tr("Alt + A")}</span>
                        </div>
                        <button type="button" className="aqClose" onClick={() => setOpen(false)} aria-label={tr("Schließen")}>
                            ✕
                        </button>
                    </div>

                    <div className="aqChips">
                        <button type="button" className={`aqChip ${view === "online" ? "on" : ""}`} onClick={() => setView("online")}>
                            🟢 {tr("Online")} <b>{online ? online.length : "–"}</b>
                        </button>
                        <button type="button" className={`aqChip ${view === "accounts" ? "on" : ""}`} onClick={() => setView("accounts")}>
                            👥 {tr("Konten")} <b>{c ? c.users : "–"}</b>
                        </button>
                    </div>

                    <input
                        className="aqSearch"
                        value={search}
                        onChange={(e) => setSearch(e.target.value)}
                        placeholder={view === "online" ? tr("Online-Spieler suchen …") : tr("Konto suchen (Name, E-Mail) …")}
                        aria-label={tr("Suchen")}
                    />

                    {msg ? <div className={`aqMsg ${msg.ok ? "ok" : "err"}`}>{tr(msg.text)}</div> : null}

                    <div className="aqList">
                        {view === "online" ? (
                            online === null ? (
                                <div className="aqEmpty">{tr("Lade …")}</div>
                            ) : onlineFiltered.length === 0 ? (
                                <div className="aqEmpty">{search ? tr("Kein Treffer.") : tr("Gerade ist niemand in einer Lobby.")}</div>
                            ) : (
                                onlineFiltered.map((p) => {
                                    const isStaffTarget = p.role === "admin" || p.role === "supporter";
                                    return (
                                        <button type="button" key={p.playerId} className={`aqRow ${focus?.key === `o:${p.playerId}` ? "sel" : ""}`} onClick={() => focusOnline(p)}>
                                            <span className="aqInfo">
                                                <span className="aqName">
                                                    {p.name}
                                                    {p.isHost ? <span title={tr("Host")}> 👑</span> : null}
                                                    {isStaffTarget ? <span className="aqTag">{p.role === "admin" ? tr("Admin") : tr("Supporter")}</span> : null}
                                                    {p.accountStatus === "suspended" ? <span className="aqTag bad">{tr("gesperrt")}</span> : null}
                                                </span>
                                                <span className="aqSub">
                                                    {p.username ? `@${p.username}` : tr("Gast")} · {tr("Lobby")} {p.lobbyCode} · {tr(PHASE_LABEL[p.phase] ?? p.phase)}
                                                </span>
                                            </span>
                                            <span className="aqGo" aria-hidden>
                                                🔍
                                            </span>
                                        </button>
                                    );
                                })
                            )
                        ) : accounts === null ? (
                            <div className="aqEmpty">{tr("Lade …")}</div>
                        ) : accounts.length === 0 ? (
                            <div className="aqEmpty">{tr("Kein Treffer.")}</div>
                        ) : (
                            accounts.map((u) => (
                                <button type="button" key={u.id} className={`aqRow ${focus?.key === `a:${u.id}` ? "sel" : ""}`} onClick={() => focusAccount(u)}>
                                    <span className="aqInfo">
                                        <span className="aqName">
                                            {u.username ?? "?"}
                                            {u.role === "admin" || u.role === "supporter" ? <span className="aqTag">{u.role === "admin" ? tr("Admin") : tr("Supporter")}</span> : null}
                                            {u.status === "suspended" ? <span className="aqTag bad">{tr("gesperrt")}</span> : null}
                                            {u.status === "deletion_requested" ? <span className="aqTag bad">{tr("Löschantrag")}</span> : null}
                                        </span>
                                        <span className="aqSub">{emailLabel(u.email)}</span>
                                    </span>
                                    <span className="aqGo" aria-hidden>
                                        🔍
                                    </span>
                                </button>
                            ))
                        )}
                    </div>

                    <div className="aqFoot">
                        <Link href="/admin" target="_blank" rel="noopener">
                            {tr("Admin-Panel")} ↗
                        </Link>
                        <Link href="/admin?tab=audit" target="_blank" rel="noopener">
                            {tr("Protokoll")} ↗
                        </Link>
                        {isAdmin ? (
                            <Link href="/admin/stats" target="_blank" rel="noopener">
                                {tr("Statistik")} ↗
                            </Link>
                        ) : null}
                    </div>
                </div>
            ) : null}

            {open && focus ? (
                <PlayerCard
                    key={focus.key}
                    focus={focus}
                    api={api}
                    meId={user?.id ?? null}
                    isAdmin={isAdmin}
                    busy={busy}
                    onClose={() => setFocus(null)}
                    onKick={() =>
                        void act(() => api.kickPlayer(focus.lobbyId!, focus.playerId!), tr("{name} gekickt.", { name: focus.name }), () => setFocus((f) => (f ? { ...f, lobbyId: null, playerId: null, lobbyCode: null, phase: null } : f)))
                    }
                    onStatus={(next) =>
                        void act(
                            async () => {
                                const s = await api.setStatus(focus.userId!, next, next === "suspended" ? "Schnellmenü" : undefined);
                                if (s.error || next !== "suspended" || !focus.lobbyId || !focus.playerId) return s;
                                // gesperrt: gleich auch aus der Lobby werfen
                                const k = await api.kickPlayer(focus.lobbyId, focus.playerId);
                                return k.error && !k.error.includes("player_not_found") ? k : {};
                            },
                            next === "suspended" ? tr("{name} gesperrt und rausgeworfen.", { name: focus.username ?? focus.name }) : tr("{name} entsperrt.", { name: focus.username ?? focus.name }),
                            () => setFocus((f) => (f ? { ...f, status: next, ...(next === "suspended" ? { lobbyId: null, playerId: null, lobbyCode: null, phase: null } : {}) } : f))
                        )
                    }
                />
            ) : null}

            <style>{STYLES}</style>
        </>
    );
}

function PlayerCard({
    focus,
    api,
    meId,
    isAdmin,
    busy,
    onClose,
    onKick,
    onStatus,
}: {
    focus: Focus;
    api: ReturnType<typeof supabaseAdminApi>;
    meId: string | null;
    isAdmin: boolean;
    busy: boolean;
    onClose: () => void;
    onKick: () => void;
    onStatus: (next: "active" | "suspended") => void;
}) {
    const { tr } = useI18n();
    const [tab, setTab] = useState<CardTab>("history");
    const [detail, setDetail] = useState<AdminUserDetail | null>(null);
    const [matches, setMatches] = useState<AdminMatchRow[] | null>(null);
    const [err, setErr] = useState("");

    useEffect(() => {
        if (!focus.userId) return;
        let alive = true;
        void (async () => {
            const [d, h] = await Promise.all([api.getUser(focus.userId!), api.userHistory(focus.userId!)]);
            if (!alive) return;
            if (d.error) setErr(adminErrorText(d.error));
            else setDetail(d.data ?? null);
            setMatches(h.data?.matches ?? []);
        })();
        return () => {
            alive = false;
        };
    }, [api, focus.userId]);

    const targetIsAdmin = focus.role === "admin";
    const targetIsStaff = targetIsAdmin || focus.role === "supporter";
    const canKick = !!focus.lobbyId && !!focus.playerId && !(targetIsAdmin && !isAdmin);
    const canBan = !!focus.userId && focus.userId !== meId && !targetIsAdmin && !(focus.role === "supporter" && !isAdmin);
    const status = detail?.status ?? focus.status;

    return (
        <aside className="aqCard" role="dialog" aria-label={tr("Spielerkarte")}>
            <div className="aqCardHead">
                <div className="aqCardWho">
                    <b>{focus.name}</b>
                    <span>
                        {focus.username ? `@${focus.username}` : tr("Gast – kein Konto")}
                        {targetIsStaff ? <span className="aqTag">{targetIsAdmin ? tr("Admin") : tr("Supporter")}</span> : null}
                        {status === "suspended" ? <span className="aqTag bad">{tr("gesperrt")}</span> : null}
                    </span>
                    <small>
                        {focus.lobbyCode ? `${tr("Lobby")} ${focus.lobbyCode} · ${tr(PHASE_LABEL[focus.phase ?? ""] ?? focus.phase ?? "")}${focus.isHost ? " · 👑" : ""}` : tr("gerade in keiner Lobby")}
                    </small>
                </div>
                <button type="button" className="aqClose" onClick={onClose} aria-label={tr("Schließen")}>
                    ✕
                </button>
            </div>

            <div className="aqCardActions">
                <Confirm wide label={`👢 ${tr("Kicken")}`} title={tr("Aus der Lobby werfen")} disabled={busy || !canKick} onYes={onKick} />
                {canBan && status === "suspended" ? (
                    <Confirm wide label={`✅ ${tr("Entsperren")}`} disabled={busy} onYes={() => onStatus("active")} />
                ) : canBan ? (
                    <Confirm wide danger label={`⛔ ${tr("Bannen")}`} title={tr("Konto sperren (meldet überall ab) und rauswerfen")} disabled={busy} onYes={() => onStatus("suspended")} />
                ) : null}
                {focus.username ? (
                    <Link href={`/admin?tab=users&q=${encodeURIComponent(focus.username)}`} target="_blank" rel="noopener" className="aqBtn wide" title={tr("Im Admin-Panel öffnen")}>
                        ↗ {tr("Admin-Panel")}
                    </Link>
                ) : null}
            </div>

            {focus.userId ? (
                <>
                    <div className="aqTabs" role="tablist">
                        {(
                            [
                                ["history", tr("📜 Verlauf")],
                                ["account", tr("👤 Konto")],
                                ["log", tr("🛡️ Protokoll")],
                            ] as [CardTab, string][]
                        ).map(([k, l]) => (
                            <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>
                                {l}
                            </button>
                        ))}
                    </div>
                    {err ? <div className="aqMsg err">{err}</div> : null}
                    <div className="aqCardBody">
                        {tab === "history" ? (
                            matches === null ? (
                                <div className="aqEmpty">{tr("Lade …")}</div>
                            ) : matches.length === 0 ? (
                                <div className="aqEmpty">{tr("Noch keine abgeschlossenen Matches.")}</div>
                            ) : (
                                <ul className="aqMatches">
                                    {matches.map((m, i) => (
                                        <li key={`${m.finishedAt}:${i}`}>
                                            <span className={`aqPlace p${m.place ?? 0}`}>{m.place ? `#${m.place}` : "–"}</span>
                                            <span className="aqMatchMain">
                                                <b>
                                                    {fmtDate(m.finishedAt)}
                                                    {m.lobbyCode ? ` · ${m.lobbyCode}` : ""}
                                                </b>
                                                <small>
                                                    {tr("{n} Spieler", { n: m.players ?? 0 })} · {m.points ?? 0} {tr("Punkte")} · 🎵 {m.titles ?? 0} · ❌ {m.wrong ?? 0}
                                                    {m.playlists?.length ? ` · ${m.playlists.join(", ")}` : ""}
                                                    {m.ranked ? "" : ` · ${tr("Übung")}`}
                                                </small>
                                            </span>
                                        </li>
                                    ))}
                                </ul>
                            )
                        ) : null}

                        {tab === "account" ? (
                            !detail ? (
                                <div className="aqEmpty">{tr("Lade …")}</div>
                            ) : (
                                <div className="aqFacts">
                                    <div>
                                        <span>{tr("E-Mail")}</span>
                                        <b>{emailLabel(detail.email)}</b>
                                    </div>
                                    <div>
                                        <span>{tr("Konto seit")}</span>
                                        <b>{fmtDate(detail.createdAt)}</b>
                                    </div>
                                    <div>
                                        <span>{tr("Letzter Login")}</span>
                                        <b>{fmtDate(detail.lastSignInAt)}</b>
                                    </div>
                                    <div>
                                        <span>{tr("Zuletzt gespielt")}</span>
                                        <b>{fmtDate(detail.stats.lastPlayed)}</b>
                                    </div>
                                    <div>
                                        <span>{tr("Matches")}</span>
                                        <b>
                                            {detail.stats.matches} ({tr("{n} gewonnen", { n: detail.stats.matchWins })})
                                        </b>
                                    </div>
                                    <div>
                                        <span>{tr("Runden")}</span>
                                        <b>{detail.stats.rounds}</b>
                                    </div>
                                    <div>
                                        <span>{tr("Titel erkannt")}</span>
                                        <b>{detail.stats.titles}</b>
                                    </div>
                                    <div>
                                        <span>{tr("Erfolge")}</span>
                                        <b>{detail.stats.achievements}</b>
                                    </div>
                                </div>
                            )
                        ) : null}

                        {tab === "log" ? (
                            !detail ? (
                                <div className="aqEmpty">{tr("Lade …")}</div>
                            ) : detail.audit.length === 0 ? (
                                <div className="aqEmpty">{tr("Keine Admin-Aktionen zu diesem Konto.")}</div>
                            ) : (
                                <ul className="aqMatches">
                                    {detail.audit.map((a, i) => (
                                        <li key={`${a.created_at}:${i}`}>
                                            <span className="aqMatchMain">
                                                <b>{tr(ACTION_LABEL[a.action] ?? a.action)}</b>
                                                <small>
                                                    {fmtDate(a.created_at)} · {tr("von {name}", { name: a.actor_name ?? tr("System / Datenbank") })}
                                                </small>
                                            </span>
                                        </li>
                                    ))}
                                </ul>
                            )
                        ) : null}
                    </div>
                </>
            ) : (
                <div className="aqEmpty">{tr("Gast ohne Konto – es gibt keinen Verlauf. Kicken geht trotzdem.")}</div>
            )}
        </aside>
    );
}

const STYLES = `
@keyframes aqIn{ from{ opacity:0; transform: translateX(28px) scale(.97); } to{ opacity:1; transform:none; } }
@keyframes aqCardIn{ from{ opacity:0; transform: translateX(-18px) scale(.97); } to{ opacity:1; transform:none; } }
/* leicht durchsichtig: das Spiel dahinter bleibt sichtbar und bedienbar */
.aqPanel{ animation: aqIn .34s cubic-bezier(.16,1,.3,1) both; position:fixed; right:12px; top:12px; z-index:3000; width:min(370px, calc(100vw - 24px)); max-height:calc(100vh - 24px); display:flex; flex-direction:column; gap:8px; padding:12px; border-radius:20px; color:#fff;
  background:rgba(24,10,6,.66); border:1px solid rgba(255,255,255,.22); box-shadow:0 18px 50px rgba(0,0,0,.35); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); font-size:13px; }
.aqHead{ display:flex; justify-content:space-between; align-items:center; gap:8px; }
.aqKbd{ margin-left:8px; font-size:10.5px; font-weight:800; padding:2px 7px; border-radius:6px; background:rgba(255,255,255,.14); }
.aqClose{ width:28px; height:28px; border-radius:999px; border:0; background:rgba(255,255,255,.14); color:#fff; cursor:pointer; font-weight:900; flex:none; }
.aqChips{ display:flex; gap:6px; flex-wrap:wrap; }
.aqChip{ border:1px solid rgba(255,255,255,.22); background:rgba(255,255,255,.06); color:#fff; border-radius:999px; padding:5px 10px; font:inherit; font-weight:700; font-size:12px; cursor:pointer; }
.aqChip.on{ background:#ffd23f; color:#2b0f04; border-color:#ffd23f; }
.aqChip b{ margin-left:3px; }
.aqSearch{ width:100%; padding:8px 10px; border-radius:12px; font:inherit; font-size:13px; color:#fff; background:rgba(0,0,0,.32); border:1px solid rgba(255,255,255,.22); }
.aqSearch::placeholder{ color:rgba(255,255,255,.5); }
.aqMsg{ padding:6px 10px; border-radius:10px; font-weight:700; font-size:12px; }
.aqMsg.ok{ background:rgba(80,200,120,.3); }
.aqMsg.err{ background:rgba(255,90,70,.34); }
.aqList{ overflow:auto; display:grid; gap:5px; min-height:60px; max-height:52vh; padding-right:2px; }
.aqEmpty{ opacity:.75; padding:14px 6px; text-align:center; }
.aqRow{ width:100%; display:flex; justify-content:space-between; align-items:center; gap:8px; padding:8px 10px; border-radius:12px; background:rgba(255,255,255,.08); border:1px solid transparent; color:#fff; font:inherit; text-align:left; cursor:pointer; transition: background .15s ease, border-color .15s ease; }
.aqRow:hover{ background:rgba(255,255,255,.16); }
.aqRow.sel{ border-color:#ffd23f; background:rgba(255,210,63,.18); }
.aqInfo{ min-width:0; display:grid; }
.aqName{ font-weight:800; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.aqSub{ font-size:11.5px; opacity:.75; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.aqGo{ opacity:.6; flex:none; }
.aqTag{ margin-left:6px; font-size:10px; font-weight:900; padding:1px 6px; border-radius:999px; background:rgba(255,255,255,.2); }
.aqTag.bad{ background:rgba(255,90,70,.45); }
.aqBtn{ transition: transform .2s cubic-bezier(.34,1.56,.64,1), background .15s ease; min-width:32px; height:34px; padding:0 12px; display:inline-grid; place-items:center; border-radius:10px; border:1px solid rgba(255,255,255,.24); background:rgba(255,255,255,.12); color:#fff; font:inherit; font-weight:800; font-size:13px; cursor:pointer; text-decoration:none; white-space:nowrap; }
.aqBtn.wide{ flex:1 1 auto; }
.aqBtn:hover:not(:disabled){ background:rgba(255,255,255,.22); transform: translateY(-2px); }
.aqBtn.danger{ border-color:rgba(255,120,100,.55); }
.aqBtn.armed{ background:#ff5a46; border-color:#ff5a46; }
.aqBtn:disabled{ opacity:.4; cursor:not-allowed; }
.aqFoot{ display:flex; gap:12px; flex-wrap:wrap; align-items:center; font-size:12px; padding-top:2px; }
.aqFoot a{ color:#fff; font-weight:800; text-decoration:underline; text-underline-offset:3px; }

/* Spielerkarte: links neben dem Menü, ebenfalls durchsichtig */
.aqCard{ animation: aqCardIn .3s cubic-bezier(.16,1,.3,1) both; position:fixed; top:12px; right:calc(12px + min(370px, calc(100vw - 24px)) + 10px); z-index:3001; width:min(380px, calc(100vw - 24px)); max-height:calc(100vh - 24px); display:flex; flex-direction:column; gap:9px; padding:13px; border-radius:20px; color:#fff;
  background:rgba(24,10,6,.7); border:1px solid rgba(255,214,120,.4); box-shadow:0 18px 50px rgba(0,0,0,.4); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); font-size:13px; }
.aqCardHead{ display:flex; justify-content:space-between; gap:8px; align-items:flex-start; }
.aqCardWho{ display:grid; gap:2px; min-width:0; }
.aqCardWho b{ font-size:20px; font-family: var(--font-display); overflow-wrap:anywhere; line-height:1.1; }
.aqCardWho span{ font-weight:700; opacity:.9; }
.aqCardWho small{ opacity:.75; font-size:12px; }
.aqCardActions{ display:flex; gap:6px; flex-wrap:wrap; }
.aqTabs{ display:flex; gap:4px; padding:3px; border-radius:999px; background:rgba(0,0,0,.28); }
.aqTabs button{ flex:1; border:0; background:transparent; color:#fff; font:inherit; font-weight:800; font-size:12px; padding:6px 4px; border-radius:999px; cursor:pointer; opacity:.8; }
.aqTabs button.on{ background:#ffd23f; color:#2b0f04; opacity:1; }
.aqCardBody{ overflow:auto; max-height:46vh; min-height:70px; }
.aqMatches{ list-style:none; margin:0; padding:0; display:grid; gap:5px; }
.aqMatches li{ display:flex; gap:9px; align-items:center; padding:7px 9px; border-radius:11px; background:rgba(255,255,255,.08); }
.aqPlace{ flex:none; min-width:34px; text-align:center; font-family: var(--font-display); font-weight:900; font-size:16px; padding:3px 4px; border-radius:9px; background:rgba(255,255,255,.14); }
.aqPlace.p1{ background:rgba(255,210,63,.4); color:#fff3c4; }
.aqMatchMain{ display:grid; min-width:0; line-height:1.25; }
.aqMatchMain b{ font-size:12.5px; }
.aqMatchMain small{ font-size:11.5px; opacity:.78; overflow-wrap:anywhere; }
.aqFacts{ display:grid; grid-template-columns:1fr 1fr; gap:6px; }
.aqFacts div{ display:grid; gap:1px; padding:7px 9px; border-radius:11px; background:rgba(255,255,255,.08); }
.aqFacts span{ font-size:10.5px; font-weight:800; letter-spacing:.5px; text-transform:uppercase; opacity:.65; }
.aqFacts b{ font-size:13px; overflow-wrap:anywhere; }
@media (max-width: 800px){
  /* schmal: Karte liegt über dem Menü */
  .aqCard{ right:12px; top:12px; width:min(380px, calc(100vw - 24px)); }
}
`;
