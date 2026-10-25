"use client";

import Image from "next/image";
import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { FireCanvas, type FireEmitter } from "@/components/FireCanvas";

/**
 * Die Kumpir über der Startseiten-Karte: wirkt ruhig/statisch, lebt aber durch kleine Gesten.
 *  - Augen: beide blinzeln regelmäßig (manchmal doppelt = Zucken), ab und zu zwinkert das rechte Auge
 *    und das linke kneift mit. Augenlider in Kartoffelfarbe (SVG), Ablauf in app/motion.css.
 *  - Finger-Welle: jeder Finger ist als eigenes Bild ausgeschnitten (public/potato/finger-*.webp,
 *    gleiche Position wie im Logo) und hebt sich nacheinander kurz an. Gestreckt wird nur vom
 *    Fingeransatz aus, so deckt der angehobene Finger das Original im Logo immer ganz ab.
 *  - 3D: Kante/Tiefe per Schatten und Lichtreflex. Die Maus hat KEINEN Einfluss (Wunsch Mehdi 2026-10-12).
 *  - Feuer (Wunsch Mehdi 2026-10-25): hinter der Kumpir züngeln echte, animierte Flammen und stieben Funken (FireCanvas), die gemalten
 *    Flammen flackern im Feuerschein, ein Glutschein pulsiert dahinter und die ganze Kumpir wiegt sich in 3D leicht hin und her
 *    (schaut mal höher, mal tiefer) – alles ohne Mausbezug.
 * Alle Koordinaten beziehen sich auf HGLogo-v2.webp (1200 x 800; rechte Hand gespiegelt, damit beide Hände 4 Finger haben).
 */
const W = 1200;
const H = 800;

// Finger in Wellen-Reihenfolge (links außen -> innen, rechts innen -> außen)
const FINGERS = [
    { n: "l1", x: 211, y: 439, w: 50, h: 62 },
    { n: "l2", x: 248, y: 425, w: 61, h: 78 },
    { n: "l3", x: 291, y: 419, w: 80, h: 84 },
    { n: "l4", x: 344, y: 436, w: 85, h: 63 },
    // rechte Hand = Spiegelbild der linken (Original hatte rechts 5 Finger, links 4)
    { n: "hr1", x: 778, y: 436, w: 85, h: 63 },
    { n: "hr2", x: 836, y: 419, w: 80, h: 84 },
    { n: "hr3", x: 898, y: 425, w: 61, h: 78 },
    { n: "hr4", x: 946, y: 439, w: 50, h: 62 },
];

// Augen (Innenfläche ohne den schwarzen Rand)
const EYE_R = { cx: 601, cy: 420, rx: 45, ry: 47 };
const EYE_L = { cx: 488, cy: 421, rx: 42, ry: 47 };

function Lids({ eye, id, side }: { eye: typeof EYE_R; id: string; side: "R" | "L" }) {
    const wink = true; // Lidform mit Unterlid (für Blinzeln beider Augen)
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
                <g className={`kpLidUp kpLid${side}`}>
                    <path d={`M ${x0} ${top} L ${x1} ${top} L ${x1} ${seam} Q ${eye.cx} ${seam + dip} ${x0} ${seam} Z`} fill="url(#kpSkinUp)" />
                    {/* ein paar Flecken wie auf der Kartoffelhaut */}
                    <ellipse cx={eye.cx - eye.rx * 0.45} cy={eye.cy - eye.ry * 0.45} rx="5" ry="3.5" fill="#a8640d" opacity=".55" />
                    <ellipse cx={eye.cx + eye.rx * 0.35} cy={eye.cy - eye.ry * 0.62} rx="3.5" ry="2.5" fill="#a8640d" opacity=".5" />
                    <ellipse cx={eye.cx + eye.rx * 0.1} cy={eye.cy - eye.ry * 0.2} rx="2.5" ry="2" fill="#a8640d" opacity=".4" />
                    <path d={edge} fill="none" stroke="#2a1203" strokeWidth={wink ? 9 : 7} strokeLinecap="round" />
                </g>
                <path className={`kpLidLo kpLid${side}Lo`} d={`${edge} L ${x1} ${bottom} L ${x0} ${bottom} Z`} fill="url(#kpSkinLo)" />
            </g>
            {side === "R" ? (
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

// Feuer-Canvas: kleine Fläche – 6 % links/rechts und 26 % nach oben über das Bild hinaus, nur oberhalb der Kumpir (Wunsch Mehdi 2026-10-25)
const FIRE_L = 0.06;
const FIRE_T = 0.26;
const fx = (ix: number) => (FIRE_L + ix / W) / (1 + 2 * FIRE_L);
const fy = (iy: number) => (FIRE_T + iy / H) / (1 + FIRE_T);
const POTATO_FIRE: FireEmitter[] = [
    // linke Flammenbank hinter der Kumpir
    { x0: fx(290), x1: fx(540), y: fy(405), rate: 40, size: 0.05, rise: 0.2, life: 0.95, sway: 1, heat: 0.9, sparks: 2 },
    { x0: fx(268), x1: fx(330), y: fy(415), rate: 14, size: 0.038, rise: 0.16, life: 0.8, sway: 1.3, heat: 0.75 },
    // über dem Käsehügel
    { x0: fx(560), x1: fx(740), y: fy(275), rate: 22, size: 0.04, rise: 0.17, life: 0.85, sway: 1, heat: 0.85, sparks: 2 },
    // rechte Flammenbank
    { x0: fx(835), x1: fx(990), y: fy(425), rate: 34, size: 0.044, rise: 0.2, life: 0.95, sway: 1, heat: 0.9, sparks: 2 },
    // Zündschnur: Funkenregen
    { x0: fx(800), x1: fx(818), y: fy(219), rate: 0, size: 0.028, rise: 0.2, life: 0.5, sway: 0.6, heat: 1, sparks: 14 },
];

export function HomePotato() {
    const pct = (v: number, of: number) => `${((v / of) * 100).toFixed(3)}%`;
    // auf kleinen Bildschirmen weniger Flammen (Akku/Leistung)
    const [density, setDensity] = useState(1);
    useEffect(() => {
        const set = () => setDensity(window.innerWidth < 700 ? 0.6 : 1);
        set();
        window.addEventListener("resize", set);
        return () => window.removeEventListener("resize", set);
    }, []);
    const fire = useMemo(() => POTATO_FIRE, []);

    return (
        <div className="potatoBgImg kpStage">
            <div className="kpGlow" aria-hidden />
            <FireCanvas className="kpFire" emitters={fire} density={density} scale={0.6} fps={36} maxParticles={420} />
            <div className="kpTilt">
                <Image src="/HGLogo-v2.webp" alt="" width={900} height={600} priority quality={80} className="kpBase" />

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
                    <Lids eye={EYE_R} id="kpEyeR" side="R" />
                    <Lids eye={EYE_L} id="kpEyeL" side="L" />
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
                {/* Feuerschein: die gemalten Flammen flackern (zwei Lagen, verschieden schnell) */}
                <span className="kpFlick" />
                <span className="kpFlick b" />
            </div>
        </div>
    );
}
