import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

export async function createSupabaseServerClient() {
    const cookieStore = await cookies();

    return createServerClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
            cookies: {
                getAll() {
                    return cookieStore.getAll();
                },
                setAll(cookiesToSet) {
                    // In Server Components sind Cookies oft readonly -> set kann fehlschlagen.
                    // Middleware/Route Handlers übernehmen das Setzen zuverlässig.
                    try {
                        cookiesToSet.forEach((c) => (cookieStore as any).set?.(c.name, c.value, c.options));
                    } catch {
                        // noop
                    }
                },
            },
        }
    );
}