"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getMuted, getVolume } from "@/lib/gameFx";

/**
 * Song-Raten (Musik-Modus): spielt den aktuellen, versteckten Song des
 * Halters als 30s-Preview ab -- der Titel wird NIRGENDS im UI gerendert,
 * nur als Suchbegriff für die iTunes-Search-API verwendet (öffentlich,
 * kein API-Key, CORS offen -- curl-verifiziert). Die eigentliche
 * Antwort-Prüfung läuft serverseitig gegen db/migrations/029.
 *
 * Läuft auf JEDEM verbundenen Client (nicht nur beim Halter), respektiert
 * aber die bestehende Mute/Lautstärke-Einstellung (gameFx), statt einen
 * zweiten, unabhängigen Audio-Schalter einzuführen.
 */
export function SongRound({ songId }: { songId: string | null }) {
    const [previewUrl, setPreviewUrl] = useState<string | null>(null);
    const audioRef = useRef<HTMLAudioElement | null>(null);
    const requestedForRef = useRef<string | null>(null);

    // songId -> Titel/Interpret laden (nur um daraus einen Suchbegriff zu
    // bauen) -> iTunes Search API -> previewUrl. Titel/Interpret selbst
    // landen nie in einem State, das im JSX gerendert wird.
    useEffect(() => {
        if (!songId) {
            // Song-Runde vorbei (Thema gewechselt/Match beendet) -- lokalen
            // Preview-Lookup zurücksetzen, damit ein späterer neuer Song mit
            // derselben id (Rematch) wieder frisch nachgeladen wird.
            // eslint-disable-next-line react-hooks/set-state-in-effect
            setPreviewUrl(null);
            requestedForRef.current = null;
            return;
        }
        if (requestedForRef.current === songId) return;
        requestedForRef.current = songId;

        let cancelled = false;
        const supabase = getSupabaseClient();

        (async () => {
            const { data, error } = await supabase
                .from("song_pool")
                .select("title,artist")
                .eq("id", songId)
                .single();

            if (cancelled || error || !data) return;

            const query = [data.title, data.artist].filter(Boolean).join(" ");
            try {
                const res = await fetch(
                    `https://itunes.apple.com/search?term=${encodeURIComponent(query)}&media=music&country=DE&limit=1`
                );
                if (cancelled) return;
                const json = await res.json();
                const url = json?.results?.[0]?.previewUrl as string | undefined;
                setPreviewUrl(url ?? null);
            } catch {
                if (!cancelled) setPreviewUrl(null);
            }
        })();

        return () => {
            cancelled = true;
        };
    }, [songId]);

    useEffect(() => {
        const el = audioRef.current;
        if (!el) return;
        if (!previewUrl || getMuted()) {
            el.pause();
            return;
        }
        el.src = previewUrl;
        el.volume = getVolume();
        void el.play().catch(() => {
            // Autoplay ohne vorherige Nutzer-Geste kann abgelehnt werden --
            // in dem Fall bleibt es einfach stumm, kein Fehler nötig.
        });
    }, [previewUrl]);

    useEffect(() => {
        if (!songId) audioRef.current?.pause();
    }, [songId]);

    if (!songId) return null;

    return (
        <div className="songRoundHint" aria-live="polite">
            <span className="songRoundIcon" aria-hidden>
                🎵
            </span>
            <span>Song läuft … errate ihn!</span>
            <audio ref={audioRef} preload="none" />
        </div>
    );
}
