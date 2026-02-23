"use client";

import { passPotatoAction, tickGameAction } from "@/actions/game";

type Ok = { ok: true };
type Err = { ok: false; error: string };
type Res = Ok | Err;

/**
 * Client -> Server Action
 * Wichtig: playerId ist dein IN-GAME player_id (aus usePlayerIdentity), NICHT auth.user.id
 */
export async function passPotato(code: string, playerId: string): Promise<Res> {
    return passPotatoAction({ code, playerId });
}

/**
 * Client -> Server Action
 */
export async function tickGame(code: string): Promise<Res> {
    return tickGameAction({ code });
}