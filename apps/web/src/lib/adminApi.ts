"use client";

import { getSupabaseClient } from "@/lib/supabaseClient";
import { tk, trNow } from "@/lib/i18n";

/** Admin-Panel (Migration 078). Jede Funktion prüft Rolle + Rechte in der Datenbank. */

export type AdminRole = "admin" | "supporter";
export type UserStatus = "active" | "suspended" | "deletion_requested";

export type AdminUserRow = {
    id: string;
    username: string | null;
    displayName: string | null;
    avatarEmoji: string | null;
    avatarColor: string | null;
    role: "user" | "supporter" | "admin";
    status: UserStatus;
    statusReason: string | null;
    deletionRequestedAt: string | null;
    email: string | null;
    createdAt: string;
    lastSignInAt: string | null;
    confirmed: boolean;
    matches: number;
};

export type AdminUserDetail = AdminUserRow & {
    bannedUntil: string | null;
    statusChangedAt: string | null;
    stats: { matches: number; matchWins: number; rounds: number; titles: number; achievements: number; lastPlayed: string | null };
    audit: { created_at: string; actor_name: string | null; action: string; details: Record<string, unknown> | null }[];
};

export type AdminOverview = {
    role: AdminRole;
    counts: { users: number; deletionRequests: number; suspended: number; staff: number; activeLobbies: number; runningGames: number; newUsers7d: number };
};

export type AdminLobby = {
    id: string;
    code: string;
    phase: string;
    locked: boolean;
    createdAt: string;
    lastActivityAt: string;
    roundIndex: number | null;
    roundsTotal: number | null;
    playlist: string | null;
    host: string | null;
    humans: number;
    bots: number;
    accounts: number;
};

export type AdminSong = {
    id: string;
    title: string;
    artist: string;
    playlist: string;
    archivedFrom: string | null;
    plays: number;
    hits: number;
    rate: number | null;
};

export type OnlinePlayer = {
    playerId: string;
    name: string;
    lobbyId: string;
    lobbyCode: string;
    phase: string;
    isHost: boolean;
    userId: string | null;
    username: string | null;
    role: "user" | "supporter" | "admin" | null;
    accountStatus: UserStatus | null;
    lastSeen: string;
};

/** Ein abgeschlossenes Match eines Kontos (Schnellmenü > Verlauf) */
export type AdminMatchRow = {
    finishedAt: string;
    lobbyCode: string | null;
    place: number | null;
    players: number | null;
    humans: number | null;
    points: number | null;
    titles: number | null;
    artists: number | null;
    wrong: number | null;
    rounds: number | null;
    ranked: boolean;
    playlists: string[] | null;
};

export type AuditPage = { total: number; rows: AuditEntry[] };

export type AuditEntry = {
    id: number;
    createdAt: string;
    actorName: string | null;
    action: string;
    targetId: string | null;
    targetLabel: string | null;
    details: Record<string, unknown> | null;
};

type R<T> = Promise<{ data?: T; error?: string }>;

export type AdminApi = {
    overview: () => R<AdminOverview>;
    listUsers: (search: string, filter: "all" | "deletion" | "suspended" | "staff") => R<AdminUserRow[]>;
    getUser: (id: string) => R<AdminUserDetail>;
    setStatus: (id: string, status: "active" | "suspended", reason?: string) => R<null>;
    deleteUser: (id: string) => R<null>;
    setRole: (id: string, role: "user" | "supporter" | "admin") => R<null>;
    moderate: (id: string, opts: { username?: string; resetDisplayName?: boolean; resetAvatar?: boolean }) => R<null>;
    sendPasswordReset: (id: string) => R<string>;
    listLobbies: () => R<AdminLobby[]>;
    closeLobby: (id: string) => R<null>;
    listSongs: (playlist: string | null, search: string) => R<AdminSong[]>;
    setSongArchived: (id: string, archived: boolean) => R<null>;
    listAudit: (limit?: number) => R<AuditPage>;
    onlinePlayers: () => R<OnlinePlayer[]>;
    kickPlayer: (lobbyId: string, playerId: string) => R<null>;
    userHistory: (userId: string) => R<{ matches: AdminMatchRow[] }>;
};

