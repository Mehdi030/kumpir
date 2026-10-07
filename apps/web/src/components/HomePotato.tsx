"use client";

import Image from "next/image";
import { useEffect, useRef, type CSSProperties } from "react";

/**
 * Die Kumpir über der Startseiten-Karte: wirkt ruhig/statisch, lebt aber durch kleine Gesten.
 *  - Zwinkern: ein Augenlid in Kartoffelfarbe schließt sich kurz über dem rechten Auge (SVG),
 *    das linke Auge kneift dabei leicht mit.
 *  - Finger-Welle: jeder Finger ist als eigenes Bild ausgeschnitten (public/potato/finger-*.webp,
 *    gleiche Position wie im Logo) und hebt sich nacheinander kurz an. Gestreckt wird nur vom
 *    Fingeransatz aus, so deckt der angehobene Finger das Original im Logo immer ganz ab.
 *  - 3D: Kante/Tiefe per Schatten, Lichtreflex und leichte Neigung zur Maus (nur Maus, nicht Touch).
 * Alle Koordinaten beziehen sich auf das Originalbild HGLogo.webp (1200 x 800).
 */
const W = 1200;
const H = 800;

// Finger in Wellen-Reihenfolge (links außen -> innen, rechts innen -> außen)
const FINGERS = [
    { n: "l1", x: 211, y: 439, w: 50, h: 62 },
    { n: "l2", x: 248, y: 425, w: 61, h: 78 },
    { n: "l3", x: 291, y: 419, w: 80, h: 84 },
    { n: "l4", x: 344, y: 436, w: 85, h: 63 },
    { n: "r1", x: 777, y: 436, w: 81, h: 62 },
    { n: "r2", x: 831, y: 414, w: 85, h: 88 },
    { n: "r3", x: 894, y: 417, w: 72, h: 85 },
    { n: "r4", x: 949, y: 426, w: 60, h: 74 },
    { n: "r5", x: 994, y: 438, w: 50, h: 61 },
];

// Augen (Innenfläche ohne den schwarzen Rand)
const EYE_R = { cx: 601, cy: 420, rx: 45, ry: 47 };
const EYE_L = { cx: 488, cy: 421, rx: 42, ry: 47 };

function Lids({ eye, id, wink }: { eye: typeof EYE_R; id: string; wink: boolean }) {
    const x0 = eye.cx - eye.rx - 12;
    const x1 = eye.cx + eye.rx + 12;
    const top = eye.cy - eye.ry - 14;
    const bottom = eye.cy + eye.ry + 14;
    const seam = eye.cy + (wink ? -2 : 4); // hier treffen sich die Lider
    const dip = wink ? 24 : 14; // Lidkante nach unten gebogen (geschlossen: kleines Lächeln)
    const edge = `M ${x0} ${seam} Q ${eye.cx} ${seam + dip} ${x1} ${seam}`;
    // Punkt auf der Lidkante (für die Wimpern)
    const at = (t: number) => ({ x: x0 + (x1 - x0) * t, y: seam + 2 * dip * t * (1 - t) });
    const l1 = at(0.8);
    const l2 = at(0.88);
    return (
        <>
            <g clipPath={`url(#${id})`}>
                <g className={wink ? "kpLidUp kpWink" : "kpLidUp kpSquint"}>
                    <path d={`M ${x0} ${top} L ${x1} ${top} L ${x1} ${seam} Q ${eye.cx} ${seam + dip} ${x0} ${seam} Z`} fill="url(#kpSkinUp)" />
                    {/* ein paar Flecken wie auf der Kartoffelhaut */}
                    <ellipse cx={eye.cx - eye.rx * 0.45} cy={eye.cy - eye.ry * 0.45} rx="5" ry="3.5" fill="#a8640d" opacity=".55" />
                    <ellipse cx={eye.cx + eye.rx * 0.35} cy={eye.cy - eye.ry * 0.62} rx="3.5" ry="2.5" fill="#a8640d" opacity=".5" />
                    <ellipse cx={eye.cx + eye.rx * 0.1} cy={eye.cy - eye.ry * 0.2} rx="2.5" ry="2" fill="#a8640d" opacity=".4" />
                    <path d={edge} fill="none" stroke="#2a1203" strokeWidth={wink ? 9 : 7} strokeLinecap="round" />
                </g>
                {wink ? <path className="kpLidLo" d={`${edge} L ${x1} ${bottom} L ${x0} ${bottom} Z`} fill="url(#kpSkinLo)" /> : null}
            </g>
            {wink ? (
                <path
                    className="kpLash"
                    d={`M ${l1.x} ${l1.y + 2} l 9 13 M ${l2.x} ${l2.y} l 14 9`}
                    stroke="#2a1203"
                    strokeWidth="6"
                    strokeLinecap="round"
                    fill="none"
                />
            ) : null}
        </>
    );
}

