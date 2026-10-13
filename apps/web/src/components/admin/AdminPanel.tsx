"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Spinner } from "@/components/Spinner";
import { AvatarBadge } from "@/components/profile/AccountSettings";
import { loadPlaylists } from "@/components/PlaylistPicker";
import {
    ACTION_LABEL,
    adminErrorText,
    type AdminApi,
    type AdminLobby,
    type AdminOverview,
    type AdminRole,
    type AdminSong,
    type AdminUserDetail,
    type AdminUserRow,
    type AuditEntry,
    type AuditPage,
    AUDIT_CATEGORY_LABEL,
    auditCategory,
    type AuditCategory,
} from "@/lib/adminApi";
import { emailLabel, isPlaceholderEmail } from "@/lib/accountSettings";
import { adminSetPassword } from "@/actions/register";
import { HomeButton } from "@/components/BackButton";
import { dateLocale, tk, trNow, useI18n } from "@/lib/i18n";

type Tab = "overview" | "users" | "deletion" | "lobbies" | "songs" | "stats" | "audit";
type Msg = { ok: boolean; text: string } | null;

const fmt = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleString(dateLocale(), { dateStyle: "short", timeStyle: "short" }) : "–");
const STATUS_LABEL: Record<string, string> = {
    active: tk("aktiv"),
    suspended: tk("⛔ gesperrt"),
    deletion_requested: tk("🗑️ Löschung beantragt"),
};
const ROLE_LABEL: Record<string, string> = {
    user: tk("Nutzer"),
    supporter: tk("🛟 Supporter"),
    admin: tk("🛡️ Admin"),
};
const PHASE_LABEL: Record<string, string> = {
    waiting: tk("Lobby"),
    lobby: tk("Lobby"),
    topic_vote: tk("Themenwahl"),
    countdown: tk("Countdown"),
    running: tk("läuft"),
    set_summary: tk("Zwischenstand"),
    finished: tk("beendet"),
    rematch_wait: tk("Rematch"),
};

function Note({ msg }: { msg: Msg }) {
    const { tr } = useI18n();
    if (!msg) return null;
    return (
        <div className={`admNote ${msg.ok ? "ok" : "err"}`} role={msg.ok ? "status" : "alert"}>
            {tr(msg.text)}
        </div>
    );
}

/** Zweistufiger Knopf: erst klicken, dann "Wirklich?" bestätigen. */
function ConfirmButton({ label, confirmLabel, onConfirm, danger = false, disabled = false }: { label: string; confirmLabel?: string; onConfirm: () => void; danger?: boolean; disabled?: boolean }) {
    const { tr } = useI18n();
    const [armed, setArmed] = useState(false);
    useEffect(() => {
        if (!armed) return;
        const t = window.setTimeout(() => setArmed(false), 4000);
        return () => window.clearTimeout(t);
    }, [armed]);
    return (
        <button
            type="button"
            className={`btn btnSmall ${armed || danger ? "admDanger" : "btnSecondary"}`}
            disabled={disabled}
            onClick={() => {
                if (armed) {
                    setArmed(false);
                    onConfirm();
                } else setArmed(true);
            }}
        >
            {armed ? (confirmLabel ?? tr("Wirklich? Nochmal tippen")) : label}
        </button>
    );
}

