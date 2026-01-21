// @/lib/supabaseClient.ts
import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

// Nur im Browser hart failen (damit du es lokal sofort merkst),
// aber Build/SSR nicht sprengen.
if (typeof window !== "undefined") {
    if (!supabaseUrl || !supabaseAnonKey) {
        throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY");
    }
}

export const supabase = createClient(supabaseUrl ?? "", supabaseAnonKey ?? "");
