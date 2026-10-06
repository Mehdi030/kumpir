"use client";

import { useEffect, useRef, useState } from "react";

/**
 * Zählt eine Zahl weich von 0 (bzw. dem letzten Wert) auf den Zielwert hoch.
 * Akzeptiert Text wie "12", "3/19" oder "87%" – die erste Zahl wird animiert, der Rest bleibt stehen.
 */
export function CountUp({ value, duration = 900 }: { value: number | string; duration?: number }) {
    const text = String(value);
    const m = /^(\d+)(.*)$/.exec(text);
    const target = m ? Number(m[1]) : null;
    const rest = m ? m[2] : "";
    const [shown, setShown] = useState<number | null>(target);
    const from = useRef(0);

    useEffect(() => {
        if (target === null) return;
        if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
            const t = window.setTimeout(() => setShown(target), 0);
            return () => window.clearTimeout(t);
        }
        const start = performance.now();
        const a = from.current;
        let raf = 0;
        const tick = (now: number) => {
            const p = Math.min(1, (now - start) / duration);
            const eased = 1 - Math.pow(1 - p, 3);
            setShown(Math.round(a + (target - a) * eased));
            if (p < 1) raf = requestAnimationFrame(tick);
            else from.current = target;
        };
        raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
    }, [target, duration]);

    if (target === null) return <>{text}</>;
    return (
        <>
            {shown ?? target}
            {rest}
        </>
    );
}
