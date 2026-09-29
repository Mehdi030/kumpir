"use client";

import { useCallback, useEffect, useRef, useState } from "react";
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
// Songs, deren Preview-URL wir schon vorgeladen haben (Modul-Ebene, überlebt
// Re-Renders und den Wechsel des aktuellen Songs für die Dauer des Tabs).
const prefetchedUrls = new Set<string>();
const prefetchedTopics = new Set<string>();
// Muss außerhalb jeder Funktion referenziert bleiben, sonst holt der
// Garbage-Collector die Audio()-Objekte, bevor der Preload fertig ist.
const prefetchAudioPool: HTMLAudioElement[] = [];

function prefetchPreviewUrl(url: string) {
    if (!url || prefetchedUrls.has(url)) return;
    prefetchedUrls.add(url);
    const a = new Audio();
    a.preload = "auto";
    a.src = url;
    a.load();
    prefetchAudioPool.push(a);
}

export function SongRound({ songId }: { songId: string | null }) {
    const [previewUrl, setPreviewUrl] = useState<string | null>(null);
    const [blocked, setBlocked] = useState(false);
    const audioRef = useRef<HTMLAudioElement | null>(null);
    const requestedForRef = useRef<string | null>(null);

    // songId -> preview_url. Der Normalfall liest nur noch die von
    // db/scripts/backfill-song-previews.mjs vorab gecachte URL (Migration
    // 036) -- kein Live-Request mehr, keine Ladezeit. Nur für einen Song,
    // der noch nie gecacht wurde (frisch hinzugefügt, Cache-Job noch nicht
    // gelaufen), fragen wir als Fallback einmalig live die iTunes Search
    // API an, statt einfach stumm zu bleiben.
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
                .select("title,artist,preview_url,preview_checked_at,topic_pool_id")
                .eq("id", songId)
                .single();

            if (cancelled || error || !data) return;

            // Restliche Songs derselben Kategorie im Hintergrund vorladen (einmal
            // pro Kategorie und Tab) -- sonst lädt <audio preload="none"> die
            // Preview erst GENAU in dem Moment, in dem der Song dran ist, und
            // wer gerade eine langsamere Verbindung/CDN-Route hat, verliert
            // dadurch spürbar Reaktionszeit gegenüber den anderen Haltern.
            if (data.topic_pool_id && !prefetchedTopics.has(data.topic_pool_id)) {
                prefetchedTopics.add(data.topic_pool_id);
                void supabase
                    .from("song_pool")
                    .select("preview_url")
                    .eq("topic_pool_id", data.topic_pool_id)
                    .not("preview_url", "is", null)
                    .then(({ data: siblings }) => {
                        for (const s of siblings ?? []) {
                            if (s.preview_url) prefetchPreviewUrl(s.preview_url as string);
                        }
                    });
            }

            if (data.preview_checked_at) {
                // Bereits gecacht (auch wenn Ergebnis damals "kein Treffer" war,
                // also preview_url null) -- kein erneuter Live-Request nötig.
                if (data.preview_url) prefetchPreviewUrl(data.preview_url);
                setPreviewUrl(data.preview_url ?? null);
                return;
            }

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
            // eslint-disable-next-line react-hooks/set-state-in-effect
            setBlocked(false);
            return;
        }
        el.src = previewUrl;
        el.volume = getVolume();
        el.play()
            .then(() => setBlocked(false))
            .catch(() => {
                // Browser-Autoplay-Policy kann den ersten Play() ohne frische
                // Nutzer-Geste ablehnen (z.B. direkt nach Rematch/Reload ohne
                // Zwischenklick) -- statt dann einfach stumm zu bleiben (der
                // gemeldete "läuft nicht von Anfang an"-Fall), zeigen wir einen
                // Tippen-zum-Abspielen-Button, der garantiert funktioniert.
                setBlocked(true);
            });
    }, [previewUrl]);

    useEffect(() => {
        if (!songId) audioRef.current?.pause();
    }, [songId]);

    const retryPlay = useCallback(() => {
        const el = audioRef.current;
        if (!el) return;
        void el.play().then(() => setBlocked(false)).catch(() => setBlocked(true));
    }, []);

    if (!songId) return null;

    return (
        <div className="songRoundHint" aria-live="polite">
            {blocked ? (
                <button type="button" onClick={retryPlay} className="btn btnSecondary btnSmall" title="Wiedergabe starten">
                    ▶️ Song abspielen
                </button>
            ) : (
                <>
                    <span className="songRoundIcon" aria-hidden>
                        🎵
                    </span>
                    <span>Song läuft … errate ihn!</span>
                </>
            )}
            <audio ref={audioRef} preload="none" />
        </div>
    );
}
