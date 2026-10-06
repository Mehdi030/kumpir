import { NextResponse } from "next/server";

/**
 * Kleiner Status-Check (verrät nur ja/nein, keine Werte):
 * usernameLogin = Server-Schlüssel für "Anmelden mit Benutzername" ist gesetzt,
 * loginEnabled  = Login ist nicht per NEXT_PUBLIC_GUEST_ONLY abgeschaltet.
 */
export const dynamic = "force-dynamic";

export function GET() {
    return NextResponse.json({
        ok: true,
        loginEnabled: process.env.NEXT_PUBLIC_GUEST_ONLY !== "1",
        usernameLogin: !!process.env.SUPABASE_SERVICE_ROLE_KEY,
        appUrl: !!process.env.NEXT_PUBLIC_APP_URL,
    });
}
