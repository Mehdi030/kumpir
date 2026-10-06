"use client";

import { useProfileContext } from "@/components/ProfileProvider";

export type { Profile } from "@/components/ProfileProvider";

/**
 * Profil des eingeloggten Users (Benutzername, Spielername, Avatar, Vorlieben aus
 * `get_my_settings`, E-Mail/Verifizierung aus der Auth-Session). Für Gäste: `profile === null`.
 * Der Stand ist app-weit geteilt (ProfileProvider im Layout).
 */
export function useProfile() {
    return useProfileContext();
}
