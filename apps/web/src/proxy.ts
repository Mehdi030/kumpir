import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

export function proxy(req: NextRequest) {
    if (!AUTH_DISABLED) return NextResponse.next();

    const p = req.nextUrl.pathname;

    if (
        p.startsWith("/login") ||
        p.startsWith("/register") ||
        p.startsWith("/verified") ||
        p.startsWith("/auth")
    ) {
        const url = req.nextUrl.clone();
        url.pathname = "/";
        url.search = "";
        return NextResponse.redirect(url);
    }

    return NextResponse.next();
}

export const config = { matcher: ["/:path*"] };