export function AdminPanel({ api, meId }: { api: AdminApi; meId: string | null }) {
    const { tr } = useI18n();
    const [tab, setTab] = useState<Tab>(() => {
        if (typeof window === "undefined") return "overview";
        const t = new URLSearchParams(window.location.search).get("tab");
        return t && ["overview", "users", "deletion", "lobbies", "songs", "stats", "audit"].includes(t) ? (t as Tab) : "overview";
    });
    const [overview, setOverview] = useState<AdminOverview | null>(null);
    const [error, setError] = useState("");

    const loadOverview = useCallback(async () => {
        const r = await api.overview();
        if (r.error) setError(adminErrorText(r.error));
        else if (r.data) setOverview(r.data);
    }, [api]);

    useEffect(() => {
        let alive = true;
        void (async () => {
            if (alive) await loadOverview();
        })();
        return () => {
            alive = false;
        };
    }, [loadOverview]);

    if (error) return <div className="admNote err">⛔ {error}</div>;
    if (!overview) return <Spinner size={22} label={tr("Lade Admin-Panel…")} />;
    const role: AdminRole = overview.role;
    const isAdmin = role === "admin";
    const c = overview.counts;

    const tabs: [Tab, string, boolean][] = [
        ["overview", tr("📋 Übersicht"), true],
        ["users", tr("👥 Nutzer"), true],
        ["deletion", `${tr("🗑️ Löschanträge")}${c.deletionRequests ? ` (${c.deletionRequests})` : ""}`, true],
        ["lobbies", tr("🎮 Lobbys"), true],
        ["songs", tr("🎵 Songs"), isAdmin],
        ["stats", tr("📊 Statistik"), isAdmin],
        ["audit", tr("📜 Protokoll"), true],
    ];

    return (
        <div className="adm">
            <div className="admHead">
                <div>
                    <h1 className="h1 admTitle">{tr("🛡️ Admin-Panel")}</h1>
                    <div className="admRole">{tr("Angemeldet als {role}", { role: tr(ROLE_LABEL[role] ?? role) })}</div>
                </div>
                <HomeButton />
            </div>

            <div className="admTabs" role="tablist" aria-label={tr("Bereiche")}>
                {tabs
                    .filter(([, , show]) => show)
                    .map(([key, label]) => (
                        <button
                            key={key}
                            type="button"
                            role="tab"
                            aria-selected={tab === key}
                            className={tab === key ? "on" : ""}
                            onClick={() => {
                                setTab(key);
                                if (key === "overview") void loadOverview();
                            }}
                        >
                            {label}
                        </button>
                    ))}
            </div>

            {tab === "overview" ? (
                <div className="admBox">
                    <div className="admTiles">
                        <Tile label={tr("Konten")} value={c.users} sub={tr("+{n} in 7 Tagen", { n: c.newUsers7d })} />
                        <Tile label={tr("Löschanträge")} value={c.deletionRequests} warn={c.deletionRequests > 0} onClick={() => setTab("deletion")} />
                        <Tile label={tr("Gesperrt")} value={c.suspended} onClick={() => setTab("users")} />
                        <Tile label={tr("Team")} value={c.staff} />
                        <Tile label={tr("Aktive Lobbys")} value={c.activeLobbies} sub={tr("{n} Spiele laufen", { n: c.runningGames })} onClick={() => setTab("lobbies")} />
                    </div>
                    <div className="admHint">
                        <b>{tr("Deine Rechte:")}</b>{" "}
                        {isAdmin
                            ? tr("alles – inkl. endgültig löschen, Rollen vergeben, Songs archivieren und Statistik.")
                            : tr("Nutzer ansehen, sperren/entsperren, Namen/Avatar zurücksetzen, Passwort-Reset senden, Löschanträge ablehnen, Lobbys schließen, Protokoll ansehen. Endgültig löschen und Rollen vergeben dürfen nur Admins.")}
                    </div>
                </div>
            ) : null}
            {tab === "users" ? <UsersTab api={api} role={role} meId={meId} initialFilter="all" onChanged={loadOverview} /> : null}
            {tab === "deletion" ? <UsersTab api={api} role={role} meId={meId} initialFilter="deletion" onChanged={loadOverview} /> : null}
            {tab === "lobbies" ? <LobbiesTab api={api} /> : null}
            {tab === "songs" && isAdmin ? <SongsTab api={api} /> : null}
            {tab === "stats" && isAdmin ? (
                <div className="admBox">
                    <p className="admHint">{tr("Spielzahlen, Song-Bekanntheit, Balance aus echten Zügen und der anonyme Weg der Spieler.")}</p>
                    <Link href="/admin/stats" className="btn btnPrimary btnSmall">
                        {tr("📊 Zur Statistik-Seite")}
                    </Link>
                </div>
            ) : null}
            {tab === "audit" ? <AuditTab api={api} /> : null}

            <style>{STYLES}</style>
        </div>
    );
}

function Tile({ label, value, sub, warn, onClick }: { label: string; value: number; sub?: string; warn?: boolean; onClick?: () => void }) {
    const body = (
        <>
            <div className={`admTileVal ${warn ? "warn" : ""}`}>{value}</div>
            <div className="admTileLabel">{label}</div>
            {sub ? <div className="admTileSub">{sub}</div> : null}
        </>
    );
    return onClick ? (
        <button type="button" className="admTile" onClick={onClick}>
            {body}
        </button>
    ) : (
        <div className="admTile">{body}</div>
    );
}

// ------------------------------------------------------------------ Nutzer
function UsersTab({ api, role, meId, initialFilter, onChanged }: { api: AdminApi; role: AdminRole; meId: string | null; initialFilter: "all" | "deletion"; onChanged: () => void }) {
    const { tr } = useI18n();
    const [search, setSearch] = useState(() => (typeof window === "undefined" ? "" : new URLSearchParams(window.location.search).get("q") ?? ""));
    const [filter, setFilter] = useState<"all" | "deletion" | "suspended" | "staff">(initialFilter);
    const [rows, setRows] = useState<AdminUserRow[] | null>(null);
    const [error, setError] = useState("");
    const [openId, setOpenId] = useState<string | null>(null);

    const load = useCallback(async () => {
        const r = await api.listUsers(search.trim(), filter);
        if (r.error) setError(adminErrorText(r.error));
        else {
            setError("");
            setRows(r.data ?? []);
        }
    }, [api, search, filter]);

    useEffect(() => {
        const t = window.setTimeout(() => void load(), 300);
        return () => window.clearTimeout(t);
    }, [load]);

    if (openId) {
        return (
            <UserDetail
                api={api}
                role={role}
                meId={meId}
                userId={openId}
                onBack={() => {
                    setOpenId(null);
                    void load();
                    onChanged();
                }}
            />
        );
    }

    return (
        <div className="admBox">
            {initialFilter === "deletion" ? (
                <p className="admHint">{tr("Spieler, die ihre Löschung beantragt haben. Ihr Zugang ist bereits gesperrt. Öffnen → „Antrag ablehnen“ (Zugang wieder frei) oder – nur Admin – „Endgültig löschen“.")}</p>
            ) : null}
            <div className="admRow">
                <input className="input" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={tr("Suche: Name, E-Mail …")} aria-label={tr("Nutzer suchen")} />
                {initialFilter === "all" ? (
                    <select className="admSelect" value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)} aria-label={tr("Filter")}>
                        <option value="all">{tr("Alle")}</option>
                        <option value="deletion">{tr("Löschanträge")}</option>
                        <option value="suspended">{tr("Gesperrt")}</option>
                        <option value="staff">{tr("Team")}</option>
                    </select>
                ) : null}
            </div>
            {error ? <div className="admNote err">{error}</div> : null}
            {!rows ? (
                <Spinner size={18} label={tr("Lade…")} />
            ) : rows.length === 0 ? (
                <div className="admHint">{initialFilter === "deletion" ? "Keine offenen Löschanträge. 🎉" : "Keine Treffer."}</div>
            ) : (
                <ul className="admList">
                    {rows.map((u) => (
                        <li key={u.id}>
                            <button type="button" className="admUser" onClick={() => setOpenId(u.id)}>
                                <AvatarBadge emoji={u.avatarEmoji} color={u.avatarColor} name={u.displayName || u.username || "?"} size={38} />
                                <span className="admUserMain">
                                    <b>
                                        {u.displayName || u.username || tr("(ohne Namen)")}
                                        {u.username ? <small> @{u.username}</small> : null}
                                    </b>
                                    <small>{tr(emailLabel(u.email))}</small>
                                </span>
                                <span className="admUserMeta">
                                    {u.role !== "user" ? <span className="admBadge staff">{tr(ROLE_LABEL[u.role] ?? u.role)}</span> : null}
                                    {u.status !== "active" ? <span className="admBadge warn">{tr(STATUS_LABEL[u.status] ?? u.status)}</span> : null}
                                    <small>
                                        {tr("{n} Matches · seit {date}", { n: u.matches, date: new Date(u.createdAt).toLocaleDateString(dateLocale()) })}
                                    </small>
                                </span>
                            </button>
                        </li>
                    ))}
                </ul>
            )}
        </div>
    );
}

