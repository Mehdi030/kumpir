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

export function AuthProvider({ children }: { children: React.ReactNode }) {
    const supabase = useMemo(() => getSupabaseClient(), []);
    const [session, setSession] = useState<Session | null>(null);
    const [user, setUser] = useState<User | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        let alive = true;

        (async () => {
            const { data } = await supabase.auth.getSession();
            if (!alive) return;
            setSession(data.session ?? null);
            setUser(data.session?.user ?? null);
            setLoading(false);
        })();

        const { data: sub } = supabase.auth.onAuthStateChange((_event, newSession) => {
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
