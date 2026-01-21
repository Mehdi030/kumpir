import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY");
}

declare global {
    // eslint-disable-next-line no-var
    var __supabase: SupabaseClient | undefined;
}

export const supabase =
    globalThis.__supabase ?? createClient(supabaseUrl, supabaseAnonKey);

if (process.env.NODE_ENV !== "production") globalThis.__supabase = supabase;