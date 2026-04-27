"use client";

/**
 * Synthesized SFX via Web Audio API + haptic vibration.
 * No external audio assets — keeps bundle small.
 *
 * Auto-mute respects:
 *  - localStorage "kumpir_mute" === "1"
 *  - prefers-reduced-motion (vibration only)
 */

type FxKind = "vote" | "voteWin" | "tick" | "pass" | "selfExplode" | "explode" | "victory";

let ctx: AudioContext | null = null;
let muted: boolean | null = null;
let volume: number | null = null; // 0..1

function isMuted(): boolean {
    if (muted !== null) return muted;
    if (typeof window === "undefined") return true;
    try {
        muted = window.localStorage.getItem("kumpir_mute") === "1";
    } catch {
        muted = false;
    }
    return muted;
}

export function setMuted(next: boolean) {
    muted = next;
    try {
        window.localStorage.setItem("kumpir_mute", next ? "1" : "0");
    } catch {
        // ignore
    }
}

export function getMuted(): boolean {
    return isMuted();
}

export function getVolume(): number {
    if (volume !== null) return volume;
    if (typeof window === "undefined") return 0.7;
    try {
        const raw = window.localStorage.getItem("kumpir_volume");
        const parsed = raw == null ? NaN : Number(raw);
        volume = Number.isFinite(parsed) ? Math.max(0, Math.min(1, parsed)) : 0.7;
    } catch {
        volume = 0.7;
    }
    return volume;
}

export function setVolume(next: number) {
    const clamped = Math.max(0, Math.min(1, next));
    volume = clamped;
    try {
        window.localStorage.setItem("kumpir_volume", String(clamped));
    } catch {
        // ignore
    }
}

function getCtx(): AudioContext | null {
    if (typeof window === "undefined") return null;
    if (ctx) return ctx;
    type WebkitWindow = Window & { webkitAudioContext?: typeof AudioContext };
    const Ctor: typeof AudioContext | undefined =
        window.AudioContext ?? (window as WebkitWindow).webkitAudioContext;
    if (!Ctor) return null;
    try {
        ctx = new Ctor();
    } catch {
        ctx = null;
    }
    return ctx;
}

function tone(freq: number, durMs: number, opts?: { type?: OscillatorType; gain?: number; decay?: number; delayMs?: number }) {
    const ac = getCtx();
    if (!ac) return;

    const startAt = ac.currentTime + (opts?.delayMs ?? 0) / 1000;
    const dur = durMs / 1000;
    const peak = (opts?.gain ?? 0.18) * getVolume();
    const decay = opts?.decay ?? 0.7;
    if (peak <= 0.0001) return;

    const osc = ac.createOscillator();
    const g = ac.createGain();
    osc.type = opts?.type ?? "sine";
    osc.frequency.value = freq;

    g.gain.setValueAtTime(0.0001, startAt);
    g.gain.exponentialRampToValueAtTime(peak, startAt + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, startAt + dur * decay);

    osc.connect(g).connect(ac.destination);
    osc.start(startAt);
    osc.stop(startAt + dur);
}

function noiseBurst(durMs: number, opts?: { gain?: number; lowpass?: number }) {
    const ac = getCtx();
    if (!ac) return;
    const start = ac.currentTime;
    const dur = durMs / 1000;
    const peak = (opts?.gain ?? 0.35) * getVolume();
    if (peak <= 0.0001) return;

    const sampleCount = Math.floor(ac.sampleRate * dur);
    const buf = ac.createBuffer(1, sampleCount, ac.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < sampleCount; i++) data[i] = (Math.random() * 2 - 1) * (1 - i / sampleCount);

    const src = ac.createBufferSource();
    src.buffer = buf;

    const lp = ac.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.value = opts?.lowpass ?? 1800;

    const g = ac.createGain();
    g.gain.setValueAtTime(0.0001, start);
    g.gain.exponentialRampToValueAtTime(peak, start + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, start + dur);

    src.connect(lp).connect(g).connect(ac.destination);
    src.start(start);
    src.stop(start + dur);
}

function vibrate(pattern: number | number[]) {
    if (typeof window === "undefined") return;
    if (typeof navigator === "undefined" || typeof navigator.vibrate !== "function") return;
    try {
        navigator.vibrate(pattern);
    } catch {
        // some browsers throw on user-gesture requirement
    }
}

/**
 * Resume the AudioContext on first user gesture (Chrome/Safari autoplay policy).
 * Call once near root; safe to call multiple times.
 */
export function unlockGameFx() {
    const ac = getCtx();
    if (!ac) return;
    if (ac.state === "suspended") void ac.resume();
}

export function playFx(kind: FxKind) {
    if (isMuted()) return;
    unlockGameFx();

    switch (kind) {
        case "vote":
            tone(680, 90, { type: "triangle", gain: 0.14 });
            vibrate(15);
            return;
        case "voteWin":
            tone(740, 110, { type: "triangle", gain: 0.18 });
            tone(990, 160, { type: "sine", gain: 0.16, delayMs: 90 });
            vibrate([20, 40, 20]);
            return;
        case "tick":
            tone(1500, 50, { type: "square", gain: 0.06 });
            return;
        case "pass":
            tone(560, 90, { type: "triangle", gain: 0.16 });
            tone(880, 70, { type: "sine", gain: 0.12, delayMs: 60 });
            vibrate(20);
            return;
        case "explode":
            noiseBurst(420, { gain: 0.45, lowpass: 2200 });
            tone(120, 380, { type: "sawtooth", gain: 0.22 });
            vibrate([60, 40, 120]);
            return;
        case "selfExplode":
            // Lower-pitched, longer burst — gives the loser a distinct gut-punch.
            noiseBurst(620, { gain: 0.55, lowpass: 1600 });
            tone(80, 520, { type: "sawtooth", gain: 0.26 });
            tone(160, 380, { type: "sine", gain: 0.18, delayMs: 80 });
            vibrate([100, 60, 180, 60, 200]);
            return;
        case "victory":
            tone(660, 140, { type: "triangle", gain: 0.18 });
            tone(880, 160, { type: "triangle", gain: 0.18, delayMs: 130 });
            tone(1320, 220, { type: "sine", gain: 0.18, delayMs: 290 });
            vibrate([30, 60, 30, 60, 80]);
            return;
    }
}
