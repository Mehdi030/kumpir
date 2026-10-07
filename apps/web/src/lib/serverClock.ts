"use client";

import type { getSupabaseClient } from "@/lib/supabaseClient";

/**
 * Client<->Server-Zeitversatz: manche Geräte-Uhren gehen spürbar falsch (Sekunden bis Minuten).
 * Alle Anzeigen und die Song-Position rechnen deshalb mit serverNow() statt Date.now(), damit
 * jedes Gerät dieselbe Zeit sieht (gemeldeter Bug: "START IN" stand bei einem Gerät fest auf 10
 * statt wie beim anderen von 5 runterzuzählen; Songs liefen auf zwei Handys versetzt).
 */
let offsetMs = 0;

/** Geschätzte Server-Zeit in ms (wie Date.now(), aber mit der Server-Uhr). */
export function serverNow(): number {
    return Date.now() + offsetMs;
}

/**
 * Mehrere Messungen, die mit der KÜRZESTEN Laufzeit gewinnt: ein einzelner langsamer Request
 * (Kaltstart, Netz-Hänger) würde sonst die ganze Anzeige um Sekunden verschieben.
 */
export async function syncServerClock(supabase: ReturnType<typeof getSupabaseClient>) {
    let best: { rtt: number; offset: number } | null = null;
    for (let k = 0; k < 4; k++) {
        const sentAt = Date.now();
        const { data, error } = await supabase.rpc("rpc_server_time");
        if (error || !data) continue;
        const serverMs = Date.parse(data as unknown as string);
        if (Number.isNaN(serverMs)) continue;
        const rtt = Date.now() - sentAt;
        const offset = serverMs + rtt / 2 - Date.now();
        if (!best || rtt < best.rtt) best = { rtt, offset };
    }
    if (best) offsetMs = best.offset;
}