function UserDetail({ api, role, meId, userId, onBack }: { api: AdminApi; role: AdminRole; meId: string | null; userId: string; onBack: () => void }) {
    const { tr } = useI18n();
    const [u, setU] = useState<AdminUserDetail | null>(null);
    const [msg, setMsg] = useState<Msg>(null);
    const [busy, setBusy] = useState(false);
    const [reason, setReason] = useState("");
    const [newName, setNewName] = useState("");
    const [newPw, setNewPw] = useState("");
    const [newRole, setNewRole] = useState<"user" | "supporter" | "admin">("user");
    const [delConfirm, setDelConfirm] = useState("");
    const [gone, setGone] = useState(false);

    const load = useCallback(async () => {
        const r = await api.getUser(userId);
        if (r.error) setMsg({ ok: false, text: adminErrorText(r.error) });
        else if (r.data) {
            setU(r.data);
            setNewRole(r.data.role);
        }
    }, [api, userId]);

    useEffect(() => {
        let alive = true;
        void (async () => {
            if (alive) await load();
        })();
        return () => {
            alive = false;
        };
    }, [load]);

    const run = async (fn: () => Promise<{ error?: string; data?: unknown }>, ok: string, reload = true) => {
        setBusy(true);
        setMsg(null);
        const r = await fn();
        setBusy(false);
        if (r.error) return setMsg({ ok: false, text: adminErrorText(r.error) });
        setMsg({ ok: true, text: ok });
        if (reload) await load();
    };

    if (gone) {
        return (
            <div className="admBox">
                <div className="admNote ok">{tr("❌ Konto endgültig gelöscht.")}</div>
                <button type="button" className="btn btnSecondary btnSmall" onClick={onBack}>
                    {tr("← Zurück zur Liste")}
                </button>
            </div>
        );
    }
    if (!u) return msg ? <Note msg={msg} /> : <Spinner size={18} label={tr("Lade Nutzer…")} />;

    const isAdmin = role === "admin";
    const isSelf = u.id === meId;
    const targetIsStaff = u.role !== "user";
    const canModerate = !isSelf && (isAdmin || !targetIsStaff);
    const label = u.username || u.email || tr("Nutzer");

    return (
        <div className="admBox">
            <button type="button" className="admBack" onClick={onBack}>
                {tr("← Zurück zur Liste")}
            </button>
            <div className="admRow" style={{ gap: 14 }}>
                <AvatarBadge emoji={u.avatarEmoji} color={u.avatarColor} name={u.displayName || u.username || "?"} size={56} />
                <div style={{ minWidth: 0 }}>
                    <h2 className="admH2">
                        {u.displayName || u.username || tr("(ohne Namen)")} {u.username ? <small>@{u.username}</small> : null}
                    </h2>
                    <div className="admSmall">
                        {tr(emailLabel(u.email))} {isPlaceholderEmail(u.email) ? "" : u.confirmed ? "✓" : tr("(nicht bestätigt)")} · {tr(ROLE_LABEL[u.role] ?? u.role)} · {tr(STATUS_LABEL[u.status] ?? u.status)}
                    </div>
                </div>
            </div>

            <div className="admTiles">
                <Tile label={tr("Matches")} value={u.stats.matches} sub={tr("{n} gewonnen", { n: u.stats.matchWins })} />
                <Tile label={tr("Runden")} value={u.stats.rounds} />
                <Tile label={tr("Titel erkannt")} value={u.stats.titles} />
                <Tile label={tr("Erfolge")} value={u.stats.achievements} />
            </div>
            <div className="admSmall">
                {tr("Konto seit {a} · letzter Login {b} · zuletzt gespielt {c}", { a: fmt(u.createdAt), b: fmt(u.lastSignInAt), c: fmt(u.stats.lastPlayed) })}
            </div>

            <Note msg={msg} />

            {/* Status */}
            <section className="admGroup">
                <h3>{tr("Zugang")}</h3>
                {u.status === "deletion_requested" ? (
                    <>
                        <div className="admHint">
                            {tr("🗑️ Löschung beantragt am {date}", { date: fmt(u.deletionRequestedAt) })}
                            {u.statusReason ? ` – ${tr("Grund:")} „${u.statusReason}“` : ""}. {tr("Zugang ist gesperrt.")}
                        </div>
                        <div className="admRow">
                            {canModerate ? (
                                <ConfirmButton label={tr("↩️ Antrag ablehnen (Zugang wieder öffnen)")} onConfirm={() => void run(() => api.setStatus(u.id, "active"), tr("Antrag abgelehnt – Konto ist wieder aktiv."))} disabled={busy} />
                            ) : null}
                        </div>
                    </>
                ) : u.status === "suspended" ? (
                    <>
                        <div className="admHint">
                            {tr("⛔ Gesperrt seit {date}", { date: fmt(u.statusChangedAt) })}
                            {u.statusReason ? ` – Grund: „${u.statusReason}“` : ""}.
                        </div>
                        {canModerate ? <ConfirmButton label={tr("✅ Entsperren")} onConfirm={() => void run(() => api.setStatus(u.id, "active"), tr("Entsperrt – Login wieder möglich."))} disabled={busy} /> : null}
                    </>
                ) : canModerate ? (
                    <div className="admRow">
                        <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={tr("Grund (optional, sieht nur das Team)")} maxLength={300} aria-label={tr("Grund für die Sperre")} />
                        <ConfirmButton label={tr("⛔ Sperren")} danger onConfirm={() => void run(() => api.setStatus(u.id, "suspended", reason), tr("Gesperrt und überall abgemeldet."))} disabled={busy} />
                    </div>
                ) : (
                    <div className="admHint">{isSelf ? tr("Das eigene Konto kann hier nicht gesperrt werden.") : tr("Team-Konten kann nur ein Admin sperren.")}</div>
                )}
            </section>

            {/* Moderation */}
            {canModerate ? (
                <section className="admGroup">
                    <h3>{tr("Profil & Login-Hilfe")}</h3>
                    <div className="admRow">
                        <input
                            className="input"
                            value={newName}
                            onChange={(e) => setNewName(e.target.value.toLowerCase().replace(/\s/g, ""))}
                            placeholder={tr("Neuer Benutzername (aktuell {name})", { name: u.username ?? "–" })}
                            maxLength={20}
                            aria-label={tr("Neuer Benutzername")}
                        />
                        <button type="button" className="btn btnSecondary btnSmall" disabled={busy || !newName} onClick={() => void run(() => api.moderate(u.id, { username: newName }), tr("Benutzername geändert.")).then(() => setNewName(""))}>
                            {tr("Ändern")}
                        </button>
                    </div>
                    <div className="admRow">
                        <button type="button" className="btn btnSecondary btnSmall" disabled={busy || !u.displayName} onClick={() => void run(() => api.moderate(u.id, { resetDisplayName: true }), tr("Spielername zurückgesetzt."))}>
                            {tr("Spielername zurücksetzen")}
                        </button>
                        <button type="button" className="btn btnSecondary btnSmall" disabled={busy || (!u.avatarEmoji && !u.avatarColor)} onClick={() => void run(() => api.moderate(u.id, { resetAvatar: true }), tr("Avatar zurückgesetzt."))}>
                            {tr("Avatar zurücksetzen")}
                        </button>
                        {u.email && !isPlaceholderEmail(u.email) ? (
                            <ConfirmButton label={tr("🔑 Passwort-Reset-Mail senden")} onConfirm={() => void run(() => api.sendPasswordReset(u.id), tr("Mail mit Reset-Link an {mail} gesendet.", { mail: u.email ?? "" }))} disabled={busy} />
                        ) : null}
                    </div>
                    {role === "admin" ? (
                        <div className="admRow">
                            <input
                                className="input"
                                type="text"
                                value={newPw}
                                onChange={(e) => setNewPw(e.target.value)}
                                placeholder={tr("Neues Passwort (z.B. Kartoffel7)")}
                                autoComplete="off"
                                aria-label={tr("Neues Passwort für dieses Konto")}
                            />
                            <ConfirmButton
                                label={tr("🔐 Neues Passwort setzen")}
                                onConfirm={() =>
                                    void run(async () => {
                                        const r = await adminSetPassword(u.id, newPw);
                                        return r.ok ? { data: true } : { error: r.error };
                                    }, tr("Neues Passwort gesetzt. Gib es der Person weiter.")).then(() => setNewPw(""))
                                }
                                disabled={busy || newPw.length < 8}
                            />
                        </div>
                    ) : null}
                </section>
            ) : null}

            {/* Rolle (nur Admin) */}
            {isAdmin && !isSelf ? (
                <section className="admGroup">
                    <h3>{tr("Rolle")}</h3>
                    <div className="admRow">
                        <select className="admSelect" value={newRole} onChange={(e) => setNewRole(e.target.value as typeof newRole)} aria-label={tr("Rolle")}>
                            <option value="user">{tr("Nutzer")}</option>
                            <option value="supporter">{tr("Supporter (weniger Rechte)")}</option>
                            <option value="admin">{tr("Admin (alle Rechte)")}</option>
                        </select>
                        <button type="button" className="btn btnSecondary btnSmall" disabled={busy || newRole === u.role} onClick={() => void run(() => api.setRole(u.id, newRole), `Rolle: ${ROLE_LABEL[newRole]}`)}>
                            {tr("Rolle speichern")}
                        </button>
                    </div>
                </section>
            ) : null}

            {/* Endgültig löschen (nur Admin) */}
            {isAdmin && !isSelf ? (
                <section className="admGroup admDangerBox">
                    <h3>{tr("Konto endgültig löschen")}</h3>
                    {targetIsStaff ? (
                        <div className="admHint">{tr("Team-Konten können nicht gelöscht werden – erst die Rolle auf „Nutzer“ setzen.")}</div>
                    ) : (
                        <>
                            <div className="admHint">
                                {tr("Löscht Konto, Verlauf, Erfolge, Saison-Punkte und Freunde.")} <b>{tr("Nicht rückgängig zu machen.")}</b> {tr("Zum Bestätigen den Benutzernamen eintippen:")} <b>{label}</b>
                            </div>
                            <div className="admRow">
                                <input className="input" value={delConfirm} onChange={(e) => setDelConfirm(e.target.value)} placeholder={label} aria-label={tr("Benutzername zur Bestätigung")} />
                                <button
                                    type="button"
                                    className="btn btnSmall admDanger"
                                    disabled={busy || delConfirm.trim().toLowerCase() !== label.toLowerCase()}
                                    onClick={async () => {
                                        setBusy(true);
                                        const r = await api.deleteUser(u.id);
                                        setBusy(false);
                                        if (r.error) setMsg({ ok: false, text: adminErrorText(r.error) });
                                        else setGone(true);
                                    }}
                                >
                                    {busy ? "…" : tr("Endgültig löschen")}
                                </button>
                            </div>
                        </>
                    )}
                </section>
            ) : null}

            {u.audit.length ? (
                <section className="admGroup">
                    <h3>{tr("Verlauf zu diesem Konto")}</h3>
                    <ul className="admAudit">
                        {u.audit.map((a, i) => (
                            <li key={i}>
                                <span>{fmt(a.created_at)}</span> <b>{tr(ACTION_LABEL[a.action] ?? a.action)}</b> <small>{tr("von {name}", { name: a.actor_name ?? "?" })}</small>
                            </li>
                        ))}
                    </ul>
                </section>
            ) : null}
        </div>
    );
}

