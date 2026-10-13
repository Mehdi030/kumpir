"use client";

import { useRef, useState, type ReactNode } from "react";
import { useI18n } from "@/lib/i18n";

export type SwipeOption<T> = { value: T; icon: string; label: ReactNode; title?: string };

/**
 * Kachel oben in der Lobby (Spieler, Modus, Runden, Sichtbarkeit). Der Host ändert den Wert direkt in der
 * Kachel (Wunsch Mehdi 2026-10-13, ersetzt die Einstellungen-Seite):
 *  - wischen (links/rechts) oder die kleinen Pfeile ‹ › antippen
 *  - Kachel antippen = nächster Wert
 *  - Pfeiltasten, wenn die Kachel den Fokus hat
 * Für alle anderen ist es eine normale Anzeige.
 */
export function SwipeStat<T extends string | number>({
    label,
    options,
    value,
    onChange,
    editable,
    className = "",
}: {
    label: string;
    options: SwipeOption<T>[];
    value: T;
    onChange: (next: T) => void;
    editable: boolean;
    className?: string;
}) {
    const { tr } = useI18n();
    const idx = Math.max(0, options.findIndex((o) => o.value === value));
    const cur = options[idx] ?? options[0];
    const [dir, setDir] = useState<"l" | "r" | "">("");
    const drag = useRef<{ x: number; y: number; moved: boolean } | null>(null);
    const canEdit = editable && options.length > 1;

    const step = (d: 1 | -1) => {
        if (!canEdit) return;
        const n = options[(idx + d + options.length) % options.length];
        setDir(d > 0 ? "r" : "l");
        onChange(n.value);
    };

    return (
        <div
            className={`lobbyStat swStat ${canEdit ? "edit" : ""} ${className}`}
            role={canEdit ? "spinbutton" : undefined}
            aria-label={label}
            aria-valuetext={typeof cur?.label === "string" ? cur.label : undefined}
            tabIndex={canEdit ? 0 : undefined}
            title={canEdit ? tr("Wischen oder antippen zum Ändern") : cur?.title}
            onKeyDown={(e) => {
                if (!canEdit) return;
                if (e.key === "ArrowRight" || e.key === "ArrowUp") {
                    e.preventDefault();
                    step(1);
                } else if (e.key === "ArrowLeft" || e.key === "ArrowDown") {
                    e.preventDefault();
                    step(-1);
                } else if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    step(1);
                }
            }}
            onPointerDown={(e) => {
                if (!canEdit) return;
                drag.current = { x: e.clientX, y: e.clientY, moved: false };
            }}
            onPointerMove={(e) => {
                const d = drag.current;
                if (!d || d.moved) return;
                const dx = e.clientX - d.x;
                if (Math.abs(dx) > 28 && Math.abs(dx) > Math.abs(e.clientY - d.y)) {
                    d.moved = true;
                    step(dx < 0 ? 1 : -1);
                }
            }}
            onPointerUp={(e) => {
                const d = drag.current;
                drag.current = null;
                if (!d || d.moved) return;
                // Tippen (nicht auf die Pfeile – die haben eigene Klicks)
                if ((e.target as HTMLElement).closest(".swArrow")) return;
                step(1);
            }}
            onPointerCancel={() => (drag.current = null)}
            style={{ touchAction: canEdit ? "pan-y" : undefined }}
        >
            {canEdit ? (
                <>
                    <button type="button" className="swArrow l" tabIndex={-1} aria-label={tr("Zurück")} onClick={() => step(-1)}>
                        ‹
                    </button>
                    <button type="button" className="swArrow r" tabIndex={-1} aria-label={tr("Weiter")} onClick={() => step(1)}>
                        ›
                    </button>
                </>
            ) : null}
            <span key={String(cur?.value)} className={`swSlide ${dir}`}>
                <span className="lobbyStatIcon" aria-hidden>
                    {cur?.icon}
                </span>
                <span className={`lobbyStatValue ${typeof cur?.label === "string" && cur.label.length > 9 ? "long" : ""}`}>{cur?.label}</span>
            </span>
            <span className="lobbyStatLabel">{label}</span>
            {canEdit && options.length <= 12 ? (
                <span className="swDots" aria-hidden>
                    {options.map((o, i) => (
                        <i key={String(o.value)} className={i === idx ? "on" : ""} />
                    ))}
                </span>
            ) : null}
            <style>{`
        .swStat{ position: relative; overflow: hidden; user-select: none; -webkit-user-select: none; }
        .swStat.edit{ cursor: grab; border-color: rgba(255,210,63,.45); background: linear-gradient(180deg, rgba(255,210,63,.13), rgba(255,255,255,.06)); }
        .swStat.edit:hover{ border-color: #ffd23f; }
        .swStat.edit:active{ cursor: grabbing; }
        .swStat.edit:focus-visible{ outline: 3px solid #ffd23f; outline-offset: 2px; }
        .swSlide{ display: grid; justify-items: center; gap: 2px; min-width: 0; max-width: 100%; }
        .swSlide.r{ animation: swInR .32s cubic-bezier(.22,1,.36,1); }
        .swSlide.l{ animation: swInL .32s cubic-bezier(.22,1,.36,1); }
        @keyframes swInR{ from{ opacity: 0; transform: translateX(38%); } }
        @keyframes swInL{ from{ opacity: 0; transform: translateX(-38%); } }
        .lobbyStatValue.long{ font-size: clamp(14px, 2.2vw, 19px) !important; white-space: normal !important; line-height: 1.15; }
        .swArrow{ position: absolute; top: 0; bottom: 0; width: 26px; border: 0; background: transparent; color: #ffe08a; font-size: 24px; font-weight: 900;
          cursor: pointer; opacity: .55; transition: opacity .15s ease, background .15s ease; z-index: 1; padding: 0; }
        .swArrow.l{ left: 0; } .swArrow.r{ right: 0; }
        .swArrow:hover{ opacity: 1; background: rgba(255,255,255,.08); }
        .swDots{ display: flex; gap: 3px; justify-content: center; margin-top: 3px; flex-wrap: wrap; max-width: 80%; }
        .swDots i{ width: 5px; height: 5px; border-radius: 50%; background: rgba(255,255,255,.3); transition: background .2s ease, transform .2s ease; }
        .swDots i.on{ background: #ffd23f; transform: scale(1.35); }
        @media (prefers-reduced-motion: reduce){ .swSlide{ animation: none !important; } }
      `}</style>
        </div>
    );
}
