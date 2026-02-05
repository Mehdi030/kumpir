import { createBrowserClient } from "@supabase/ssr";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!url) throw new Error("Missing env: NEXT_PUBLIC_SUPABASE_URL");
if (!anon) throw new Error("Missing env: NEXT_PUBLIC_SUPABASE_ANON_KEY");

// Optional: schneller sanity check (anon keys sind i.d.R. sehr lang)
if (anon.length < 50) throw new Error("NEXT_PUBLIC_SUPABASE_ANON_KEY looks too short");

let browserClient: ReturnType<typeof createBrowserClient> | null = null;

export function getSupabaseClient() {
    if (!browserClient) {
        browserClient = createBrowserClient(url, anon);
    }
    return browserClient;
}
