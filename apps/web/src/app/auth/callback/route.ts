import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

export async function GET(request: Request) {
    const url = new URL(request.url);
    const code = url.searchParams.get("code");
    const next = url.searchParams.get("next") ?? "/";

    const cookieStore = await cookies();

    const supabase = createServerClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
            cookies: {
                get(name: string) {
                    return cookieStore.get(name)?.value;
                },
                set(name: string, value: string, options: any) {
                    cookieStore.set({ name, value, ...options });
                },
                remove(name: string, options: any) {
                    cookieStore.set({ name, value: "", ...options, maxAge: 0 });
                },
            },
        }
    );

    if (code) {
        const { error } = await supabase.auth.exchangeCodeForSession(code);
        if (error) {
            const errUrl = new URL("/login", url.origin);
            errUrl.searchParams.set("next", next);
            errUrl.searchParams.set("error", "oauth_exchange_failed");
            return NextResponse.redirect(errUrl);
        }
    }

    return NextResponse.redirect(new URL(next, url.origin));
}
