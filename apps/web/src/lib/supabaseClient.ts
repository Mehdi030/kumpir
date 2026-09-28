"use client";

import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { SESSION_HEADER, getSessionToken } from "@/lib/playerSession";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

let browserClient: SupabaseClient | null = null;

/**
 * Hängt das Session-Token an jeden Request. Bewusst hier und nicht als
 * statischer `global.headers`-Eintrag: das Token entsteht erst beim
 * ersten Zugriff und darf sich (nach Kick/Verlassen) ändern, ohne dass
 * der Client neu gebaut werden muss.
 */
const fetchWithSession: typeof fetch = (input, init) => {
    const headers = new Headers(init?.headers);
    const token = getSessionToken();
    if (token) headers.set(SESSION_HEADER, token);
    return fetch(input, { ...init, headers });
};

export function getSupabaseClient(): SupabaseClient {
    if (!browserClient) {
        browserClient = createBrowserClient(url, anon, {
            global: { fetch: fetchWithSession },
        });
    }
    return browserClient;
}
