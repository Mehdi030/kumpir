"use client";

import { useEffect } from "react";
import { useAuth } from "@/components/AuthProvider";
import { getSupabaseClient } from "@/lib/supabaseClient";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";
const PING_MS = 60000;

/** Meldet angemeldete Konten jede Minute als "online" (für die Freundesliste). Unsichtbar. */
export function PresencePing() {
    const { user } = useAuth();
    const userId = user?.id ?? null;

    useEffect(() => {
        if (!userId || GUEST_ONLY) return;
        const sb = getSupabaseClient();
        const ping = () => {
            if (document.visibilityState === "hidden") return;
            void sb.rpc("touch_presence");
        };
        ping();
        const t = window.setInterval(ping, PING_MS);
        document.addEventListener("visibilitychange", ping);
        return () => {
            window.clearInterval(t);
            document.removeEventListener("visibilitychange", ping);
        };
    }, [userId]);

    return null;
}
