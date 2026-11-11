"use client";

import { getSupabaseClient } from "@/lib/supabaseClient";
import { getMuted, getVolume } from "@/lib/gameFx";
import { getSongAudio, setPendingSongPlay } from "@/lib/songAudio";

const urlCache = new Map<string, string | null>();

/** Vorschau-Adresse eines Songs (wie im Quiz direkt aus der Song-Tabelle; Titel und Künstler bleiben gesperrt). */
export async function previewUrlOf(songId: string): Promise<string | null> {
    if (urlCache.has(songId)) return urlCache.get(songId) ?? null;
    for (let attempt = 0; attempt < 3; attempt++) {
        const { data, error } = await getSupabaseClient().from("song_pool").select("preview_url").eq("id", songId).single();
        if (!error && data) {
            const url = (data as { preview_url: string | null }).preview_url ?? null;
            urlCache.set(songId, url);
            return url;
        }
        await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
    }
    return null;
}

/**
 * Spielt einen Ausschnitt: ab startSec (Sekunden im Song) für seconds Sekunden, danach Stille.
 * offset = wie viele Sekunden des Ausschnitts schon vorbei sind (späte Mitspieler steigen in der Mitte ein).
 * Gibt eine Funktion zurück, die den Ausschnitt abbricht. onBlocked wird gerufen, wenn der Browser den Ton sperrt.
 */
export function playClip(url: string, startSec: number, seconds: number, offset = 0, onBlocked?: (blocked: boolean) => void): () => void {
    const el = getSongAudio();
    if (!el || getMuted() || offset >= seconds) return () => {};
    let timer = 0;
    const go = () => {
        if (el.src !== url) el.src = url;
        el.loop = false;
        el.volume = getVolume();
        const begin = () => {
            try {
                el.currentTime = startSec + offset;
            } catch {
                /* Metadaten noch nicht da: loadedmetadata holt es nach */
            }
        };
        begin();
        el.addEventListener("loadedmetadata", begin, { once: true });
        void el
            .play()
            .then(() => {
                onBlocked?.(false);
                setPendingSongPlay(null);
            })
            .catch((err: unknown) => {
                if (err instanceof DOMException && err.name === "NotAllowedError") {
                    onBlocked?.(true);
                    setPendingSongPlay(go);
                }
            });
    };
    go();
    timer = window.setTimeout(() => el.pause(), Math.max(0, (seconds - offset) * 1000));
    return () => {
        window.clearTimeout(timer);
        el.pause();
        setPendingSongPlay(null);
    };
}
