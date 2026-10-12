import { createClient } from "@supabase/supabase-js";

export function createSupabaseAdminClient() {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY!.trim();
    return createClient(url, serviceKey, {
        auth: { persistSession: false, autoRefreshToken: false },
    });
}
