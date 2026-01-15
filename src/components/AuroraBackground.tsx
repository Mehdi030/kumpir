"use client";

import { useEffect, useRef } from "react";

export default function AuroraBackground() {
    const ref = useRef<HTMLCanvasElement | null>(null);

    useEffect(() => {
        const canvas = ref.current!;
        const ctx = canvas.getContext("2d")!;
        let t = 0;

        function resize() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
        }
        resize();
        window.addEventListener("resize", resize);

        function draw() {
            const w = canvas.width;
            const h = canvas.height;

            ctx.clearRect(0, 0, w, h);

            const gradients = [
                { x: 0.2, y: 0.3, c: "rgba(124,92,255,0.35)" },
                { x: 0.8, y: 0.25, c: "rgba(60,220,255,0.25)" },
                { x: 0.5, y: 0.8, c: "rgba(255,77,141,0.18)" },
            ];

            gradients.forEach((g, i) => {
                const ox = Math.sin(t * 0.0004 + i) * 120;
                const oy = Math.cos(t * 0.0003 + i) * 120;

                const grd = ctx.createRadialGradient(
                    w * g.x + ox,
                    h * g.y + oy,
                    0,
                    w * g.x + ox,
                    h * g.y + oy,
                    Math.max(w, h)
                );

                grd.addColorStop(0, g.c);
                grd.addColorStop(1, "transparent");

                ctx.fillStyle = grd;
                ctx.fillRect(0, 0, w, h);
            });

            t += 16;
            requestAnimationFrame(draw);
        }

        draw();
        return () => window.removeEventListener("resize", resize);
    }, []);

    return (
        <canvas
            ref={ref}
            style={{
                position: "fixed",
                inset: 0,
                zIndex: 0,
                pointerEvents: "none",
            }}
        />
    );
}
