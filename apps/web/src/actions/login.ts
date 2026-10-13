"use server";

import { tk } from "@/lib/i18nMark";
import { createSupabaseServerClient } from "@/lib/supabaseServer";
import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";

export type LoginResult = { ok: true } | { ok: false; error: string; code?: "not_confirmed" };

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}

/**
 * Löst den Login-Identifier (E-Mail oder Benutzername) serverseitig zur E-Mail auf.
 * Die E-Mail eines fremden Users wird dabei NIE an den Browser zurückgegeben --
 * get_email_for_username ist seit Migration 017 nur für den service_role aufrufbar.
 */
async function resolveEmail(identifier: string): Promise<{ ok: true; email: string } | { ok: false; error: string }> {
    const idValue = identifier.trim();
    if (!idValue) return { ok: false, error: tk("Bitte E-Mail oder Benutzername eingeben.") };
    if (isEmailLike(idValue)) return { ok: true, email: idValue.toLowerCase() };

    if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
        return { ok: false, error: tk("Anmelden mit Benutzername ist gerade nicht verfügbar. Bitte mit E-Mail anmelden.") };
    }
    const admin = createSupabaseAdminClient();
    const { data, error } = await admin.rpc("get_email_for_username", { p_username: idValue });
    if (error) return { ok: false, error: tk("Benutzername konnte nicht geprüft werden. Bitte erneut versuchen.") };
    // Bewusst dieselbe Meldung wie bei falschem Passwort: verrät nicht, welche Benutzernamen existieren.
    if (!data) return { ok: false, error: tk("Benutzername/E-Mail oder Passwort falsch.") };
    return { ok: true, email: String(data) };
}

function friendlyAuthError(raw: string | undefined): string {
    const msg = (raw ?? "").toLowerCase();
    if (msg.includes("invalid login") || msg.includes("invalid credentials")) return tk("Benutzername/E-Mail oder Passwort falsch.");
    if (msg.includes("banned")) return tk("Dieses Konto ist gesperrt oder zur Löschung beantragt. Wende dich an einen Admin, wenn das ein Irrtum ist.");
    if (msg.includes("email rate limit")) return tk("Der Mail-Dienst hat gerade sein Stundenlimit für Bestätigungsmails erreicht. Bitte in etwa einer Stunde erneut versuchen.");
    if (msg.includes("rate limit") || msg.includes("too many") || msg.includes("seconds")) return tk("Zu viele Versuche. Bitte kurz warten und dann erneut versuchen.");
    if (msg.includes("fetch") || msg.includes("network")) return tk("Keine Verbindung zum Server. Bitte erneut versuchen.");
    return raw || tk("Anmelden fehlgeschlagen.");
}

export async function loginWithIdentifier(identifier: string, password: string): Promise<LoginResult> {
    if (!password) return { ok: false, error: tk("Bitte dein Passwort eingeben.") };

    const resolved = await resolveEmail(identifier);
    if (!resolved.ok) return resolved;

    const supabase = await createSupabaseServerClient();
    const { error: loginErr } = await supabase.auth.signInWithPassword({ email: resolved.email, password });

    if (loginErr) {
        const msg = loginErr.message?.toLowerCase() ?? "";
        if (msg.includes("email not confirmed")) {
            return { ok: false, code: "not_confirmed", error: tk("Deine E-Mail ist noch nicht bestätigt. Schau in dein Postfach (auch im Spam-Ordner).") };
        }
        return { ok: false, error: friendlyAuthError(loginErr.message) };
    }

    return { ok: true };
}

/** Bestätigungsmail erneut senden (E-Mail oder Benutzername). */
export async function resendConfirmation(identifier: string, origin: string): Promise<{ ok: boolean; message: string }> {
    const resolved = await resolveEmail(identifier);
    // Unbekannter Name: trotzdem neutrale Antwort (keine Auskunft, ob ein Konto existiert)
    if (!resolved.ok) return { ok: true, message: tk("📨 Falls es dazu ein unbestätigtes Konto gibt, ist eine neue Bestätigungsmail unterwegs.") };

    // Nur eigene Herkunft zulassen (Supabase prüft die Weiterleitungs-Liste zusätzlich)
    const base = /^https?:\/\/[^/]+$/.test(origin) ? origin : process.env.NEXT_PUBLIC_APP_URL || "";
    const supabase = await createSupabaseServerClient();
    const { error } = await supabase.auth.resend({
        type: "signup",
        email: resolved.email,
        options: base ? { emailRedirectTo: `${base}/auth/callback?next=${encodeURIComponent("/")}` } : undefined,
    });
    if (error) return { ok: false, message: friendlyAuthError(error.message) };
    return { ok: true, message: tk("📨 Neue Bestätigungsmail ist unterwegs. Klick den Link darin, dann kannst du dich anmelden.") };
}
