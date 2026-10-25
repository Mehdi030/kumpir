"use client";

import { useEffect, useRef } from "react";

/**
 * Lebendiges Feuer als Partikel-Animation (Startseite): Flammen steigen auf, wiegen sich, werden von gelb-weiß zu rot und verglühen;
 * dazu Funken, die knistern (flackern) und ab und zu aufploppen ("brutzeln"). Alles auf einem Canvas mit vorgerenderten
 * Leucht-Sprites und additivem Mischen – dadurch weich und billig (kein Blur-Filter). Läuft mit gedrosselter Bildrate,
 * pausiert unsichtbar (Tab im Hintergrund / außerhalb des Bildes) und bleibt bei "Bewegung reduzieren" aus.
 */
export type FireEmitter = {
    /** Quelle als Anteil der Canvas-Breite/-Höhe (0–1): Flammen entstehen zwischen x0 und x1 auf der Höhe y */
    x0: number;
    x1: number;
    y: number;
    /** Flammen pro Sekunde */
    rate: number;
    /** Größe einer Flamme (Anteil der Canvas-Breite) */
    size: number;
    /** Aufstieg (Anteil der Canvas-Höhe pro Sekunde) */
    rise: number;
    /** Lebensdauer in Sekunden */
    life: number;
    /** Hin- und Herwiegen (Anteil der Breite pro Sekunde) */
    sway?: number;
    /** Hitze 0–1: 1 = bis weiß-gelb, 0.5 = nur orange */
    heat?: number;
    /** Funken pro Sekunde */
    sparks?: number;
};

type Particle = { x: number; y: number; vx: number; vy: number; age: number; life: number; size: number; ph: number; heat: number; spark: boolean; pop: boolean; sw: number };

const SPRITES = 10;
const KEYS: [number, number, number][] = [
    [150, 20, 4],
    [235, 80, 14],
    [255, 165, 38],
    [255, 238, 170],
];

function keyColor(t: number): [number, number, number] {
    const s = Math.max(0, Math.min(0.9999, t)) * (KEYS.length - 1);
    const i = Math.floor(s);
    const f = s - i;
    const a = KEYS[i]!;
    const b = KEYS[i + 1]!;
    return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
}

/** Leucht-Sprites von dunkelrot (kalt) bis weiß-gelb (heiß) */
function makeSprites(): HTMLCanvasElement[] {
    return Array.from({ length: SPRITES }, (_, i) => {
        const t = i / (SPRITES - 1);
        const [r, g, b] = keyColor(t);
        const c = document.createElement("canvas");
        c.width = c.height = 64;
        const x = c.getContext("2d")!;
        const grad = x.createRadialGradient(32, 32, 0, 32, 32, 32);
        const core = (v: number) => Math.round(v + (255 - v) * t * 0.55);
        grad.addColorStop(0, `rgba(${core(r)},${core(g)},${core(b)},1)`);
        grad.addColorStop(0.35, `rgba(${Math.round(r)},${Math.round(g)},${Math.round(b)},.7)`);
        grad.addColorStop(1, `rgba(${Math.round(r)},${Math.round(g)},${Math.round(b)},0)`);
        x.fillStyle = grad;
        x.fillRect(0, 0, 64, 64);
        return c;
    });
}