// ------------------------------------------------------------------ Lobbys
function LobbiesTab({ api }: { api: AdminApi }) {
    const { tr } = useI18n();
    const [rows, setRows] = useState<AdminLobby[] | null>(null);
    const [msg, setMsg] = useState<Msg>(null);
    const load = useCallback(async () => {
        const r = await api.listLobbies();
        if (r.error) setMsg({ ok: false, text: adminErrorText(r.error) });
        else setRows(r.data ?? []);
    }, [api]);
    useEffect(() => {
        let alive = true;
        void (async () => {
            if (alive) await load();
        })();
        return () => {
            alive = false;
        };
    }, [load]);

    return (
        <div className="admBox">
            <div className="admRow" style={{ justifyContent: "space-between" }}>
                <p className="admHint" style={{ margin: 0 }}>
                    {tr("Alle Lobbys (leere schließen sich nach 3 Min. automatisch). „Schließen“ beendet die Lobby sofort für alle.")}
                </p>
                <button type="button" className="btn btnSecondary btnSmall" onClick={() => void load()}>
                    {tr("🔄 Aktualisieren")}
                </button>
            </div>
            <Note msg={msg} />
            {!rows ? (
                <Spinner size={18} label={tr("Lade…")} />
            ) : rows.length === 0 ? (
                <div className="admHint">{tr("Gerade keine Lobbys.")}</div>
            ) : (
                <ul className="admList">
                    {rows.map((l) => (
                        <li key={l.id} className="admLobby">
                            <div>
                                <b className="admCode">{l.code}</b> <span className="admBadge">{tr(PHASE_LABEL[l.phase] ?? l.phase)}</span>
                                {l.locked ? <span className="admBadge">🔒</span> : null}
                                <div className="admSmall">
                                    {tr("Host {name}", { name: l.host ?? "?" })} · {tr("{n} Menschen", { n: l.humans })}
                                    {l.bots ? ` + ${tr("{n} Bots", { n: l.bots })}` : ""}
                                    {l.accounts ? ` · ${tr("{n} mit Konto", { n: l.accounts })}` : ""}
                                    {l.playlist ? ` · ${l.playlist}` : ""}
                                    {l.roundsTotal && l.roundsTotal > 1 ? ` · ${tr("Runde")} ${l.roundIndex}/${l.roundsTotal}` : ""} · {tr("aktiv {date}", { date: fmt(l.lastActivityAt) })}
                                </div>
                            </div>
                            <div className="admRow">
                                <Link href={`/game/${l.code}`} className="btn btnSecondary btnSmall" target="_blank">
                                    {tr("👀 Ansehen")}
                                </Link>
                                <ConfirmButton
                                    label={tr("🚪 Schließen")}
                                    danger
                                    onConfirm={async () => {
                                        const r = await api.closeLobby(l.id);
                                        setMsg(r.error ? { ok: false, text: adminErrorText(r.error) } : { ok: true, text: tr("Lobby {code} geschlossen.", { code: l.code }) });
                                        void load();
                                    }}
                                />
                            </div>
                        </li>
                    ))}
                </ul>
            )}
        </div>
    );
}

