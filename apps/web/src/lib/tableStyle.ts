"use client";

import { useSyncExternalStore } from "react";
import { tk } from "@/lib/i18nMark";

/**
 * Tisch-Stile für das normale Spiel (Wunsch Mehdi 2026-10-14: wieder mit Tisch, aber nicht wie am Roulette).
 * Gespeichert im Browser (localStorage), jeder wählt für sich. Die Optik steckt in PlayerRing (CSS-Klassen tbl-*).
 */
export type TableStyleKey = "felt" | "wood" | "midnight" | "ember" | "picnic" | "neon";

export const TABLE_STYLES: { key: TableStyleKey; label: string; hint: string; swatch: string }[] = [
    { key: "felt", label: tk("Filz"), hint: tk("Klassisch, dunkelgrün"), swatch: "radial-gradient(circle, #1f5a46, #0c2a22)" },
    { key: "wood", label: tk("Holz"), hint: tk("Warmer Stammtisch"), swatch: "repeating-linear-gradient(92deg, #8a5a2f 0 4px, #6e431e 4px 9px)" },
    { key: "midnight", label: tk("Mitternacht"), hint: tk("Dunkelblau, modern, ruhig"), swatch: "radial-gradient(circle, #24508a, #070f24)" },
    { key: "ember", label: tk("Glut"), hint: tk("Schwarz mit glühendem Ring"), swatch: "radial-gradient(circle, #5a2a10 0, #140704 70%)" },
    { key: "picnic", label: tk("Picknick"), hint: tk("Rot-weiß karierte Decke"), swatch: "repeating-linear-gradient(0deg, rgba(200,30,40,.7) 0 5px, transparent 5px 10px), repeating-linear-gradient(90deg, rgba(200,30,40,.7) 0 5px, transparent 5px 10px), #fbf3e6" },
    { key: "neon", label: tk("Neon"), hint: tk("Schwarz mit Leuchtringen"), swatch: "radial-gradient(circle, #1b0a2e 0, #05020a 60%), #05020a" },
];

const KEY = "kumpir_table_style";
const EVT = "kumpir:table-style";
const VALID = new Set<string>(TABLE_STYLES.map((s) => s.key));

function read(): TableStyleKey {
    try {
        const v = window.localStorage.getItem(KEY);
        return v && VALID.has(v) ? (v as TableStyleKey) : "felt";
    } catch {
        return "felt";
    }
}

export function setTableStyle(next: TableStyleKey) {
    try {
        window.localStorage.setItem(KEY, next);
    } catch {
        /* privater Modus */
    }
    window.dispatchEvent(new Event(EVT));
}

function subscribe(cb: () => void) {
    window.addEventListener(EVT, cb);
    window.addEventListener("storage", cb);
    return () => {
        window.removeEventListener(EVT, cb);
        window.removeEventListener("storage", cb);
    };
}

export function useTableStyle(): TableStyleKey {
    return useSyncExternalStore(subscribe, read, () => "felt");
}
