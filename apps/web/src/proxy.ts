import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

const AUTH_ROUTES = ["/login", "/register", "/verified", "/auth"];

export function proxy(req: NextRequest) {
    if (!AUTH_DISABLED) return NextResponse.next();

    const p = req.nextUrl.pathname;
    const isAuthRoute = AUTH_ROUTES.some((route) => p.startsWith(route));

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