// ------------------------------------------------------------------ Songs (Admin)
function SongsTab({ api }: { api: AdminApi }) {
    const { tr } = useI18n();
    const [playlists, setPlaylists] = useState<string[]>([]);
    const [playlist, setPlaylist] = useState<string>("");
    const [search, setSearch] = useState("");
    const [rows, setRows] = useState<AdminSong[] | null>(null);
    const [msg, setMsg] = useState<Msg>(null);

    useEffect(() => {
        void loadPlaylists().then((l) => setPlaylists(l.map((p) => p.name)));
    }, []);

    const load = useCallback(async () => {
        const r = await api.listSongs(playlist || null, search.trim());
        if (r.error) setMsg({ ok: false, text: adminErrorText(r.error) });
        else setRows(r.data ?? []);
    }, [api, playlist, search]);
    useEffect(() => {
        const t = window.setTimeout(() => void load(), 300);
        return () => window.clearTimeout(t);
    }, [load]);

    return (
        <div className="admBox">
            <p className="admHint">
                {tr("Archivierte Songs werden nie mehr gespielt, bleiben aber gespeichert und lassen sich zurückholen. „Erkannt“ = Anteil voller Titel-Treffer bei Menschen (rot unter 50 %).")}
            </p>
            <div className="admRow">
                <select className="admSelect" value={playlist} onChange={(e) => setPlaylist(e.target.value)} aria-label={tr("Playlist")}>
                    <option value="">{tr("Alle Playlists")}</option>
                    {playlists.map((p) => (
                        <option key={p} value={p}>
                            {p}
                        </option>
                    ))}
                </select>
                <input className="input" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={tr("Titel oder Interpret")} aria-label={tr("Song suchen")} />
            </div>
            <Note msg={msg} />
            {!rows ? (
                <Spinner size={18} label={tr("Lade…")} />
            ) : (
                <ul className="admList">
                    {rows.map((s) => {
                        const weak = s.plays >= 5 && (s.rate ?? 0) < 50;
                        return (
                            <li key={s.id} className={`admSong ${s.archivedFrom ? "archived" : ""}`}>
                                <div style={{ minWidth: 0 }}>
                                    <b>{s.title}</b> <small>– {s.artist}</small>
                                    <div className="admSmall">
                                        {s.archivedFrom ? tr("📦 archiviert (aus {pl})", { pl: s.archivedFrom }) : s.playlist} · {tr("{n} Einsätze", { n: s.plays })} ·{" "}
                                        <span className={weak ? "admWeak" : ""}>{s.rate != null ? tr("{n} % erkannt", { n: s.rate }) : tr("noch keine Daten")}</span>
                                    </div>
                                </div>
                                <button
                                    type="button"
                                    className="btn btnSecondary btnSmall"
                                    onClick={async () => {
                                        const r = await api.setSongArchived(s.id, !s.archivedFrom);
                                        setMsg(r.error ? { ok: false, text: adminErrorText(r.error) } : { ok: true, text: s.archivedFrom ? tr("„{title}“ ist wieder in {pl}.", { title: s.title, pl: s.archivedFrom }) : tr("„{title}“ archiviert.", { title: s.title }) });
                                        void load();
                                    }}
                                >
                                    {s.archivedFrom ? tr("♻️ Zurückholen") : tr("📦 Archivieren")}
                                </button>
                            </li>
                        );
                    })}
                </ul>
            )}
        </div>
    );
}

