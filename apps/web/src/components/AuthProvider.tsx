"use client";

import { createContext, useContext, useEffect, useMemo, useState } from "react";
import type { Session, User } from "@supabase/supabase-js";
import { getSupabaseClient } from "@/lib/supabaseClient";

type AuthCtx = {
    user: User | null;
    session: Session | null;
    loading: boolean;
};

const Ctx = createContext<AuthCtx>({ user: null, session: null, loading: true });

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

export function AuthProvider({ children }: { children: React.ReactNode }) {
    // Lazy-init: nur clientseitig den Supabase-Client erzeugen, sonst crashen
    // statisch generierte Pages beim Build (createBrowserClient ruft window-only API auf).
    const supabase = useMemo(() => {
        if (typeof window === "undefined") return null;
        return getSupabaseClient();
    }, []);

    const [session, setSession] = useState<Session | null>(null);
    const [user, setUser] = useState<User | null>(null);
    const [loading, setLoading] = useState(!AUTH_DISABLED);

    useEffect(() => {
        // ✅ Auth aus: sofort fertig, keine Subscriptions
        if (AUTH_DISABLED) return;
        if (!supabase) return;

        let alive = true;

        (async () => {
            const { data } = await supabase.auth.getSession();
            if (!alive) return;
            setSession(data.session ?? null);
            setUser(data.session?.user ?? null);
            setLoading(false);
        })();

        const { data: sub } = supabase.auth.onAuthStateChange((_event: string, newSession: Session | null) => {
            setSession(newSession);
            setUser(newSession?.user ?? null);
            setLoading(false);
        });

        return () => {
            alive = false;
            sub.subscription.unsubscribe();
        };
    }, [supabase]);

    return <Ctx.Provider value={{ user, session, loading }}>{children}</Ctx.Provider>;
}

export function useAuth() {
    return useContext(Ctx);
}
