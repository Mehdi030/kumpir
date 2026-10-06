"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getMuted, getVolume, onAudioSettingsChanged } from "@/lib/gameFx";
import { getSongAudio, setPendingSongPlay } from "@/lib/songAudio";

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

// Wie weit der Song laut Server-Zeitstempel gerade sein müsste (Sekunden).
// Deckel bei 28s, damit ein spät beigetretener/aufgewachter Client nicht
// versucht, über das Ende einer typischen 30s-iTunes-Preview hinaus zu
// seeken.
function targetOffsetSeconds(startedAt: string | null): number {
    if (!startedAt) return 0;
    const startedMs = Date.parse(startedAt);
    if (Number.isNaN(startedMs)) return 0;
    return Math.max(0, Math.min(28, (Date.now() - startedMs) / 1000));
}

export function SongRound({ songId, startedAt }: { songId: string | null; startedAt: string | null }) {
    const [previewUrl, setPreviewUrl] = useState<string | null>(null);
    const [blocked, setBlocked] = useState(false);
    // Aktuelle Start-Funktion/Sperr-Status für Intervalle und Gesten-Nachholen (ohne Neu-Abo)
    const startPlaybackRef = useRef<(() => void) | null>(null);
    const blockedRef = useRef(false);
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
                .select("preview_url,preview_checked_at,topic_pool_id")
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

            // Titel/Interpret sind für Clients gesperrt (Anti-Leak, Migration 063)
            // -- es gibt nur noch die vorab geprüfte preview_url, keinen
            // Live-Fallback über die iTunes-Suche mehr.
            if (data.preview_url) prefetchPreviewUrl(data.preview_url);
            setPreviewUrl(data.preview_url ?? null);
        })();

        return () => {
            cancelled = true;
        };
    }, [songId]);

    // Startet den Song an der Server-Position. "blocked" nur bei echter Autoplay-Sperre
    // (NotAllowedError) -- dann holt der nächste Tipp/Tastendruck irgendwo den Start nach
    // (lib/songAudio.ts), zusätzlich gibt es den Knopf. Andere Fehler (z. B. AbortError,
    // weil schon der nächste Song kommt) sind harmlos und werden ignoriert.
    const startPlayback = useCallback(() => {
        const el = getSongAudio();
        if (!el || !previewUrl || getMuted()) return;
        if (el.src !== previewUrl) el.src = previewUrl;
        el.volume = getVolume();
        el.currentTime = targetOffsetSeconds(startedAt);
        void el
            .play()
            .then(() => {
                setBlocked(false);
                setPendingSongPlay(null);
            })
            .catch((err: unknown) => {
                if (err instanceof DOMException && err.name === "NotAllowedError") {
                    setBlocked(true);
                    setPendingSongPlay(() => startPlaybackRef.current?.());
                }
            });
    }, [previewUrl, startedAt]);
    useEffect(() => {
        startPlaybackRef.current = startPlayback;
    }, [startPlayback]);

    useEffect(() => {
        const el = getSongAudio();
        if (!el) return;
        if (!previewUrl || getMuted()) {
            el.pause();
            setPendingSongPlay(null);
            // eslint-disable-next-line react-hooks/set-state-in-effect
            setBlocked(false);
            return;
        }
        // Synchrone Wiedergabe: alle Clients starten an derselben Stelle im Song (aus
        // current_song_started_at), sobald Metadaten da sind zusätzlich nachjustieren.
        const onLoadedMeta = () => {
            el.currentTime = targetOffsetSeconds(startedAt);
        };
        el.addEventListener("loadedmetadata", onLoadedMeta);
        startPlayback();
        return () => el.removeEventListener("loadedmetadata", onLoadedMeta);
    }, [previewUrl, startedAt, startPlayback]);

    // Song-Runde vorbei oder Spielseite verlassen -> Ton aus, kein Nachholen mehr
    useEffect(() => {
        if (!songId) {
            getSongAudio()?.pause();
            setPendingSongPlay(null);
        }
    }, [songId]);
    useEffect(
        () => () => {
            getSongAudio()?.pause();
            setPendingSongPlay(null);
        },
        []
    );

    // Drift-Korrektur: läuft ein Client (Buffering, gedrosselter Hintergrund-Tab, ...)
    // spürbar aus dem Takt, wird hart auf die Server-Zielposition zurückgesprungen.
    // Bleibt der Song trotz allem stehen (z. B. kurz Netz weg), wird er neu gestartet.
    useEffect(() => {
        if (!previewUrl || !startedAt) return;
        const t = window.setInterval(() => {
            const el = getSongAudio();
            if (!el || getMuted()) return;
            if (el.paused) {
                if (!blockedRef.current) startPlaybackRef.current?.();
                return;
            }
            const target = targetOffsetSeconds(startedAt);
            if (Math.abs(el.currentTime - target) > 0.75) el.currentTime = target;
        }, 3000);
        return () => window.clearInterval(t);
    }, [previewUrl, startedAt]);
    useEffect(() => {
        blockedRef.current = blocked;
    }, [blocked]);

    // Live nachziehen, wenn Mute/Lautstärke über AudioControl/Taste M geändert wird.
    useEffect(() => {
        const apply = () => {
            const el = getSongAudio();
            if (!el || !previewUrl) return;
            if (getMuted()) {
                el.pause();
                return;
            }
            el.volume = getVolume();
            if (el.paused) startPlaybackRef.current?.();
        };
        return onAudioSettingsChanged(apply);
    }, [previewUrl]);

    // Zurück in den Tab -> ggf. pausierten Song wieder anwerfen
    useEffect(() => {
        const onVis = () => {
            if (document.visibilityState === "visible" && previewUrl && !getMuted() && getSongAudio()?.paused) startPlaybackRef.current?.();
        };
        document.addEventListener("visibilitychange", onVis);
        return () => document.removeEventListener("visibilitychange", onVis);
    }, [previewUrl]);

    if (!songId) return null;

    // Nur der Autoplay-Notfall-Knopf wird gerendert (der Player selbst ist unsichtbar und
    // app-weit geteilt). Meist ist er gar nicht nötig, weil schon der nächste Tipp/Tastendruck
    // den Song startet.
    return blocked ? (
        <button type="button" onClick={startPlayback} className="btn btnPrimary songUnblock" title="Wiedergabe starten">
            🔊 Tippen für Musik
            <style>{`
        .songUnblock{ position: fixed; left: 50%; bottom: max(18px, env(safe-area-inset-bottom)); transform: translateX(-50%); z-index: 70; box-shadow: 0 10px 30px rgba(0,0,0,.4); animation: songPulse 1.2s ease-in-out infinite; }
        @keyframes songPulse { 0%,100% { transform: translateX(-50%) scale(1); } 50% { transform: translateX(-50%) scale(1.06); } }
      `}</style>
        </button>
    ) : null;
}
