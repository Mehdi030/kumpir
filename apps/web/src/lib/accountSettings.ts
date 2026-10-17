/** Konto-Einstellungen (Migration 077). Die Datenbank prüft alles noch einmal. */
import { tk } from "@/lib/i18nMark";

export type Preferences = {
    lang?: "de" | "en" | "fr";
    muted?: boolean;
    volume?: number;
    host?: {
        maxPlayers?: number;
        /** Rausgenommene Playlists (neue Playlists sind automatisch dabei). */
        excludedPlaylists?: string[];
        speed?: "fast" | "normal" | "calm";
        rounds?: 1 | 3 | 5;
        answerMode?: "text" | "voice";
        /** zuletzt gewählter Modus (wird beim Erstellen gemerkt, Migration 122) */
        mode?: "original" | "buzzer" | "year" | "letters";
    };
    solo?: {
        bots?: number;
        skill?: "mixed" | "1" | "2" | "3";
        /** zuletzt gewählter Modus / Tempo gegen Bots (Migration 122) */
        mode?: "original" | "buzzer" | "year" | "letters";
        speed?: "fast" | "normal" | "calm";
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
    /** eigene Spielfigur (Migration 102), null = aus dem Namen */
    avatarConfig: Record<string, string> | null;
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
    if (!email) return tk("–");
    return isPlaceholderEmail(email) ? tk("ohne E-Mail") : email;
}

/**
 * Passwort-Regel von Supabase (Projekt-Einstellung): mind. 8 Zeichen, Klein- und Großbuchstaben und eine Zahl.
 * Gibt null zurück, wenn alles passt, sonst einen verständlichen Satz.
 */
export const PASSWORD_HINT = tk("mind. 8 Zeichen, mit Groß- und Kleinbuchstaben und einer Zahl");
export function passwordProblem(pw: string): string | null {
    if (!pw || pw.length < 8) return tk("Das Passwort braucht mindestens 8 Zeichen.");
    if (pw.length > 72) return tk("Das Passwort ist zu lang (höchstens 72 Zeichen).");
    if (!/[a-z]/.test(pw) || !/[A-Z]/.test(pw) || !/[0-9]/.test(pw)) return tk("Das Passwort braucht Groß- und Kleinbuchstaben und mindestens eine Zahl.");
    return null;
}

export function validateUsername(raw: string): { ok: true; value: string } | { ok: false; message: string } {
    const v = raw.trim().toLowerCase();
    if (v.length < 3) return { ok: false, message: tk("Mindestens 3 Zeichen.") };
    if (v.length > 20) return { ok: false, message: tk("Höchstens 20 Zeichen.") };
    if (!/^[a-z0-9._-]+$/.test(v)) return { ok: false, message: tk("Nur a–z, 0–9, Punkt, Unterstrich, Minus.") };
    return { ok: true, value: v };
}

/** Spielername wie beim Beitreten: nur Buchstaben (inkl. Umlaute), 2–12 Zeichen. */
export function sanitizeDisplayName(input: string): string {
    return input.replace(/[^A-Za-zÄÖÜäöüß]/g, "").slice(0, 12);
}

export function validateDisplayName(raw: string): { ok: true; value: string | null } | { ok: false; message: string } {
    const v = raw.trim();
    if (!v) return { ok: true, value: null };
    if (!/^[A-Za-zÄÖÜäöüß]{2,12}$/.test(v)) return { ok: false, message: tk("2–12 Buchstaben, keine Ziffern oder Leerzeichen.") };
    return { ok: true, value: v };
}

/** Übersetzt Fehlercodes der Konto-RPCs in verständliche Texte. */
export function settingsErrorText(message: string | undefined | null): string {
    const m = message ?? "";
    if (m.includes("username_taken")) return tk("Dieser Benutzername ist schon vergeben.");
    if (m.includes("username_invalid")) return tk("Benutzername: 3–20 Zeichen, nur a–z, 0–9, Punkt, Unterstrich, Minus.");
    if (m.includes("username_profane") || m.includes("display_name_invalid")) return tk("Bitte einen anderen Namen wählen.");
    if (m.includes("avatar_invalid")) return tk("Dieser Avatar geht leider nicht.");
    if (m.includes("admin_cannot_delete")) return tk("Admin-Konten können keine Löschung beantragen.");
    if (m.includes("not_authorized")) return tk("Dafür fehlen dir die Rechte.");
    if (m.includes("not_logged_in") || m.includes("JWT")) return tk("Bitte melde dich erneut an.");
    return m || tk("Speichern hat nicht geklappt.");
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
    mixed: tk("Gemischt"),
    "1": tk("Anfänger"),
    "2": tk("Mittel"),
    "3": tk("Profi"),
};
