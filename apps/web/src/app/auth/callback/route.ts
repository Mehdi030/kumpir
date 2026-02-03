import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

function safeNextPath(v: string | null) {
    if (!v) return "/verified";
    if (!v.startsWith("/")) return "/verified";
    if (v.startsWith("//")) return "/verified";
    return v;
}

function buildRedirect(origin: string, path: string, params?: Record<string, string>) {
    const u = new URL(path, origin);
    if (params) {
        for (const [k, val] of Object.entries(params)) u.searchParams.set(k, val);
    }
    return NextResponse.redirect(u);
}

export async function GET(request: Request) {
    const url = new URL(request.url);
    const origin = url.origin;

    const debug = url.searchParams.get("debug") === "1";

    // Common Supabase callback params
    const code = url.searchParams.get("code");
    const next = safeNextPath(url.searchParams.get("next"));

    // Error params (OAuth + magic links)
    const error = url.searchParams.get("error");
    const errorDescription = url.searchParams.get("error_description");

    // Sometimes used in older/other flows:
    const type = url.searchParams.get("type"); // e.g. signup, recovery
    const tokenHash = url.searchParams.get("token_hash"); // magic-link verify style (if used)

    // Debug response (helps you see what Safari actually passes)
    if (debug) {
        return NextResponse.json({
            origin,
            next,
            code_present: Boolean(code),
            error,
            errorDescription,
            type,
            tokenHash_present: Boolean(tokenHash),
            full_query: Object.fromEntries(url.searchParams.entries()),
        });
    }

    const cookieStore = cookies();

    const supabase = createServerClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
            cookies: {
                get(name: string) {
                    return cookieStore.get(name)?.value;
                },
                set(name: string, value: string, options: { [key: string]: unknown }) {
                    cookieStore.set({ name, value, ...options });
                },
                remove(name: string, options: { [key: string]: unknown }) {
                    cookieStore.set({ name, value: "", ...options, maxAge: 0 });
                },
            },
        }
    );

    // 1) If Supabase sent an explicit error, route to login with details
    if (error) {
        return buildRedirect(origin, "/login", {
            m: "auth_error",
            next,
            error,
            ...(errorDescription ? { error_description: errorDescription } : {}),
        });
    }

    // 2) Normal OAuth / PKCE callback: exchange code for session
    if (code) {
        const { error: exErr } = await supabase.auth.exchangeCodeForSession(code);

        if (exErr) {
            // Safari often fails here if redirect URL not whitelisted or cookies blocked.
            // Provide an actionable fallback screen instead of Safari "cannot open page".
            return buildRedirect(origin, "/login", {
                m: "oauth_exchange_failed",
                next,
            });
        }

        // Extra safety: ensure we actually have a session after exchange
        const { data: sessionData } = await supabase.auth.getSession();

        if (!sessionData.session) {
            // If cookie write was blocked, redirect to a "verified" screen where the user can continue manually.
            // You already have /verified page.tsx, so let's use it.
            return buildRedirect(origin, "/verified", {
                next,
                m: "session_missing",
            });
        }

        return buildRedirect(origin, next);
    }

    // 3) If no code:
    // This can happen if the user opens a link that doesn't include `code` (or it's stripped).
    // For email confirmation flows, you can still send them to verified/login with messaging.
    if (type === "recovery") {
        // Password reset flow should land on your reset page
        return buildRedirect(origin, "/reset", { next });
    }

    // If token_hash is present but no code, you're likely using a different email verify style.
    // We can't complete it here without an explicit verify endpoint; route user to login/verified.
    if (tokenHash) {
        return buildRedirect(origin, "/verified", {
            next,
            m: "token_hash_received",
        });
    }

    // Default fallback
    return buildRedirect(origin, "/login", {
        m: "missing_code",
        next,
    });
}