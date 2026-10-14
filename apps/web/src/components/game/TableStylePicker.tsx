"use client";

import { useEffect, useRef, useState } from "react";
import { TABLE_STYLES, setTableStyle, useTableStyle } from "@/lib/tableStyle";
import { useI18n } from "@/lib/i18n";

/** Kleiner Umschalter oben rechts im Spiel: Tisch-Stil wählen (gilt nur für dich, bleibt im Browser gemerkt). */
export function TableStylePicker() {
    const { tr } = useI18n();
    const current = useTableStyle();
    const [open, setOpen] = useState(false);
    const box = useRef<HTMLDivElement | null>(null);

    useEffect(() => {
        if (!open) return;
        const onDown = (e: PointerEvent) => {
            if (!box.current?.contains(e.target as Node)) setOpen(false);
        };
        const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
        document.addEventListener("pointerdown", onDown);
        document.addEventListener("keydown", onKey);
        return () => {
            document.removeEventListener("pointerdown", onDown);
            document.removeEventListener("keydown", onKey);
        };
    }, [open]);

    return (
        <div className="tsPick" ref={box}>
            <button type="button" className="tsBtn" onClick={() => setOpen((v) => !v)} aria-expanded={open} title={tr("Tisch-Stil")} aria-label={tr("Tisch-Stil")}>
                🎨
            </button>
            {open ? (
                <div className="tsPop" role="menu" aria-label={tr("Tisch-Stil")}>
                    <div className="tsHead">{tr("Tisch-Stil")}</div>
                    {TABLE_STYLES.map((s) => (
                        <button key={s.key} type="button" role="menuitemradio" aria-checked={current === s.key} className={`tsItem ${current === s.key ? "on" : ""}`} onClick={() => setTableStyle(s.key)}>
                            <span className="tsSwatch" style={{ background: s.swatch }} aria-hidden />
                            <span className="tsText">
                                <b>{tr(s.label)}</b>
                                <small>{tr(s.hint)}</small>
                            </span>
                            {current === s.key ? <span className="tsCheck">✓</span> : null}
                        </button>
                    ))}
                </div>
            ) : null}
            <style>{`
        .tsPick{ position: relative; }
        .tsBtn{ width: 40px; height: 40px; border-radius: 50%; border: 1px solid rgba(255,255,255,.2); background: rgba(14,12,24,.7); color: #fff; font-size: 18px; cursor: pointer; backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px); }
        .tsBtn:hover{ background: rgba(40,34,60,.85); }
        .tsPop{ position: absolute; right: 0; top: 46px; z-index: 80; width: 250px; padding: 8px; border-radius: 16px; display: grid; gap: 4px; background: rgba(18,14,28,.94); border: 1px solid rgba(255,255,255,.16);
          box-shadow: 0 18px 44px rgba(0,0,0,.5); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); animation: tsIn .2s cubic-bezier(.22,1,.36,1); }
        @keyframes tsIn{ from{ opacity: 0; transform: translateY(-6px) scale(.97); } }
        .tsHead{ padding: 4px 8px 6px; font-size: 11px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; color: rgba(255,255,255,.55); }
        .tsItem{ display: flex; align-items: center; gap: 10px; padding: 7px 8px; border-radius: 12px; border: 1px solid transparent; background: transparent; color: #fff; text-align: left; cursor: pointer; }
        .tsItem:hover{ background: rgba(255,255,255,.08); }
        .tsItem.on{ border-color: #ffd23f; background: rgba(255,210,63,.12); }
        .tsSwatch{ flex: none; width: 34px; height: 34px; border-radius: 50%; border: 2px solid rgba(255,255,255,.35); box-shadow: 0 2px 6px rgba(0,0,0,.4); }
        .tsText{ display: grid; line-height: 1.15; min-width: 0; flex: 1; }
        .tsText b{ font-size: 14px; font-weight: 900; }
        .tsText small{ font-size: 11px; opacity: .65; }
        .tsCheck{ color: #ffd23f; font-weight: 900; }
        @media (prefers-reduced-motion: reduce){ .tsPop{ animation: none; } }
      `}</style>
        </div>
    );
}
