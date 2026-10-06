"use client";

import { usePathname } from "next/navigation";

/**
 * Aufsteigende Glutfunken im Hintergrund (nur Deko, hinter allem anderen).
 * Feste Werte statt Zufall → kein Hydration-Unterschied. Nicht im laufenden Spiel (dort stört es und kostet Leistung).
 */
const SPARKS = [
    { x: 6, s: 6, d: 0, t: 14 },
    { x: 14, s: 4, d: 3.5, t: 17 },
    { x: 22, s: 8, d: 7, t: 15 },
    { x: 31, s: 5, d: 1.8, t: 19 },
    { x: 39, s: 7, d: 9.2, t: 16 },
    { x: 47, s: 4, d: 5, t: 18 },
    { x: 55, s: 6, d: 12, t: 14 },
    { x: 63, s: 8, d: 2.6, t: 20 },
    { x: 71, s: 5, d: 8.3, t: 15 },
    { x: 79, s: 7, d: 4.4, t: 17 },
    { x: 87, s: 4, d: 10.6, t: 16 },
    { x: 94, s: 6, d: 6.1, t: 18 },
];

export function Embers() {
    const path = usePathname();
    if (path?.startsWith("/game")) return null;
    return (
        <div className="embers" aria-hidden>
            {SPARKS.map((p, i) => (
                <span key={i} style={{ left: `${p.x}%`, width: p.s, height: p.s, animationDelay: `${p.d}s`, animationDuration: `${p.t}s` }} />
            ))}
        </div>
    );
}
