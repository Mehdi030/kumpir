import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

const SESSION_HEADER = "x-kumpir-session";

/**
 * @param sessionToken Session-Token des handelnden Spielers. Server Actions
 * rufen RPCs in seinem Namen auf; seit Migration 023/024 prüfen die RPCs den
 * Header `x-kumpir-session`. Der Server reicht das Token also nur durch --
 * es stammt ohnehin vom selben Client und bringt keine zusätzlichen Rechte.
 */
export async function createSupabaseServerClient(sessionToken?: string | null) {
    const cookieStore = await cookies();

    return createServerClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
            global: sessionToken ? { headers: { [SESSION_HEADER]: sessionToken } } : undefined,
            cookies: {
                getAll() {
                    return cookieStore.getAll();
                },
                setAll(cookiesToSet) {
                    // In Server Actions kann cookieStore.set funktionieren, in manchen Contexts aber auch nicht.
                    // Middleware / Route Handlers sind die "sicherste" Stelle fürs Setzen.
                    try {
                        cookiesToSet.forEach(({ name, value, options }) => {
                            cookieStore.set(name, value, options);
                        });
                    } catch {
                        // noop
                    }
                },
            },
        }
    );
}
