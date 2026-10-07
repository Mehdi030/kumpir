"use server";

import { randomUUID } from "node:crypto";
import { headers } from "next/headers";
import { createSupabaseServerClient } from "@/lib/supabaseServer";
import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";
import { validateUsername, PLACEHOLDER_EMAIL_DOMAIN } from "@/lib/accountSettings";

export type RegisterResult = { ok: true } | { ok: false; error: string; field?: "username" | "password" };

async function clientIp(): Promise<string> {
    const h = await headers();
    return (h.get("x-forwarded-for") ?? "").split(",")[0].trim() || h.get("x-real-ip") || "";
}

/**
 * Konto nur mit Benutzername + Passwort (keine E-Mail, keine Bestätigungsmail).
 * Der Server legt das Konto direkt bestätigt an (interne Platzhalter-Adresse, die nie angezeigt wird)
 * und meldet den Nutzer gleich an (Session-Cookies). Bremse: 5 Konten pro IP und Stunde (Migration 089).
 */
export async function registerAccount(usernameRaw: string, password: string): Promise<RegisterResult> {
    const v = validateUsername(usernameRaw ?? "");
    if (!v.ok) return { ok: false, field: "username", error: `Benutzername: ${v.message}` };
    const username = v.value;
    if (!password || password.length < 8) return { ok: false, field: "password", error: "Passwort muss mindestens 8 Zeichen haben." };
    if (password.length > 72) return { ok: false, field: "password", error: "Passwort ist zu lang (höchstens 72 Zeichen)." };
    if (!process.env.SUPABASE_SERVICE_ROLE_KEY) return { ok: false, error: "Registrieren ist gerade nicht verfügbar." };

    const admin = createSupabaseAdminClient();

    const guard = await admin.rpc("register_guard", { p_ip: await clientIp() });
    if (guard.error) {
        return guard.error.message.includes("rate_limited")
            ? { ok: false, error: "Von diesem Anschluss wurden gerade viele Konten erstellt. Bitte in einer Stunde erneut versuchen." }
            : { ok: false, error: "Registrieren hat gerade nicht geklappt. Bitte erneut versuchen." };
    }

    const avail = await admin.rpc("is_username_available", { p_username: username });
    if (avail.error) return { ok: false, error: "Benutzername konnte nicht geprüft werden. Bitte erneut versuchen." };
    if (!avail.data) return { ok: false, field: "username", error: "Benutzername ist schon vergeben oder nicht erlaubt." };

    const email = `${randomUUID()}@${PLACEHOLDER_EMAIL_DOMAIN}`;
    const created = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { username } });
    if (created.error || !created.data.user) {
        const m = (created.error?.message ?? "").toLowerCase();
        if (m.includes("password")) return { ok: false, field: "password", error: "Das Passwort ist zu schwach. Bitte ein längeres wählen." };
        return { ok: false, error: "Konto konnte nicht erstellt werden. Bitte erneut versuchen." };
    }

    // Hat jemand den Namen in derselben Sekunde genommen, vergibt die Datenbank einen anderen -> dann abbrechen
    const prof = await admin.from("profiles").select("username").eq("id", created.data.user.id).maybeSingle();
    if ((prof.data?.username ?? "").toLowerCase() !== username) {
        await admin.auth.admin.deleteUser(created.data.user.id);
        return { ok: false, field: "username", error: "Benutzername wurde gerade vergeben. Bitte einen anderen wählen." };
    }

    const supabase = await createSupabaseServerClient();
    const login = await supabase.auth.signInWithPassword({ email, password });
    if (login.error) return { ok: false, error: "Konto ist erstellt, aber das Anmelden hat nicht geklappt. Bitte jetzt mit Benutzername und Passwort anmelden." };
    return { ok: true };
}

/** Admin setzt ein neues Passwort für ein Konto (für Konten ohne E-Mail der einzige Weg, ein vergessenes Passwort zu ersetzen). */
export async function adminSetPassword(userId: string, password: string): Promise<{ ok: true } | { ok: false; error: string }> {
    if (!password || password.length < 8) return { ok: false, error: "Passwort muss mindestens 8 Zeichen haben." };
    if (password.length > 72) return { ok: false, error: "Passwort ist zu lang (höchstens 72 Zeichen)." };
    const supabase = await createSupabaseServerClient();
    const { data: me } = await supabase.auth.getUser();
    if (!me.user) return { ok: false, error: "Bitte erst anmelden." };
    const admin = createSupabaseAdminClient();
    const { data: prof } = await admin.from("profiles").select("role,status").eq("id", me.user.id).maybeSingle();
    if (prof?.role !== "admin" || prof?.status !== "active") return { ok: false, error: "Dafür fehlen dir die Rechte." };
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) return { ok: false, error: "Passwort konnte nicht gesetzt werden." };
    return { ok: true };
}
