"use client";

/**
 * Geheimes Session-Token dieses Browsers.
 *
 * Wird einmal erzeugt, lokal gespeichert und bei JEDEM Supabase-Request
 * als Header `x-kumpir-session` mitgeschickt (siehe supabaseClient.ts).
 * Beim Beitreten bindet rpc_join_lobby / rpc_create_lobby es an die
 * eigene players-Zeile; die Spalte ist per Column-Grant für andere
 * Clients nicht lesbar (Migration 023).
 *
 * Damit ist die player_id allein wertlos für Angreifer: sie ist zwar
 * für alle in der Lobby sichtbar, aber ohne das passende Token lehnt
 * jede schreibende RPC mit `invalid_session` ab.
 */

const KEY = "kumpir_session_token";

export const SESSION_HEADER = "x-kumpir-session";

function readStored(): string | null {
    try {
        return localStorage.getItem(KEY) || sessionStorage.getItem(KEY);
    } catch {
        return null;
    }
}

function persist(token: string) {
    try {
        localStorage.setItem(KEY, token);
    } catch {
        /* private mode o.ä. -- dann nur für diese Sitzung */
    }
    try {
        sessionStorage.setItem(KEY, token);
    } catch {
        /* ignore */
    }
}

/** Liefert das Token dieses Browsers und erzeugt es beim ersten Aufruf. */
export function getSessionToken(): string | null {
    if (typeof window === "undefined") return null;

    const existing = readStored();
    if (existing) return existing;

    const fresh = crypto.randomUUID();
    persist(fresh);
    return fresh;
}

/** Nur für den Identitäts-Reset (z.B. nach Kick/Verlassen). */
export function clearSessionToken() {
    try {
        localStorage.removeItem(KEY);
    } catch {
        /* ignore */
    }
    try {
        sessionStorage.removeItem(KEY);
    } catch {
        /* ignore */
    }
}
