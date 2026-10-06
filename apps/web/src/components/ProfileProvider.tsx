"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { User } from "@supabase/supabase-js";
import { useAuth } from "@/components/AuthProvider";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { mergePreferences, type AccountSettings, type AccountStatus, type Preferences, type StaffRole } from "@/lib/accountSettings";

export type Profile = {
    username: string | null;
    email: string | null;
    emailVerified: boolean;
    createdAt: string | null;
    displayName: string | null;
    avatarEmoji: string | null;
    avatarColor: string | null;
    preferences: Preferences;
    /** Name für Lobbys: Spielername, sonst Benutzername. */
    playerName: string | null;
    role: StaffRole;
    status: AccountStatus;
    /** Admin oder Supporter -> Admin-Panel sichtbar */
    isStaff: boolean;
};

type ProfileCtx = {
    profile: Profile | null;
    user: User | null;
    loading: boolean;
    /** Lädt Einstellungen neu (z. B. nach dem Speichern). */
    refresh: () => Promise<void>;
    /** Speichert Vorlieben (Teil-Update, wird mit dem aktuellen Stand zusammengeführt). */
    savePreferences: (patch: Preferences) => Promise<{ ok: boolean; error?: string }>;
};

const EMPTY: AccountSettings = { role: "user", status: "active", username: null, displayName: null, avatarEmoji: null, avatarColor: null, preferences: {} };

const Ctx = createContext<ProfileCtx>({
    profile: null,
    user: null,
    loading: true,
    refresh: async () => {},
    savePreferences: async () => ({ ok: false }),
});

/** Ein gemeinsamer Profil-Stand für die ganze App (Kopfzeile, Profil, Host/Join/Solo). */
export function ProfileProvider({ children }: { children: React.ReactNode }) {
    const { user, loading: authLoading } = useAuth();
    const userId = user?.id ?? null;
    const [settings, setSettings] = useState<AccountSettings>(EMPTY);
    const [loadedFor, setLoadedFor] = useState<string | null>(null);

    const load = useCallback(async (uid: string) => {
        const supabase = getSupabaseClient();
        const { data, error } = await supabase.rpc("get_my_settings");
        if (!error && data) {
            const d = data as Partial<AccountSettings>;
            // Gesperrt oder Löschung beantragt: sofort abmelden (der Server lässt ohnehin nichts mehr zu)
            if (d.status && d.status !== "active") {
                await supabase.auth.signOut();
                window.location.assign(`/login?m=${d.status === "deletion_requested" ? "deletion_requested" : "account_suspended"}`);
                return;
            }
            setSettings({
                role: (d.role as StaffRole) ?? "user",
                status: "active",
                username: d.username ?? null,
                displayName: d.displayName ?? null,
                avatarEmoji: d.avatarEmoji ?? null,
                avatarColor: d.avatarColor ?? null,
                preferences: (d.preferences as Preferences) ?? {},
            });
        } else {
            // Rückfall (z. B. Netzwerkfehler): wenigstens den Benutzernamen anzeigen
            const { data: row } = await supabase.from("profiles").select("username").eq("id", uid).maybeSingle();
            setSettings({ ...EMPTY, username: (row as { username?: string | null } | null)?.username ?? null });
        }
        setLoadedFor(uid);
    }, []);

    useEffect(() => {
        if (!userId) return;
        let cancel = false;
        void (async () => {
            if (!cancel) await load(userId);
        })();
        return () => {
            cancel = true;
        };
    }, [userId, load]);

    const refresh = useCallback(async () => {
        if (userId) await load(userId);
    }, [userId, load]);

    const savePreferences = useCallback(
        async (patch: Preferences) => {
            if (!userId) return { ok: false, error: "not_logged_in" };
            const next = mergePreferences(settings.preferences, patch);
            const { data, error } = await getSupabaseClient().rpc("set_my_preferences", { p_prefs: next });
            if (error) return { ok: false, error: error.message };
            setSettings((s) => ({ ...s, preferences: (data as Preferences) ?? next }));
            return { ok: true };
        },
        [userId, settings.preferences]
    );

    const value = useMemo<ProfileCtx>(() => {
        const ready = !!userId && loadedFor === userId;
        const s = ready ? settings : EMPTY;
        const profile: Profile | null = user
            ? {
                  username: s.username,
                  email: user.email ?? null,
                  emailVerified: !!user.email_confirmed_at,
                  createdAt: user.created_at ?? null,
                  displayName: s.displayName,
                  avatarEmoji: s.avatarEmoji,
                  avatarColor: s.avatarColor,
                  preferences: s.preferences,
                  playerName: s.displayName || s.username,
                  role: s.role,
                  status: s.status,
                  isStaff: s.role === "admin" || s.role === "supporter",
              }
            : null;
        return {
            profile,
            user,
            loading: authLoading || (!!userId && !ready),
            refresh,
            savePreferences,
        };
    }, [user, userId, loadedFor, settings, authLoading, refresh, savePreferences]);

    return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useProfileContext() {
    return useContext(Ctx);
}
