/**
 * Wer bekommt die Kumpir als Nächstes? Spiegelt die Server-Regel (_next_alive, Migration 113):
 * Sitzreihenfolge in Weitergaberichtung; im Modus Teams der nächste Lebende aus dem ANDEREN Team.
 * `alive` muss in Sitzreihenfolge (seat_index aufsteigend) stehen und nur Lebende enthalten.
 */
export function nextHolderId<T extends { player_id: string; team?: number | null }>(alive: T[], holderId: string, direction: number): string | null {
    const n = alive.length;
    if (n < 2) return null;
    const hi = alive.findIndex((p) => p.player_id === holderId);
    if (hi < 0) return null;
    const dir = direction < 0 ? -1 : 1;
    const holder = alive[hi]!;
    if (holder.team != null) {
        for (let k = 1; k < n; k++) {
            const cand = alive[(((hi + dir * k) % n) + n) % n]!;
            if (cand.team !== holder.team) return cand.player_id;
        }
    }
    return alive[(((hi + dir) % n) + n) % n]?.player_id ?? null;
}
