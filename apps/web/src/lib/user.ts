import { getSupabaseClient } from "./supabaseClient";

export async function requireAuthUserId(): Promise<string> {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase.auth.getUser();
    if (error) throw new Error(error.message);
    if (!data.user?.id) throw new Error("Not authenticated");
    return data.user.id; // ✅ auth.users.id (uuid string)
}