export function supabaseAdminApi(): AdminApi {
    const sb = getSupabaseClient();
    const call = async <T>(fn: string, args?: Record<string, unknown>): R<T> => {
        const { data, error } = await sb.rpc(fn, args ?? {});
        return error ? { error: error.message } : { data: (data ?? null) as T };
    };
    return {
        overview: () => call("admin_whoami"),
        listUsers: (search, filter) => call("admin_list_users", { p_search: search || null, p_filter: filter, p_limit: 100, p_offset: 0 }),
        getUser: (id) => call("admin_get_user", { p_user_id: id }),
        setStatus: (id, status, reason) => call("admin_set_user_status", { p_user_id: id, p_status: status, p_reason: reason || null }),
        deleteUser: (id) => call("admin_delete_user", { p_user_id: id }),
        setRole: (id, role) => call("admin_set_role", { p_user_id: id, p_role: role }),
        moderate: (id, o) =>
            call("admin_update_user_profile", {
                p_user_id: id,
                p_username: o.username || null,
                p_reset_display_name: !!o.resetDisplayName,
                p_reset_avatar: !!o.resetAvatar,
            }),
        async sendPasswordReset(id) {
            const r = await call<string>("admin_log_password_reset", { p_user_id: id });
            if (r.error || !r.data) return r;
            const { error } = await sb.auth.resetPasswordForEmail(r.data, {
                redirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent("/auth/reset")}`,
            });
            return error ? { error: error.message } : { data: r.data };
        },
        listLobbies: () => call("admin_list_lobbies"),
        closeLobby: (id) => call("admin_close_lobby", { p_lobby_id: id }),
        listSongs: (playlist, search) => call("admin_list_songs", { p_playlist: playlist, p_search: search || null }),
        setSongArchived: (id, archived) => call("admin_set_song_archived", { p_song_id: id, p_archived: archived }),
        listAudit: (limit = 300) => call("admin_list_audit", { p_limit: limit }),
        onlinePlayers: () => call("admin_online_players"),
        kickPlayer: (lobbyId, playerId) => call("admin_kick_player", { p_lobby_id: lobbyId, p_player_id: playerId }),
        userHistory: (userId) => call("admin_user_history", { p_user_id: userId }),
    };
}

/** Fehlercodes aus den Admin-Funktionen -> verständlicher Text */
export function adminErrorText(e: string | undefined): string {
    const m = e ?? "";
    if (m.includes("not_authorized")) return trNow("Dafür fehlen dir die Rechte.");
    if (m.includes("not_on_self")) return trNow("Das geht nicht mit dem eigenen Konto.");
    if (m.includes("staff_cannot_be_deleted")) return trNow("Team-Konten (Admin/Supporter) können nicht gelöscht werden – erst Rolle auf „Nutzer“ setzen.");
    if (m.includes("username_taken")) return trNow("Dieser Benutzername ist schon vergeben.");
    if (m.includes("username_invalid")) return trNow("Benutzername: 3–20 Zeichen, nur a–z, 0–9, Punkt, Unterstrich, Minus.");
    if (m.includes("user_not_found")) return trNow("Nutzer nicht gefunden (evtl. schon gelöscht).");
    if (m.includes("lobby_not_found")) return trNow("Lobby gibt es nicht mehr.");
    if (m.includes("player_not_found")) return trNow("Spieler ist nicht mehr in der Lobby.");
    if (m.includes("rate") || m.includes("seconds")) return trNow("Bitte kurz warten und erneut versuchen.");
    return m || trNow("Das hat nicht geklappt.");
}

export const ACTION_LABEL: Record<string, string> = {
    suspended: tk("⛔ gesperrt"),
    unsuspended: tk("✅ entsperrt"),
    deletion_requested: tk("🗑️ Löschung beantragt"),
    deletion_rejected: tk("↩️ Löschantrag abgelehnt"),
    deleted: tk("❌ endgültig gelöscht"),
    role_changed: tk("🛡️ Rolle geändert"),
    profile_moderated: tk("✏️ Profil bearbeitet"),
    password_reset_sent: tk("🔑 Passwort-Reset gesendet"),
    lobby_closed: tk("🚪 Lobby geschlossen"),
    player_kicked: tk("👢 Spieler gekickt"),
    song_archived: tk("📦 Song archiviert"),
    song_restored: tk("♻️ Song zurückgeholt"),
    account_created: tk("🆕 Konto angelegt"),
    account_deleted: tk("❌ Konto gelöscht (per Skript)"),
    username_changed: tk("✏️ Benutzername geändert"),
    display_name_changed: tk("✏️ Spielername geändert"),
    avatar_changed: tk("🙂 Avatar geändert"),
    preferences_changed: tk("⚙️ Einstellungen geändert"),
    email_changed: tk("📧 E-Mail geändert"),
    password_changed: tk("🔐 Passwort geändert"),
    status_changed: tk("🚦 Status geändert"),
    platform_admin_changed: tk("🛡️ Plattform-Admin geändert"),
    songs_added: tk("➕ Songs hinzugefügt"),
    songs_removed: tk("➖ Songs entfernt"),
    songs_changed: tk("🎵 Songs geändert"),
    playlist_changed: tk("📀 Playlist geändert"),
    lobbies_expired: tk("🧹 Lobbys automatisch geschlossen"),
};

export type AuditCategory = "all" | "account" | "profile" | "access" | "songs" | "lobbies";
export const AUDIT_CATEGORY_LABEL: Record<AuditCategory, string> = {
    all: tk("Alle"),
    account: tk("Konten"),
    profile: tk("Profil & Einstellungen"),
    access: tk("Rollen & Sperren"),
    songs: tk("Songs & Playlists"),
    lobbies: tk("Lobbys"),
};
const CATEGORY_OF: Record<string, AuditCategory> = {
    account_created: "account", account_deleted: "account", deleted: "account", deletion_requested: "account", deletion_rejected: "account",
    email_changed: "account", password_changed: "account", password_reset_sent: "account",
    username_changed: "profile", display_name_changed: "profile", avatar_changed: "profile", preferences_changed: "profile", profile_moderated: "profile",
    suspended: "access", unsuspended: "access", role_changed: "access", status_changed: "access", platform_admin_changed: "access",
    song_archived: "songs", song_restored: "songs", songs_added: "songs", songs_removed: "songs", songs_changed: "songs", playlist_changed: "songs",
    lobby_closed: "lobbies", lobbies_expired: "lobbies", player_kicked: "lobbies",
};
export const auditCategory = (action: string): AuditCategory => CATEGORY_OF[action] ?? "all";