// ------------------------------------------------------------------ Protokoll
const DETAIL_LABEL: Record<string, string> = {
    from: tk("vorher"),
    to: tk("nachher"),
    email: tk("E-Mail"),
    role: tk("Rolle"),
    status: tk("Status"),
    via: tk("über"),
    count: tk("Anzahl"),
    playlists: tk("Playlists"),
    sample: tk("Beispiele"),
    aktion: tk("Aktion"),
    bereiche: tk("Bereiche"),
    reason: tk("Grund"),
    playlist: tk("Playlist"),
    lobbyId: tk("Lobby-ID"),
    nachgetragen: tk("nachträglich eingetragen"),
};
function detailText(v: unknown): string {
    if (v === null || v === undefined || v === "") return "–";
    if (typeof v === "boolean") return v ? trNow("ja") : trNow("nein");
    if (Array.isArray(v)) return v.map(detailText).join(", ");
    if (typeof v === "object") return Object.entries(v as Record<string, unknown>).map(([k, x]) => `${k}: ${detailText(x)}`).join(" · ");
    return String(v);
}
const dayKey = (iso: string) => new Date(iso).toLocaleDateString(dateLocale(), { weekday: "long", day: "numeric", month: "long", year: "numeric" });
const timeOf = (iso: string) => new Date(iso).toLocaleTimeString(dateLocale(), { hour: "2-digit", minute: "2-digit", second: "2-digit" });

