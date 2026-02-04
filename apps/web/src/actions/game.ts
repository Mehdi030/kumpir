"use client";

import { passPotato, explodePotato } from "@/lib/gameActions";

export async function pass(lobbyId: string, toPlayerId: string) {
    await passPotato(lobbyId, toPlayerId);
}

export async function explode(lobbyId: string) {
    await explodePotato(lobbyId);
}
