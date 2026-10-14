/**
 * Wer bekommt die Kumpir als Nächstes? Spiegelt die Server-Regel (_next_alive): nächster Lebender in Sitzreihenfolge
 * in Weitergaberichtung (1 = vorwärts, -1 = rückwärts nach einem Rache-Pass). `alive` muss in Sitzreihenfolge stehen.
 */
export function nextHolderId<T extends { player_id: string }>(alive: T[], holderId: string, direction: number): string | null {
    const n = alive.length;
    if (n < 2) return null;
    const hi = alive.findIndex((p) => p.player_id === holderId);
    if (hi < 0) return null;
    return alive[(((hi + (direction < 0 ? -1 : 1)) % n) + n) % n]?.player_id ?? null;
}