function AuditTab({ api }: { api: AdminApi }) {
    const { tr } = useI18n();
    const [page, setPage] = useState<AuditPage | null>(null);
    const [limit, setLimit] = useState(300);
    const [cat, setCat] = useState<AuditCategory>("all");
    const [search, setSearch] = useState("");
    const [error, setError] = useState("");
    const [loading, setLoading] = useState(false);
    useEffect(() => {
        let alive = true;
        void api.listAudit(limit).then((r) => {
            if (!alive) return;
            if (r.error) setError(adminErrorText(r.error));
            else {
                setError("");
                setPage(r.data ?? { total: 0, rows: [] });
            }
            setLoading(false);
        });
        return () => {
            alive = false;
        };
    }, [api, limit]);

    const q = search.trim().toLowerCase();
    const shown = (page?.rows ?? []).filter((a) => {
        if (cat !== "all" && auditCategory(a.action) !== cat) return false;
        if (!q) return true;
        const hay = [ACTION_LABEL[a.action] ?? a.action, a.targetLabel, a.actorName, a.details ? JSON.stringify(a.details) : ""].join(" ").toLowerCase();
        return hay.includes(q);
    });
    const days: { day: string; items: AuditEntry[] }[] = [];
    for (const a of shown) {
        const d = dayKey(a.createdAt);
        const last = days[days.length - 1];
        if (last && last.day === d) last.items.push(a);
        else days.push({ day: d, items: [a] });
    }
    const hasMore = !!page && page.rows.length < page.total;

    return (
        <div className="admBox">
            <p className="admHint">
                {tr("Hier steht jede Änderung an Konten, Profilen, Rollen, Sperren, Songs, Playlists und Lobbys – egal ob über das Admin-Panel, die Einstellungen eines Spielers oder ein Skript – mit Datum, Uhrzeit und Urheber. Einträge lassen sich nicht ändern oder löschen. Einzelne Spielzüge stehen nicht hier.")}
            </p>
            <div className="admRow">
                {(Object.keys(AUDIT_CATEGORY_LABEL) as AuditCategory[]).map((k) => (
                    <button key={k} type="button" className={`btn btnSmall ${cat === k ? "btnPrimary" : "btnSecondary"}`} onClick={() => setCat(k)}>
                        {tr(AUDIT_CATEGORY_LABEL[k])}
                    </button>
                ))}
            </div>
            <div className="admRow">
                <input className="input" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={tr("Suchen: Name, Aktion, Person …")} aria-label={tr("Protokoll durchsuchen")} />
            </div>
            {error ? <div className="admNote err">{error}</div> : null}
            {!page ? (
                <Spinner size={18} label={tr("Lade…")} />
            ) : (
                <>
                    <div className="admSmall">
                        {tr("{n} angezeigt · {total} insgesamt im Protokoll", { n: shown.length, total: page.total })}
                    </div>
                    {shown.length === 0 ? <div className="admHint">{cat !== "all" || q ? tr("Keine Einträge zu diesem Filter.") : tr("Noch keine Einträge.")}</div> : null}
                    {days.map((g) => (
                        <div key={g.day} className="admDay">
                            <h3 className="admDayHead">
                                📅 {g.day} <small>({g.items.length})</small>
                            </h3>
                            <ul className="admAudit">
                                {g.items.map((a) => {
                                    const entries = a.details && typeof a.details === "object" ? Object.entries(a.details).filter(([, v]) => v !== undefined) : [];
                                    return (
                                        <li key={a.id}>
                                            <span className="admTime" title={fmt(a.createdAt)}>
                                                {timeOf(a.createdAt)}
                                            </span>{" "}
                                            <b>{tr(ACTION_LABEL[a.action] ?? a.action)}</b> {a.targetLabel ? <>· {a.targetLabel}</> : null}{" "}
                                            <small>{tr("von {name}", { name: a.actorName ?? tr("System / Datenbank") })}</small>
                                            {entries.length ? (
                                                <div className="admDetails">
                                                    {entries.map(([k, v]) => (
                                                        <span key={k} className="admChip">
                                                            {tr(DETAIL_LABEL[k] ?? k)}: <b>{detailText(v)}</b>
                                                        </span>
                                                    ))}
                                                </div>
                                            ) : null}
                                        </li>
                                    );
                                })}
                            </ul>
                        </div>
                    ))}
                    {hasMore ? (
                        <button
                            type="button"
                            className="btn btnSecondary btnSmall"
                            disabled={loading}
                            onClick={() => {
                                setLoading(true);
                                setLimit((l) => Math.min(l + 500, 2000));
                            }}
                        >
                            {loading ? tr("Lade…") : tr("Mehr laden ({n} weitere)", { n: page.total - page.rows.length })}
                        </button>
                    ) : null}
                </>
            )}
        </div>
    );
}

