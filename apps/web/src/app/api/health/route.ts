import { NextResponse } from "next/server";

/**
 * Kleiner Status-Check (verrät nur ja/nein, keine Werte):
 * usernameLogin = Server-Schlüssel für "Anmelden mit Benutzername" ist gesetzt.
 */
export const dynamic = "force-dynamic";

export function GET() {
    return NextResponse.json({
        ok: true,
        usernameLogin: !!process.env.SUPABASE_SERVICE_ROLE_KEY,
        appUrl: !!process.env.NEXT_PUBLIC_APP_URL,
    });
}
