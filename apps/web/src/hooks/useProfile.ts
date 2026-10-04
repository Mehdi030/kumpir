"use client";

import { useEffect, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type Profile = {
    username: string | null;
    email: string | null;
    emailVerified: boolean;
    createdAt: string | null;
};

/**
 * Profil des eingeloggten Users (Username aus `profiles`, E-Mail/Verifizierung
 * aus der Auth-Session). Für Gäste: `profile === null`.
 */
export function useProfile() {
    const { user, loading: authLoading } = useAuth();
    const [username, setUsername] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);

    const userId = user?.id ?? null;

    useEffect(() => {
        if (!userId) {
            // eslint-disable-next-line react-hooks/set-state-in-effect
            setUsername(null);
            return;
        }
        let cancel = false;
        setLoading(true);
        void (async () => {
            const { data } = await getSupabaseClient().from("profiles").select("username").eq("id", userId).maybeSingle();
            if (cancel) return;
            setUsername((data as { username?: string | null } | null)?.username ?? null);
            setLoading(false);
        })();
        return () => {
            cancel = true;
        };
    }, [userId]);

    const profile: Profile | null = user
        ? {
              username,
              email: user.email ?? null,
              emailVerified: !!user.email_confirmed_at,
              createdAt: user.created_at ?? null,
          }
        : null;

    return { profile, user, loading: authLoading || loading };
}
