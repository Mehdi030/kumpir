"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getMuted, getVolume, onAudioSettingsChanged } from "@/lib/gameFx";
import { getSongAudio, setPendingSongPlay } from "@/lib/songAudio";
import { serverNow } from "@/lib/serverClock";

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
// Kein Vorladen anderer Songs: früher wurden beim ersten Song ALLE Songs der Playlist im
// Hintergrund geladen (bei 164 Songs ~80 MB). Das verstopfte die Verbindung zum iTunes-Server, der
// gerade laufende Song kam dann bis zu 30 s lang nicht durch (Testrunde 2026-10-07). Der aktuelle
// Song selbst lädt in ~0,3 s.

// Länge einer iTunes-Vorschau, solange der Browser die echte Dauer noch nicht kennt.
const PREVIEW_FALLBACK_SECONDS = 30;

function previewLength(el: HTMLAudioElement | null): number {
    const d = el?.duration;
    return d && Number.isFinite(d) && d > 5 ? d : PREVIEW_FALLBACK_SECONDS;
}

// Wie weit der Song laut Server-Zeitstempel gerade sein müsste (Sekunden).
// Rechnet mit der Server-Uhr (nicht der Geräte-Uhr), damit alle Geräte an
// derselben Stelle sind. Hält ein Spieler die Kartoffel länger als die
// ~30s-Vorschau, läuft der Song in einer Schleife weiter (alle Geräte springen
// gleichzeitig an den Anfang) statt abzubrechen.
function targetOffsetSeconds(startedAt: string | null, el: HTMLAudioElement | null): number {
    if (!startedAt) return 0;
    const startedMs = Date.parse(startedAt);
    if (Number.isNaN(startedMs)) return 0;
    const elapsed = Math.max(0, (serverNow() - startedMs) / 1000);
    return elapsed % previewLength(el);
}

// Abstand zwischen Ist- und Soll-Position, mit Schleife gedacht (29.9s und 0.1s liegen nah beieinander).
function driftSeconds(el: HTMLAudioElement, target: number): number {
    const len = previewLength(el);
    const d = (((el.currentTime - target) % len) + len) % len;
    return Math.min(d, len - d);
}

export function SongRound({ songId, startedAt }: { songId: string | null; startedAt: string | null }) {
    const [previewUrl, setPreviewUrl] = useState<string | null>(null);
    const [blocked, setBlocked] = useState(false);
    // Aktuelle Start-Funktion/Sperr-Status für Intervalle und Gesten-Nachholen (ohne Neu-Abo)
    const startPlaybackRef = useRef<(() => void) | null>(null);
    const blockedRef = useRef(false);

    // songId -> preview_url (vorab geprüfte iTunes-Vorschau; Titel/Interpret sind für Clients gesperrt, Migration 063).
    useEffect(() => {
        if (!songId) {
            // Song-Runde vorbei (Thema gewechselt/Match beendet)
            setPreviewUrl(null);
            return;
        }

        // Läuft nur, wenn sich der Song ändert. Kein "schon angefragt"-Merker: wurde eine
        // Anfrage abgebrochen (Song-Wechsel, React-Neumontage), muss der nächste Lauf sie
        // wirklich neu stellen -- sonst blieb der erste Song einer Runde manchmal stumm.
        let cancelled = false;
        const supabase = getSupabaseClient();

        (async () => {
            // Kurzer Netz-Hänger soll den Song nicht für die ganze Runde stumm lassen: bis zu 4 Versuche.
            let data: { preview_url: string | null } | null = null;
            for (let attempt = 0; attempt < 4 && !cancelled; attempt++) {
                if (attempt > 0) await new Promise((r) => setTimeout(r, 600 * attempt));
                if (cancelled) return;
                const res = await supabase.from("song_pool").select("preview_url").eq("id", songId).single();
                if (!res.error && res.data) {
                    data = res.data as { preview_url: string | null };
                    break;
                }
            }

            if (cancelled || !data) return;

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
        el.loop = true;
        el.volume = getVolume();
        el.currentTime = targetOffsetSeconds(startedAt, el);
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
            setBlocked(false);
            return;
        }
        // Synchrone Wiedergabe: alle Clients starten an derselben Stelle im Song (aus
        // current_song_started_at). Sobald Metadaten da sind und sobald der Ton wirklich
        // läuft (Laden/Puffern kostet ein paar hundert ms), wird nachjustiert.
        const onLoadedMeta = () => {
            el.currentTime = targetOffsetSeconds(startedAt, el);
        };
        const onPlaying = () => {
            const target = targetOffsetSeconds(startedAt, el);
            if (driftSeconds(el, target) > 0.25) el.currentTime = target;
        };
        el.addEventListener("loadedmetadata", onLoadedMeta);
        el.addEventListener("playing", onPlaying);
        startPlayback();
        return () => {
            el.removeEventListener("loadedmetadata", onLoadedMeta);
            el.removeEventListener("playing", onPlaying);
        };
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

    // Drift-Korrektur (alle 2s): läuft ein Client (Buffering, gedrosselter Hintergrund-Tab, ...)
    // spürbar aus dem Takt, wird hart auf die Server-Zielposition zurückgesprungen.
    // Bleibt der Song trotz allem stehen (z. B. kurz Netz weg), wird er neu gestartet.
    // Zusätzlich: Lädt der Song noch, wird nicht dazwischen gesprungen (jeder Sprung startet das
    // Laden neu); hängt er trotz "läuft" (Position bewegt sich nicht, oder lädt > 6 s), wird er
    // neu geladen.
    useEffect(() => {
        if (!previewUrl || !startedAt) return;
        let lastCt = -1;
        let loadingChecks = 0;
        const restart = (el: HTMLAudioElement) => {
            lastCt = -1;
            loadingChecks = 0;
            el.load();
            startPlaybackRef.current?.();
        };
        const t = window.setInterval(() => {
            const el = getSongAudio();
            if (!el || getMuted()) return;
            if (el.paused) {
                lastCt = -1;
                if (!blockedRef.current) startPlaybackRef.current?.();
                return;
            }
            if (el.readyState < 3) {
                if (++loadingChecks >= 3) restart(el);
                return;
            }
            loadingChecks = 0;
            if (lastCt >= 0 && Math.abs(el.currentTime - lastCt) < 0.05) {
                restart(el);
                return;
            }
            const target = targetOffsetSeconds(startedAt, el);
            if (driftSeconds(el, target) > 0.5) el.currentTime = target;
            lastCt = el.currentTime;
        }, 2000);
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
