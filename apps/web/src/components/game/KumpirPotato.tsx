"use client";

import React, { useId } from "react";

type Props = {
    /** Kantenlänge in px (Breite = Höhe). */
    size?: number;
    /** 0..1: je heißer, desto stärker glühen die Risse und der Funke. */
    heat?: number;
    className?: string;
};

/**
 * Die Kumpir als gezeichnetes Spielobjekt: glänzende Knolle mit Schalen-Punkten,
 * glühenden Rissen und brennender Zündschnur. Reines SVG (skaliert scharf, kein Emoji).
 */
export function KumpirPotato({ size = 56, heat = 0, className }: Props) {
    const uid = useId().replace(/[^a-zA-Z0-9]/g, "");
    const h = Math.max(0, Math.min(1, heat));
    const glow = 0.25 + 0.75 * h;

    return (
        <svg className={className} width={size} height={size} viewBox="0 0 120 120" role="img" aria-label="Kumpir" style={{ overflow: "visible" }}>
            <defs>
                <radialGradient id={`body${uid}`} cx="36%" cy="30%" r="78%">
                    <stop offset="0%" stopColor="#ffe3a1" />
                    <stop offset="34%" stopColor="#e7b565" />
                    <stop offset="70%" stopColor="#b97a33" />
                    <stop offset="100%" stopColor="#7c4719" />
                </radialGradient>
                <linearGradient id={`shade${uid}`} x1="0" y1="0" x2="0" y2="1">
                    <stop offset="55%" stopColor="#3a1a05" stopOpacity="0" />
                    <stop offset="100%" stopColor="#2a1002" stopOpacity="0.55" />
                </linearGradient>
                <radialGradient id={`spark${uid}`} cx="50%" cy="50%" r="50%">
                    <stop offset="0%" stopColor="#fffbe0" />
                    <stop offset="35%" stopColor="#ffd23f" />
                    <stop offset="70%" stopColor="#ff7a1a" stopOpacity="0.85" />
                    <stop offset="100%" stopColor="#ff3d00" stopOpacity="0" />
                </radialGradient>
                <radialGradient id={`gloss${uid}`} cx="50%" cy="50%" r="50%">
                    <stop offset="0%" stopColor="#fff" stopOpacity="0.85" />
                    <stop offset="100%" stopColor="#fff" stopOpacity="0" />
                </radialGradient>
                <clipPath id={`clip${uid}`}>
                    <path d="M60 30 C86 27 106 46 104 71 C102 95 83 108 58 107 C33 106 15 91 17 67 C19 45 36 32 60 30 Z" />
                </clipPath>
            </defs>

            {/* Bodenschatten */}
            <ellipse cx="60" cy="110" rx="34" ry="6" fill="#000" opacity="0.28" />

            {/* Knolle */}
            <path d="M60 30 C86 27 106 46 104 71 C102 95 83 108 58 107 C33 106 15 91 17 67 C19 45 36 32 60 30 Z" fill={`url(#body${uid})`} />
            <g clipPath={`url(#clip${uid})`}>
                <rect x="0" y="0" width="120" height="120" fill={`url(#shade${uid})`} />
                {/* Schalen-Punkte */}
                <g fill="#6a3a13" opacity="0.5">
                    <ellipse cx="38" cy="52" rx="3.2" ry="2.1" />
                    <ellipse cx="78" cy="48" rx="2.6" ry="1.8" />
                    <ellipse cx="88" cy="74" rx="3.4" ry="2.2" />
                    <ellipse cx="30" cy="78" rx="2.8" ry="1.9" />
                    <ellipse cx="56" cy="90" rx="3" ry="2" />
                    <ellipse cx="68" cy="66" rx="2.2" ry="1.5" />
                    <ellipse cx="46" cy="68" rx="2" ry="1.4" />
                </g>
                {/* Augen der Kartoffel (Schalen-Kerben) */}
                <g fill="none" stroke="#5a3010" strokeWidth="1.6" strokeLinecap="round" opacity="0.55">
                    <path d="M50 58 q4 3 8 0" />
                    <path d="M72 82 q4 3 8 0" />
                    <path d="M28 64 q3 3 7 1" />
                </g>
                {/* Glühende Risse */}
                <g fill="none" stroke="#ff8a1f" strokeLinecap="round" strokeWidth="2.2" opacity={glow}>
                    <path d="M62 62 l6 8 l-3 6 l7 9" />
                    <path d="M40 84 l7 -5 l1 -7" />
                    <path d="M84 56 l-6 6" />
                </g>
                <g fill="none" stroke="#fff1b0" strokeLinecap="round" strokeWidth="0.9" opacity={glow * 0.9}>
                    <path d="M62 62 l6 8 l-3 6 l7 9" />
                    <path d="M40 84 l7 -5 l1 -7" />
                </g>
            </g>

            {/* Glanz */}
            <ellipse cx="45" cy="50" rx="18" ry="11" fill={`url(#gloss${uid})`} transform="rotate(-28 45 50)" opacity="0.8" />
            <ellipse cx="78" cy="92" rx="10" ry="4" fill="#fff" opacity="0.1" transform="rotate(-18 78 92)" />

            {/* Zündschnur */}
            <path d="M60 31 C58 20 66 14 74 10" fill="none" stroke="#3b2a14" strokeWidth="5.4" strokeLinecap="round" />
            <path d="M60 31 C58 20 66 14 74 10" fill="none" stroke="#d9c18a" strokeWidth="3.4" strokeLinecap="round" strokeDasharray="3 2" />
            {/* Funke */}
            <g className="kpSpark" style={{ transformOrigin: "75px 9px", transformBox: "view-box" as never }}>
                <circle cx="75" cy="9" r={11 + 6 * h} fill={`url(#spark${uid})`} opacity={0.75 + 0.25 * h} />
                <g stroke="#ffe27a" strokeWidth="1.6" strokeLinecap="round" opacity="0.95">
                    <path d="M75 -3 v5" />
                    <path d="M75 20 v-5" opacity="0.6" />
                    <path d="M64 9 h5" />
                    <path d="M86 9 h-5" />
                    <path d="M67 1 l3.5 3.5" />
                    <path d="M83 1 l-3.5 3.5" />
                </g>
                <circle cx="75" cy="9" r="3" fill="#fffbe6" />
            </g>
            <style>{`
              .kpSpark{ animation: kpFlicker .32s steps(2, end) infinite alternate; }
              @keyframes kpFlicker{ from{ transform: scale(.88) rotate(-6deg); opacity:.85; } to{ transform: scale(1.12) rotate(8deg); opacity:1; } }
              @media (prefers-reduced-motion: reduce){ .kpSpark{ animation: none; } }
            `}</style>
        </svg>
    );
}
