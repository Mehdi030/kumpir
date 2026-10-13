"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getMuted, getVolume } from "@/lib/gameFx";
import { getSongAudio, setPendingSongPlay } from "@/lib/songAudio";
import { serverNow } from "@/lib/serverClock";
import { useI18n } from "@/lib/i18n";

/** Blitz-Schnipsel (Migration 108): alle 6 s ein Stück vom Gesangsstart – 1 s, 2 s, 4 s, 8 s. */
export const SNIPPET_STEP_SECONDS = 6;
export const SNIPPET_CLIPS = [1, 2, 4, 8];

export function snippetStage(startedAt: string | null): { stage: number; elapsed: number } {
    const t = startedAt ? Date.parse(startedAt) : NaN;
    const elapsed = Number.isNaN(t) ? 0 : Math.max(0, (serverNow() - t) / 1000);
    return { stage: Math.min(SNIPPET_CLIPS.length - 1, Math.floor(elapsed / SNIPPET_STEP_SECONDS)), elapsed };
}

export function SnippetPlayer({ songId, startedAt }: { songId: string | null; startedAt: string | null }) {
    const { tr } = useI18n();
    const [src, setSrc] = useState<{ url: string; start: number } | null>(null);
    const [blocked, setBlocked] = useState(false);
    const blockedRef = useRef(false);

    useEffect(() => {
        setSrc(null);
        if (!songId) return;
        let cancelled = false;
        (async () => {
            for (let attempt = 0; attempt < 4 && !cancelled; attempt++) {
                if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * attempt));
                const res = await getSupabaseClient().from("song_pool").select("preview_url, vocal_start_ms").eq("id", songId).single();
                if (cancelled) return;
                const d = res.data as { preview_url: string | null; vocal_start_ms?: number | null } | null;
                if (!res.error && d?.preview_url) {
                    setSrc({ url: d.preview_url, start: Math.max(0, Number(d.vocal_start_ms ?? 0) / 1000) });
                    return;
                }
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [songId]);

    useEffect(() => {
        const el = getSongAudio();
        if (!el || !src) return;
        el.pause();
        el.loop = false;
        if (el.src !== src.url) {
            el.src = src.url;
            el.load();
        }
        const tick = () => {
            if (getMuted()) {
                el.pause();
                return;
            }
            const { stage, elapsed } = snippetStage(startedAt);
            const within = elapsed - stage * SNIPPET_STEP_SECONDS;
            const clip = SNIPPET_CLIPS[stage];
            if (within < clip) {
                // Ausschnitt läuft: an die richtige Stelle (Gesangsstart + verstrichene Zeit im Ausschnitt)
                const start = Math.min(src.start, Math.max(0, (Number.isFinite(el.duration) ? el.duration : 30) - 10));
                const target = start + within;
                if (el.paused) {
                    el.volume = getVolume();
                    el.currentTime = target;
                    if (!blockedRef.current)
                        void el.play().catch((err: unknown) => {
                            if (err instanceof DOMException && err.name === "NotAllowedError") {
                                blockedRef.current = true;
                                setBlocked(true);
                                setPendingSongPlay(() => {
                                    blockedRef.current = false;
                                    setBlocked(false);
                                });
                            }
                        });
                } else if (Math.abs(el.currentTime - target) > 0.4) {
                    el.currentTime = target;
                }
            } else if (!el.paused) {
                el.pause();
            }
        };
        tick();
        const t = window.setInterval(tick, 120);
        return () => {
            window.clearInterval(t);
            el.pause();
        };
    }, [src, startedAt]);

    return blocked ? (
        <button
            type="button"
            className="btn btnPrimary"
            style={{ position: "fixed", left: "50%", bottom: 18, transform: "translateX(-50%)", zIndex: 70 }}
            onClick={() => {
                blockedRef.current = false;
                setBlocked(false);
            }}
        >
            {tr("🔊 Tippen für Musik")}
        </button>
    ) : null;
}
