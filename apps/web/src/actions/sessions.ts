"use client";

export function getSessionPlayerId(): string | null {
    if (typeof window === "undefined") return null;
    return localStorage.getItem("kumpir_player_id");
}
