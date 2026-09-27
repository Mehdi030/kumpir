import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

/**
 * Auth-Modus (Etappe 3a, opt-in):
 *
 * - `NEXT_PUBLIC_AUTH_DISABLED=1` → strikter Gast-Modus: alle Auth-Routen
 *   leiten auf "/" um. Sinnvoll für Demos/lokales Testen ohne Supabase-Auth.
 * - sonst (Default) → Auth-Routen sind erreichbar, aber NICHT Pflicht.
 *   Gast-Modus bleibt voll funktional, eingeloggte User bekommen zusätzlich
 *   ihre user_id an die DB gehängt (für Lifetime-Stats etc).
 */
const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

const AUTH_ROUTES = ["/login", "/register", "/verified", "/auth"];

// Auth-only Features (Etappe 3): ohne Login nutzlos. Im Gast-Modus können
// Nutzer eh nie einloggen (siehe oben), also direkt auf "/" umleiten statt
// sie auf einer "Bitte einloggen"-Seite stranden zu lassen, deren Login-
// Button ohnehin wieder hierher umgeleitet würde.
const AUTH_ONLY_ROUTES = ["/achievements", "/leaderboard", "/friends"];

export function proxy(req: NextRequest) {
    if (!AUTH_DISABLED) return NextResponse.next();

    const p = req.nextUrl.pathname;
    const isAuthRoute = AUTH_ROUTES.some((route) => p.startsWith(route)) || AUTH_ONLY_ROUTES.some((route) => p.startsWith(route));

    if (isAuthRoute) {
        const url = req.nextUrl.clone();
        url.pathname = "/";
        url.search = "";
        return NextResponse.redirect(url);
    }

    return NextResponse.next();
}

export const config = {
    matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:png|svg|jpg|jpeg|gif|webp|webmanifest)$).*)"],
};