export function FireCanvas({
    emitters,
    className = "",
    scale = 0.6,
    density = 1,
    fps = 40,
    maxParticles = 340,
}: {
    emitters: FireEmitter[];
    className?: string;
    /** Auflösung gegenüber der CSS-Größe (kleiner = billiger, weicher) */
    scale?: number;
    density?: number;
    fps?: number;
    maxParticles?: number;
}) {
    const ref = useRef<HTMLCanvasElement | null>(null);
    const cfg = useRef({ emitters, density });
    useEffect(() => {
        cfg.current = { emitters, density };
    }, [emitters, density]);

    useEffect(() => {
        const cv = ref.current;
        if (!cv) return;
        if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
        const ctx = cv.getContext("2d");
        if (!ctx) return;
        const sprites = makeSprites();
        const parts: Particle[] = [];
        const acc = new Map<number, { f: number; s: number }>();
        let W = 1;
        let H = 1;
        let visible = true;
        const resize = () => {
            W = Math.max(2, Math.round(cv.clientWidth * scale));
            H = Math.max(2, Math.round(cv.clientHeight * scale));
            cv.width = W;
            cv.height = H;
        };
        resize();
        const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(resize) : null;
        ro?.observe(cv);
        const io = typeof IntersectionObserver !== "undefined" ? new IntersectionObserver((e) => (visible = !!e[0]?.isIntersecting)) : null;
        io?.observe(cv);

        let raf = 0;
        let last = performance.now();
        let clock = 0;
        const frame = 1000 / fps;
        const rnd = Math.random;

        const spawn = (e: FireEmitter, spark: boolean) => {
            if (parts.length >= maxParticles) return;
            const x = (e.x0 + (e.x1 - e.x0) * rnd()) * W;
            const y = e.y * H;
            if (spark) {
                parts.push({
                    x, y,
                    vx: (rnd() - 0.5) * 0.22 * W,
                    vy: -e.rise * H * (1.1 + rnd() * 1.5),
                    age: 0, life: 0.5 + rnd() * 1.1, size: (0.0035 + rnd() * 0.005) * W * 1.6, ph: rnd() * 6.28, heat: 1, spark: true, pop: rnd() < 0.18, sw: 0,
                });
            } else {
                parts.push({
                    x, y,
                    vx: (rnd() - 0.5) * 0.02 * W,
                    vy: -e.rise * H * (0.7 + rnd() * 0.6),
                    age: 0, life: e.life * (0.7 + rnd() * 0.6), size: e.size * W * (0.7 + rnd() * 0.6), ph: rnd() * 6.28, heat: (e.heat ?? 1) * (0.85 + rnd() * 0.15), spark: false, pop: false, sw: e.sway ?? 1,
                });
            }
        };

        const tick = (now: number) => {
            raf = requestAnimationFrame(tick);
            if (document.hidden || !visible) {
                last = now;
                return;
            }
            const elapsed = now - last;
            if (elapsed < frame) return;
            const dt = Math.min(0.06, elapsed / 1000);
            last = now;
            clock += dt;
            const { emitters: ems, density: dens } = cfg.current;

            ems.forEach((e, i) => {
                const a = acc.get(i) ?? { f: 0, s: 0 };
                a.f += e.rate * dens * dt;
                a.s += (e.sparks ?? 0) * dens * dt;
                while (a.f >= 1) {
                    a.f -= 1;
                    spawn(e, false);
                }
                while (a.s >= 1) {
                    a.s -= 1;
                    spawn(e, true);
                }
                acc.set(i, a);
            });

            ctx.clearRect(0, 0, W, H);
            ctx.globalCompositeOperation = "lighter";
            for (let i = parts.length - 1; i >= 0; i--) {
                const p = parts[i]!;
                p.age += dt;
                if (p.age >= p.life) {
                    parts.splice(i, 1);
                    continue;
                }
                const t = p.age / p.life;
                if (p.spark) {
                    p.vy += 0.5 * H * dt * 0.35; // Funken werden oben langsamer
                    p.x += p.vx * dt;
                    p.y += p.vy * dt;
                    const flick = 0.35 + 0.65 * Math.abs(Math.sin(p.age * (24 + p.ph * 3) + p.ph));
                    ctx.globalAlpha = Math.min(1, (1 - t) * 1.4) * flick;
                    const s = p.size;
                    ctx.drawImage(sprites[SPRITES - 1]!, p.x - s, p.y - s, s * 2, s * 2);
                    // kurzes Aufploppen: heller, größerer Blitz
                    if (p.pop && t > 0.35 && t < 0.35 + 0.09 / p.life) {
                        ctx.globalAlpha = 0.9;
                        const b = s * 5;
                        ctx.drawImage(sprites[SPRITES - 1]!, p.x - b, p.y - b, b * 2, b * 2);
                    }
                    continue;
                }
                // Flamme: wiegt sich, wird von unten nach oben kälter und kleiner
                const e = 1 + Math.sin(clock * 1.3 + p.ph + p.y * 0.006) * 0.5;
                p.x += (p.vx + Math.sin(p.age * 3.1 + p.ph) * 0.045 * W * e * p.sw) * dt;
                p.y += p.vy * dt;
                p.vy *= 1 - 0.1 * dt;
                const temp = p.heat * (1 - t * 0.9);
                const idx = Math.max(0, Math.min(SPRITES - 1, Math.round(temp * (SPRITES - 1))));
                const s = p.size * (1 - t * 0.72) * (0.9 + 0.2 * Math.sin(p.age * 17 + p.ph));
                ctx.globalAlpha = Math.min(1, t * 7) * Math.pow(1 - t, 1.15) * 0.8;
                // Flammenzunge: höher als breit, kippt leicht in Windrichtung
                const sw = s * 0.72;
                const sh = s * 1.75;
                ctx.drawImage(sprites[idx]!, p.x - sw, p.y - sh * 0.9, sw * 2, sh * 2);
            }
            ctx.globalAlpha = 1;
            ctx.globalCompositeOperation = "source-over";
        };
        raf = requestAnimationFrame(tick);
        return () => {
            cancelAnimationFrame(raf);
            ro?.disconnect();
            io?.disconnect();
        };
    }, [scale, fps, maxParticles]);

    return <canvas ref={ref} className={className} aria-hidden />;
}
