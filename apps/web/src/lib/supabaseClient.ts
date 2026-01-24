// @/lib/supabaseClient.ts
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

let client: SupabaseClient | null = null;

export function getSupabaseClient(): SupabaseClient {
    if (client) return client;

    if (!supabaseUrl || !supabaseAnonKey) {
        // kein throw beim Build – aber klarer Hinweis im Log
        console.warn("Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY");
        // Dummy-Client vermeiden -> lieber hart fail NUR im Browser zur Laufzeit
        if (typeof window !== "undefined") {
            throw new Error("Supabase env vars missing in runtime.");
        }
        // Auf Server/Build: gib einen Client mit leeren Werten NICHT zurück
        // → hier bewusst Error vermeiden, weil Seite ggf. client-only ist
    }

    client = createClient(supabaseUrl ?? "", supabaseAnonKey ?? "");
    return client;
}

// Bequemlichkeit: bestehende Imports weiter nutzbar
export const supabase = getSupabaseClient();
