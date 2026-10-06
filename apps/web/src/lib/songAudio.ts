"use client";

import { unlockGameFx } from "@/lib/gameFx";

/**
 * EIN gemeinsamer Audio-Player für die Song-Vorschauen.
 *
 * Warum: Browser blockieren Ton ohne vorherige Nutzer-Geste (Autoplay-Sperre). Chrome merkt sich
 * eine Geste pro Seite, iPhone-Safari aber pro <audio>-Element. Ein frisch erzeugtes Element auf
 * der Spielseite (z. B. nach Neuladen oder auf dem iPhone) startete deshalb manchmal stumm, bis ein
 * neuer Song kam. Lösung:
 *  1. ein einziger Player für die ganze App,
 *  2. beim ersten Tipp/Tastendruck irgendwo wird er einmal (lautlos) freigeschaltet,
 *  3. scheitert ein Start trotzdem, wird er beim nächsten Tipp/Tastendruck automatisch nachgeholt.
 */

let player: HTMLAudioElement | null = null;
let unlocked = false;
let pendingPlay: (() => void) | null = null;
let installed = false;

export function getSongAudio(): HTMLAudioElement | null {
    if (typeof window === "undefined") return null;
    if (!player) {
        player = new Audio();
        player.preload = "auto";
        player.setAttribute("playsinline", "");
        // nur in der Entwicklung von außen prüfbar (Tests im Browser)
        if (process.env.NODE_ENV !== "production") (window as unknown as { __songAudio?: HTMLAudioElement }).__songAudio = player;
    }
    return player;
}

/** Winzige stille WAV-Datei (für die Freischaltung, ohne zusätzliche Datei). */
function silentWavUrl(): string {
    const samples = 400; // 50 ms bei 8 kHz
    const buf = new Uint8Array(44 + samples);
    const dv = new DataView(buf.buffer);
    const w = (o: number, s: string) => [...s].forEach((c, i) => dv.setUint8(o + i, c.charCodeAt(0)));
    w(0, "RIFF");
    dv.setUint32(4, 36 + samples, true);
    w(8, "WAVE");
    w(12, "fmt ");
    dv.setUint32(16, 16, true);
    dv.setUint16(20, 1, true); // PCM
    dv.setUint16(22, 1, true); // mono
    dv.setUint32(24, 8000, true);
    dv.setUint32(28, 8000, true);
    dv.setUint16(32, 1, true);
    dv.setUint16(34, 8, true);
    w(36, "data");
    dv.setUint32(40, samples, true);
    buf.fill(128, 44); // 8-bit Stille
    let bin = "";
    buf.forEach((b) => (bin += String.fromCharCode(b)));
    return `data:audio/wav;base64,${btoa(bin)}`;
}

/** Merkt sich einen fehlgeschlagenen Start, der beim nächsten Tipp/Tastendruck nachgeholt wird. */
export function setPendingSongPlay(fn: (() => void) | null) {
    pendingPlay = fn;
}

function onGesture() {
    unlockGameFx();
    if (pendingPlay) {
        const fn = pendingPlay;
        pendingPlay = null;
        fn(); // innerhalb der Geste -> erlaubt
        unlocked = true;
        return;
    }
    if (unlocked) return;
    const a = getSongAudio();
    if (!a || !a.paused) return; // läuft schon
    if (a.src && !a.src.startsWith("data:")) return; // echter Song geladen -> nicht ersetzen
    a.muted = true;
    a.src = silentWavUrl();
    void a
        .play()
        .then(() => {
            unlocked = true;
            a.pause();
        })
        .catch(() => undefined)
        .finally(() => {
            a.muted = false;
        });
}

/** Einmal pro App: Gesten-Lauscher für Freischaltung und Nachholen. */
export function installAudioUnlock() {
    if (installed || typeof window === "undefined") return;
    installed = true;
    const opts = { capture: true, passive: true } as const;
    window.addEventListener("pointerdown", onGesture, opts);
    window.addEventListener("keydown", onGesture, opts);
    window.addEventListener("touchend", onGesture, opts);
}