export function HomePotato() {
    const tiltRef = useRef<HTMLDivElement>(null);

    // Leichte 3D-Neigung zur Maus (weich nachgezogen). Touch-Geräte und "weniger Bewegung": aus.
    useEffect(() => {
        const el = tiltRef.current;
        if (!el) return;
        const fine = window.matchMedia("(hover: hover) and (pointer: fine)").matches;
        const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        if (!fine || reduce) return;
        let tx = 0, ty = 0, cx = 0, cy = 0, raf = 0;
        const onMove = (e: PointerEvent) => {
            const r = el.getBoundingClientRect();
            tx = Math.max(-1, Math.min(1, (e.clientX - (r.left + r.width / 2)) / (window.innerWidth / 2)));
            ty = Math.max(-1, Math.min(1, (e.clientY - (r.top + r.height * 0.6)) / (window.innerHeight / 2)));
            if (!raf) raf = requestAnimationFrame(step);
        };
        const step = () => {
            cx += (tx - cx) * 0.08;
            cy += (ty - cy) * 0.08;
            el.style.setProperty("--ry", `${(cx * 7).toFixed(2)}deg`);
            el.style.setProperty("--rx", `${(-cy * 5).toFixed(2)}deg`);
            el.style.setProperty("--lx", `${(50 + cx * 30).toFixed(1)}%`);
            el.style.setProperty("--ly", `${(38 + cy * 20).toFixed(1)}%`);
            raf = Math.abs(tx - cx) + Math.abs(ty - cy) > 0.002 ? requestAnimationFrame(step) : 0;
        };
        window.addEventListener("pointermove", onMove, { passive: true });
        return () => {
            window.removeEventListener("pointermove", onMove);
            if (raf) cancelAnimationFrame(raf);
        };
    }, []);

    const pct = (v: number, of: number) => `${((v / of) * 100).toFixed(3)}%`;

    return (
        <div className="potatoBgImg kpStage">
            <div className="kpTilt" ref={tiltRef}>
                <Image src="/HGLogo.webp" alt="" width={900} height={600} priority quality={80} className="kpBase" />

                {/* Augenlider */}
                <svg className="kpLayer" viewBox={`0 0 ${W} ${H}`} aria-hidden>
                    <defs>
                        <clipPath id="kpEyeR">
                            <ellipse cx={EYE_R.cx} cy={EYE_R.cy} rx={EYE_R.rx} ry={EYE_R.ry} />
                        </clipPath>
                        <clipPath id="kpEyeL">
                            <ellipse cx={EYE_L.cx} cy={EYE_L.cy} rx={EYE_L.rx} ry={EYE_L.ry} />
                        </clipPath>
                        {/* gewölbtes Lid: Licht oben in der Mitte, zum Rand dunkler */}
                        <radialGradient id="kpSkinUp" cx="0.45" cy="0.62" r="0.7">
                            <stop offset="0" stopColor="#fbd25a" />
                            <stop offset="0.5" stopColor="#eaa923" />
                            <stop offset="1" stopColor="#a9670c" />
                        </radialGradient>
                        <linearGradient id="kpSkinLo" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0" stopColor="#d99819" />
                            <stop offset="1" stopColor="#b5720e" />
                        </linearGradient>
                    </defs>
                    <Lids eye={EYE_R} id="kpEyeR" wink />
                    <Lids eye={EYE_L} id="kpEyeL" wink={false} />
                </svg>

                {/* Finger (einzeln ausgeschnitten, liegen exakt über dem Original) */}
                {FINGERS.map((f, i) => (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                        key={f.n}
                        src={`/potato/finger-${f.n}.webp`}
                        alt=""
                        className={`kpFinger ${f.n.startsWith("l") ? "kpHandL" : "kpHandR"}`}
                        style={
                            {
                                left: pct(f.x, W),
                                top: pct(f.y, H),
                                width: pct(f.w, W),
                                height: pct(f.h, H),
                                "--i": i < 4 ? i : i - 4,
                            } as CSSProperties
                        }
                        draggable={false}
                    />
                ))}

                {/* Funke an der Zündschnur + Lichtreflex */}
                <span className="kpSpark" style={{ left: pct(808, W), top: pct(219, H) }} />
                <span className="kpSheen" />
            </div>
        </div>
    );
}
