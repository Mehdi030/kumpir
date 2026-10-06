"use client";

import { getSupabaseClient } from "@/lib/supabaseClient";

/**
 * Anonyme Nutzungs-Ereignisse ("Weg der Spieler"): Wie viele starten Solo, spielen zu Ende,
 * laden Freunde ein …? Gespeichert werden nur Ereignisname, eine zufällige Geräte-ID
 * (localStorage, kein Name, keine IP) und wenige Zusatzwerte. Rohdaten werden nach 90 Tagen
 * gelöscht (Migration 076). Auswertung: /admin/stats.
 *
 * Neue Ereignisse müssen zusätzlich in public.log_event (Whitelist) eingetragen werden.
 */
export type TrackEvent =
    | "home_view"
    | "solo_start"
    | "solo_game_started"
    | "host_created"
    | "join_success"
    | "spectate"
    | "game_finished"
    | "invite_share"
    | "invite_copy"
    | "invite_qr"
    | "result_share"
    | "install_click"
    | "lang_en"
    | "register_success";

type Props = Record<string, string | number | boolean>;

const ANON_KEY = "kumpir_anon_id";

function anonId(): string | null {
    try {
        let id = localStorage.getItem(ANON_KEY);
        if (!id) {
            id = crypto.randomUUID();
            localStorage.setItem(ANON_KEY, id);
        }
        return id;
    } catch {
        return null;
    }
}

/** Feuert und vergisst – darf nie einen Fehler in der Oberfläche auslösen. */
export function track(event: TrackEvent, props?: Props): void {
    if (typeof window === "undefined") return;
    const id = anonId();
    if (!id) return;
    // Entwicklung nutzt dieselbe Datenbank wie die echte Seite: als "dev" markieren,
    // damit die Auswertung diese Ereignisse herausfiltert.
    const all: Props = { ...(props ?? {}), ...(process.env.NODE_ENV !== "production" ? { dev: true } : {}) };
    try {
        void getSupabaseClient()
            .rpc("log_event", { p_event: event, p_anon: id, p_props: Object.keys(all).length ? all : null })
            .then(
                () => undefined,
                () => undefined
            );
    } catch {
        /* ignore */
    }
}
