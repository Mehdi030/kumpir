"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";
import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";

export type LoginResult = { ok: true } | { ok: false; error: string };

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}

/**
 * Löst den Login-Identifier (Email oder Username) serverseitig auf und
 * meldet an. Die Email eines fremden Users wird dabei NIE an den Browser
 * zurückgegeben -- get_email_for_username ist seit Migration 017 nur noch
 * für den service_role aufrufbar, genau damit dieser Lookup nicht mehr
 * roh übers Frontend-Bundle (Anon-Key) erreichbar ist.
 */
export async function loginWithIdentifier(identifier: string, password: string): Promise<LoginResult> {
    const idValue = identifier.trim();
    if (!idValue) return { ok: false, error: "Bitte E-Mail oder Username eingeben." };
    if (password.length < 8) return { ok: false, error: "Passwort muss mindestens 8 Zeichen haben." };

    let emailToUse = idValue;

    if (!isEmailLike(idValue)) {
        if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
            return {
                ok: false,
                error: "Username-Login ist serverseitig nicht konfiguriert. Bitte mit E-Mail einloggen.",
            };
        }

        const admin = createSupabaseAdminClient();
        const { data: emailRow, error: rpcErr } = await admin.rpc("get_email_for_username", {
            p_username: idValue,
        });

        if (rpcErr) return { ok: false, error: "Konnte Benutzernamen nicht prüfen. Bitte erneut versuchen." };
        if (!emailRow) return { ok: false, error: "Benutzername unbekannt." };
        emailToUse = String(emailRow);
    }

    const supabase = await createSupabaseServerClient();
    const { error: loginErr } = await supabase.auth.signInWithPassword({
        email: emailToUse,
        password,
    });

    if (loginErr) {
        const msg = loginErr.message?.toLowerCase() ?? "";
        if (msg.includes("email not confirmed")) {
            return { ok: false, error: "E-Mail noch nicht bestätigt. Bitte schau in dein Postfach." };
        }
        if (msg.includes("invalid")) {
            return { ok: false, error: "E-Mail oder Passwort falsch." };
        }
        return { ok: false, error: loginErr.message || "Login fehlgeschlagen." };
    }

    return { ok: true };
}
