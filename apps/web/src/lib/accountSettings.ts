/** Konto-Einstellungen (Migration 077). Die Datenbank prüft alles noch einmal. */

export type Preferences = {
    lang?: "de" | "en";
    muted?: boolean;
    volume?: number;
    host?: {
        maxPlayers?: number;
        /** Rausgenommene Playlists (neue Playlists sind automatisch dabei). */
        excludedPlaylists?: string[];
        speed?: "fast" | "normal" | "calm";
        rounds?: 1 | 3 | 5;
        answerMode?: "text" | "voice";
    };
    solo?: {
        bots?: number;
        skill?: "mixed" | "1" | "2" | "3";
    };
};

export type StaffRole = "user" | "supporter" | "admin";
export type AccountStatus = "active" | "suspended" | "deletion_requested";

export type AccountSettings = {
    role: StaffRole;
    status: AccountStatus;
    username: string | null;
    displayName: string | null;
    avatarEmoji: string | null;
    avatarColor: string | null;
    preferences: Preferences;
};

export const AVATAR_EMOJIS = ["🥔", "🔥", "🎧", "🎤", "🎸", "🥁", "🎹", "🎷", "🦊", "🐼", "🐯", "🦁", "🐸", "🐙", "🦄", "🐝", "👑", "😎", "🤖", "👻", "⚡", "🌶️", "🍕", "🌈"];

export const AVATAR_COLORS = ["#ffb21a", "#ff6b35", "#e63946", "#d6336c", "#9b5de5", "#4361ee", "#00b4d8", "#2a9d8f", "#57cc99", "#8d6e63"];

export const DEFAULT_AVATAR = { emoji: "", color: "#ffb21a" };

/** Konten ohne E-Mail (Migration 089) haben intern diese Platzhalter-Adresse -- nie anzeigen. */
export const PLACEHOLDER_EMAIL_DOMAIN = "konto.kumpir.invalid";
export function isPlaceholderEmail(email: string | null | undefined): boolean {
    return !!email && email.toLowerCase().endsWith("@" + PLACEHOLDER_EMAIL_DOMAIN);
}
/** E-Mail für die Anzeige (Konten ohne E-Mail: "ohne E-Mail"). */
export function emailLabel(email: string | null | undefined): string {
    if (!email) return "–";
    return isPlaceholderEmail(email) ? "ohne E-Mail" : email;
}

export function validateUsername(raw: string): { ok: true; value: string } | { ok: false; message: string } {
    const v = raw.trim().toLowerCase();
    if (v.length < 3) return { ok: false, message: "Mindestens 3 Zeichen." };
    if (v.length > 20) return { ok: false, message: "Höchstens 20 Zeichen." };
    if (!/^[a-z0-9._-]+$/.test(v)) return { ok: false, message: "Nur a–z, 0–9, Punkt, Unterstrich, Minus." };
    return { ok: true, value: v };
}

/** Spielername wie beim Beitreten: nur Buchstaben (inkl. Umlaute), 2–12 Zeichen. */
export function sanitizeDisplayName(input: string): string {
    return input.replace(/[^A-Za-zÄÖÜäöüß]/g, "").slice(0, 12);
}

export function validateDisplayName(raw: string): { ok: true; value: string | null } | { ok: false; message: string } {
    const v = raw.trim();
    if (!v) return { ok: true, value: null };
    if (!/^[A-Za-zÄÖÜäöüß]{2,12}$/.test(v)) return { ok: false, message: "2–12 Buchstaben, keine Ziffern oder Leerzeichen." };
    return { ok: true, value: v };
}

/** Übersetzt Fehlercodes der Konto-RPCs in verständliche Texte. */
export function settingsErrorText(message: string | undefined | null): string {
    const m = message ?? "";
    if (m.includes("username_taken")) return "Dieser Benutzername ist schon vergeben.";
    if (m.includes("username_invalid")) return "Benutzername: 3–20 Zeichen, nur a–z, 0–9, Punkt, Unterstrich, Minus.";
    if (m.includes("username_profane") || m.includes("display_name_invalid")) return "Bitte einen anderen Namen wählen.";
    if (m.includes("avatar_invalid")) return "Dieser Avatar geht leider nicht.";
    if (m.includes("admin_cannot_delete")) return "Admin-Konten können keine Löschung beantragen.";
    if (m.includes("not_authorized")) return "Dafür fehlen dir die Rechte.";
    if (m.includes("not_logged_in") || m.includes("JWT")) return "Bitte melde dich erneut an.";
    return m || "Speichern hat nicht geklappt.";
}

/** Tiefe Zusammenführung für host/solo, damit Teil-Updates nichts überschreiben. */
export function mergePreferences(base: Preferences, patch: Preferences): Preferences {
    return {
        ...base,
        ...patch,
        host: { ...(base.host ?? {}), ...(patch.host ?? {}) },
        solo: { ...(base.solo ?? {}), ...(patch.solo ?? {}) },
    };
}

export const SOLO_SKILL_LABEL: Record<NonNullable<NonNullable<Preferences["solo"]>["skill"]>, string> = {
    mixed: "Gemischt",
    "1": "Anfänger",
    "2": "Mittel",
    "3": "Profi",
};
