"use client";

import { useEffect } from "react";

/**
 * Zwei unsichtbare Feinheiten für die ganze App:
 *  1. Klick-Welle auf Knöpfen (.btn) – kurzer Lichtkreis an der Klickstelle.
 *  2. Lichtreflex auf Karten: setzt --mx/--my, damit der Glanz dem Mauszeiger folgt (nur Maus).
 * Läuft über Event-Delegation am Dokument (kein Eingriff in einzelne Seiten) und ist bei
 * "Bewegung reduzieren" komplett aus.
 */
const SPOT = ".card, .pillCard, .homeStep, .panel, .frCard, .playChoice";

export function UiFx() {
    useEffect(() => {
        if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

        const onDown = (e: PointerEvent) => {
            const el = (e.target as HTMLElement | null)?.closest?.<HTMLElement>(".btn");
            if (!el || (el as HTMLButtonElement).disabled || el.classList.contains("btnDisabled")) return;
            const r = el.getBoundingClientRect();
            const size = Math.max(r.width, r.height) * 2.2;
            const dot = document.createElement("span");
            dot.className = "kmRipple";
            dot.style.width = dot.style.height = `${size}px`;
            dot.style.left = `${e.clientX - r.left - size / 2}px`;
            dot.style.top = `${e.clientY - r.top - size / 2}px`;
            el.appendChild(dot);
            window.setTimeout(() => dot.remove(), 700);
        };

        let raf = 0;
        let pending: PointerEvent | null = null;
        const onMove = (e: PointerEvent) => {
            if (e.pointerType !== "mouse") return;
            pending = e;
            if (raf) return;
            raf = window.requestAnimationFrame(() => {
                raf = 0;
                const ev = pending;
                pending = null;
                if (!ev) return;
                const el = (ev.target as HTMLElement | null)?.closest?.<HTMLElement>(SPOT);
                if (!el) return;
                const r = el.getBoundingClientRect();
                el.style.setProperty("--mx", `${ev.clientX - r.left}px`);
                el.style.setProperty("--my", `${ev.clientY - r.top}px`);
            });
        };

        document.addEventListener("pointerdown", onDown, { passive: true });
        document.addEventListener("pointermove", onMove, { passive: true });
        return () => {
            document.removeEventListener("pointerdown", onDown);
            document.removeEventListener("pointermove", onMove);
            if (raf) window.cancelAnimationFrame(raf);
        };
    }, []);

    return null;
}
