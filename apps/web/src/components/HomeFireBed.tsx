"use client";

import { useEffect, useState } from "react";
import { FireCanvas, type FireEmitter } from "@/components/FireCanvas";

/**
 * Glutbett am unteren Rand der Startseite (Wunsch Mehdi 2026-10-25): breite Flammenzungen und Funken steigen hinter der Karte auf,
 * am Rand daneben sieht man sie lodern. Nur Deko, hinter allem anderen; auf dem Handy mit weniger Flammen.
 */
const COUNT = 9;
const BED: FireEmitter[] = Array.from({ length: COUNT }, (_, i) => ({
    x0: i / COUNT - 0.02,
    x1: (i + 1) / COUNT + 0.02,
    y: 1.04,
    rate: 8,
    size: 0.06 + (i % 3) * 0.012,
    rise: 0.36,
    life: 1.9 + (i % 4) * 0.2,
    sway: 1.2,
    heat: 0.7 + ((i * 37) % 10) / 40,
    sparks: 2.2,
}));

export function HomeFireBed() {
    const [density, setDensity] = useState(1);
    useEffect(() => {
        const set = () => setDensity(window.innerWidth < 700 ? 0.45 : 1);
        set();
        window.addEventListener("resize", set);
        return () => window.removeEventListener("resize", set);
    }, []);
    return (
        <div className="homeFireBed" aria-hidden>
            <FireCanvas className="homeFireCv" emitters={BED} density={density} scale={0.4} fps={30} maxParticles={320} />
        </div>
    );
}
