import { createClient, SupabaseClient } from "@supabase/supabase-js";

export function getSupabaseClient(): SupabaseClient {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

    if (!supabaseUrl || !supabaseAnonKey) {
        throw new Error("Supabase env vars missing at runtime");
    }

    return createClient(supabaseUrl, supabaseAnonKey);
}