const STYLES = `
.adm{ display:grid; gap:14px; }
.admHead{ display:flex; justify-content:space-between; align-items:flex-start; gap:10px; flex-wrap:wrap; }
.admTitle{ font-size: clamp(28px,6vw,40px) !important; margin:0; }
.admRole{ font-size:13px; opacity:.85; font-weight:700; margin-top:2px; }
.admTabs{ display:flex; gap:6px; flex-wrap:wrap; }
.admTabs button{ border:1px solid rgba(255,255,255,.25); background: rgba(255,255,255,.06); color:#fff; border-radius:999px; padding:7px 12px; font-weight:800; font-size:13px; cursor:pointer; }
.admTabs button.on{ background:#ffd23f; color:#2b0f04; border-color:#ffd23f; }
.admBox{ display:grid; gap:12px; padding:16px; border-radius:18px; background: rgba(0,0,0,.2); border:1px solid rgba(255,255,255,.14); min-width:0; }
.admTiles{ display:grid; grid-template-columns: repeat(auto-fit, minmax(130px,1fr)); gap:10px; }
.admTile{ padding:12px; border-radius:16px; background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.14); text-align:center; color:#fff; font:inherit; }
button.admTile{ cursor:pointer; }
button.admTile:hover{ background: rgba(255,255,255,.14); }
.admTileVal{ font-size:24px; font-weight:800; font-family: var(--font-display); color:#ffe08a; }
.admTileVal.warn{ color:#ff9b8a; }
.admTileLabel{ font-size:11px; font-weight:800; letter-spacing:.6px; text-transform:uppercase; opacity:.75; }
.admTileSub{ font-size:11px; opacity:.7; margin-top:2px; }
.admHint{ font-size:13px; opacity:.85; line-height:1.45; margin:0; }
.admSmall{ font-size:12px; opacity:.78; }
.admRow{ display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
.admRow .input{ flex:1 1 220px; min-width:0; }
.admSelect{ background: rgba(0,0,0,.3); color:#fff; border:1px solid rgba(255,255,255,.25); border-radius:12px; padding:9px 10px; font-weight:700; }
.admList{ list-style:none; margin:0; padding:0; display:grid; gap:8px; }
.admUser{ width:100%; display:grid; grid-template-columns: 38px 1fr auto; gap:10px; align-items:center; text-align:left; padding:10px 12px; border-radius:14px; background: rgba(255,255,255,.07); border:1px solid transparent; color:#fff; cursor:pointer; font:inherit; }
.admUser:hover{ background: rgba(255,255,255,.13); }
.admUserMain{ display:grid; min-width:0; }
.admUserMain b, .admUserMain small{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.admUserMain b small{ font-weight:600; opacity:.7; }
.admUserMain > small{ opacity:.75; }
.admUserMeta{ display:grid; justify-items:end; gap:3px; font-size:12px; }
.admUserMeta small{ opacity:.75; }
.admBadge{ display:inline-block; font-size:11px; font-weight:800; padding:2px 8px; border-radius:999px; background: rgba(255,255,255,.16); margin-left:4px; }
.admBadge.warn{ background: rgba(248,113,113,.3); }
.admBadge.staff{ background: rgba(255,210,63,.3); }
.admNote{ padding:10px 12px; border-radius:12px; font-weight:700; font-size:14px; }
.admNote.ok{ background: rgba(60,200,110,.18); border:1px solid rgba(110,230,150,.45); }
.admNote.err{ background: rgba(248,113,113,.18); border:1px solid rgba(248,113,113,.5); }
.admGroup{ display:grid; gap:8px; padding:12px; border-radius:14px; background: rgba(255,255,255,.05); border:1px solid rgba(255,255,255,.1); }
.admGroup h3{ margin:0; font-size:15px; }
.admDangerBox{ border-color: rgba(248,113,113,.5); background: rgba(248,113,113,.07); }
.admDanger{ background:#e63946 !important; color:#fff !important; border-color:#e63946 !important; }
.admBack{ justify-self:start; border:0; background:none; color:#fff; font-weight:800; cursor:pointer; text-decoration:underline; text-underline-offset:3px; padding:0; }
.admH2{ margin:0; font-size:20px; overflow-wrap:anywhere; }
.admH2 small{ font-size:14px; opacity:.7; font-weight:600; }
.admAudit{ list-style:none; margin:0; padding:0; display:grid; gap:6px; font-size:13px; }
.admAudit li{ padding:8px 10px; border-radius:10px; background: rgba(255,255,255,.06); }
.admTime{ font-variant-numeric: tabular-nums; font-weight:800; opacity:.9 !important; }
.admDay{ display:grid; gap:6px; }
.admDayHead{ margin:8px 0 0; font-size:14px; font-weight:900; letter-spacing:.2px; }
.admDayHead small{ opacity:.65; font-weight:700; }
.admDetails{ display:flex; flex-wrap:wrap; gap:4px 6px; margin-top:5px; }
.admChip{ font-size:11.5px; padding:2px 8px; border-radius:999px; background: rgba(255,255,255,.1); max-width:100%; overflow-wrap:anywhere; }
.admAudit span{ opacity:.7; margin-right:4px; }
.admAudit small{ opacity:.75; }
.admLobby{ display:flex; justify-content:space-between; gap:10px; align-items:center; flex-wrap:wrap; padding:10px 12px; border-radius:14px; background: rgba(255,255,255,.07); }
.admCode{ font-family: var(--font-display); font-size:18px; letter-spacing:2px; }
.admSong{ display:flex; justify-content:space-between; gap:10px; align-items:center; padding:9px 12px; border-radius:12px; background: rgba(255,255,255,.07); }
.admSong.archived{ opacity:.65; }
.admSong b{ font-size:14px; }
.admWeak{ color:#ff9b8a; font-weight:800; }
@media (max-width:560px){ .admUser{ grid-template-columns: 38px 1fr; } .admUserMeta{ grid-column: 2; justify-items:start; } }
`;
