"use client";

import type { ReactNode } from "react";

/**
 * Auf-/Zurollen mit Animation (Wunsch Mehdi 2026-10-12): die Höhe läuft weich von 0 auf den Inhalt
 * (grid-template-rows 0fr -> 1fr), der Inhalt rollt dabei von oben herunter, Kinder mit `.rollItem`
 * kommen nacheinander herein. Bei "Bewegung reduzieren" im System ohne Animation.
 */
export function Collapse({ open, children, className = "", id }: { open: boolean; children: ReactNode; className?: string; id?: string }) {
    return (
        <div id={id} className={`kCollapse ${open ? "open" : ""} ${className}`} aria-hidden={!open} inert={!open}>
            <div className="kCollapseInner">{children}</div>
            <style>{`
        .kCollapse{ display: grid; grid-template-rows: 0fr; transition: grid-template-rows .45s cubic-bezier(.22,1,.36,1); }
        .kCollapse.open{ grid-template-rows: 1fr; }
        .kCollapseInner{ min-height: 0; overflow: hidden; transform-origin: top center;
          transform: perspective(700px) rotateX(-14deg) translateY(-8px); opacity: 0;
          transition: transform .45s cubic-bezier(.22,1,.36,1), opacity .3s ease; }
        .kCollapse.open .kCollapseInner{ transform: none; opacity: 1; }
        .kCollapse .rollItem{ opacity: 0; transform: translateY(-6px); transition: opacity .3s ease, transform .35s cubic-bezier(.22,1,.36,1); }
        .kCollapse.open .rollItem{ opacity: 1; transform: none; transition-delay: calc(var(--i, 0) * 45ms + 80ms); }
        @media (prefers-reduced-motion: reduce){
          .kCollapse, .kCollapseInner, .kCollapse .rollItem{ transition: none !important; }
        }
      `}</style>
        </div>
    );
}
