"use client";

import { useEffect, useRef } from "react";

const COLORS = ["#ffd23f", "#ff5c8a", "#5ce1e6", "#8dffb8", "#ff9d2e", "#b79cff", "#ffffff"];

type P = { x: number; y: number; vx: number; vy: number; w: number; h: number; rot: number; vr: number; c: string; life: number; max: number; tw: number };

/**
 * Konfetti-Stoß (Canvas) für die Roulette-Wertungs-Show: level 0 = kleines Häuflein aus der Mitte, 1 = zwei Kanonen von unten
 * plus Konfetti-Regen von oben. Räumt sich nach ein paar Sekunden selbst auf. Bei "weniger Bewegung" passiert nichts.
 * Neuer Stoß = neuer key.
 */
export function ConfettiBurst({ level, winner = false }: { level: number; winner?: boolean }) {
    const ref = useRef<HTMLCanvasElement | null>(null);

    useEffect(() => {
        const canvas = ref.current;
        if (!canvas) return;
        if (window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches) return;
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        const dpr = Math.min(2, window.devicePixelRatio || 1);
        const W = window.innerWidth;
        const H = window.innerHeight;
        canvas.width = W * dpr;
        canvas.height = H * dpr;
        ctx.scale(dpr, dpr);

        const lv = Math.max(0, Math.min(1, level));
        const count = Math.round(16 + 240 * Math.pow(lv, 1.7)) + (winner ? 220 : 0);
        const parts: P[] = [];
        const add = (x: number, y: number, angle: number, spread: number, speed: number, n: number) => {
            for (let i = 0; i < n; i++) {
                const a = angle + (Math.random() - 0.5) * spread;
                const v = speed * (0.45 + Math.random() * 0.75);
                parts.push({
                    x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, w: 6 + Math.random() * 9, h: 3 + Math.random() * 6,
                    rot: Math.random() * 6.28, vr: (Math.random() - 0.5) * 0.4, c: COLORS[Math.floor(Math.random() * COLORS.length)]!,
                    life: 0, max: 150 + Math.random() * 110, tw: Math.random() * 6.28,
                });
            }
        };
        if (lv < 0.3 && !winner) {
            add(W / 2, H * 0.42, -Math.PI / 2, Math.PI * 1.1, 9 + 6 * lv, count);
        } else if (lv < 0.8 && !winner) {
            add(W * 0.12, H * 0.9, -Math.PI / 2 - 0.35, 0.8, 17 + 9 * lv, Math.round(count / 2));
            add(W * 0.88, H * 0.9, -Math.PI / 2 + 0.35, 0.8, 17 + 9 * lv, Math.round(count / 2));
        } else {
            add(W * 0.08, H * 0.95, -Math.PI / 2 - 0.3, 0.9, 27, Math.round(count * 0.3));
            add(W * 0.92, H * 0.95, -Math.PI / 2 + 0.3, 0.9, 27, Math.round(count * 0.3));
            add(W / 2, H * 0.5, -Math.PI / 2, Math.PI * 1.4, 16, Math.round(count * 0.2));
            for (let i = 0; i < Math.round(count * 0.2); i++) add(Math.random() * W, -20 - Math.random() * 200, Math.PI / 2, 0.5, 2 + Math.random() * 4, 1);
        }

        let raf = 0;
        const tick = () => {
            ctx.clearRect(0, 0, W, H);
            let alive = 0;
            for (const p of parts) {
                p.life++;
                if (p.life > p.max) continue;
                alive++;
                p.vy += 0.38; // Schwerkraft
                p.vx *= 0.985;
                p.vy *= 0.985;
                p.x += p.vx;
                p.y += p.vy;
                p.rot += p.vr;
                p.tw += 0.2;
                const a = Math.min(1, (p.max - p.life) / 40);
                ctx.save();
                ctx.globalAlpha = a;
                ctx.translate(p.x, p.y);
                ctx.rotate(p.rot);
                ctx.fillStyle = p.c;
                ctx.fillRect(-p.w / 2, (-p.h / 2) * Math.abs(Math.cos(p.tw)) - 0.5, p.w, Math.max(1, p.h * Math.abs(Math.cos(p.tw))));
                ctx.restore();
            }
            if (alive > 0) raf = requestAnimationFrame(tick);
        };
        raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
    }, [level, winner]);

    return <canvas ref={ref} aria-hidden style={{ position: "fixed", inset: 0, width: "100vw", height: "100vh", pointerEvents: "none", zIndex: 9999 }} />;
}
