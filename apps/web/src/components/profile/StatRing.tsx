"use client";

/**
 * Kleine Diagramm-Bausteine für Profil und Statistik (Wunsch Mehdi 2026-11-02): Ring für Quoten und Streifen für die letzten Ergebnisse.
 * Reines CSS/SVG, die Animation läuft beim Erscheinen von selbst (kein Zustand nötig).
 */
export function StatRing({ value, label, sub, size = 92, tone = "gold" }: { value: number; label: string; sub?: string; size?: number; tone?: "gold" | "green" | "blue" }) {
    const pct = Math.max(0, Math.min(100, Math.round(value)));
    const r = 40;
    const c = 2 * Math.PI * r;
    return (
        <figure className={`srRing ${tone}`} style={{ width: size }} aria-label={`${label}: ${pct} %`}>
            <svg viewBox="0 0 100 100" width={size} height={size} aria-hidden>
                <circle cx="50" cy="50" r={r} className="srTrack" />
                <circle cx="50" cy="50" r={r} className="srArc" style={{ ["--c" as string]: c, ["--to" as string]: c * (1 - pct / 100), strokeDasharray: c }} transform="rotate(-90 50 50)" />
                <text x="50" y="55" textAnchor="middle" className="srNum">
                    {pct}%
                </text>
            </svg>
            <figcaption>
                <b>{label}</b>
                {sub ? <small>{sub}</small> : null}
            </figcaption>
            <style>{`
        .srRing{ margin: 0; display: grid; justify-items: center; gap: 4px; text-align: center; }
        .srTrack{ fill: none; stroke: rgba(255,255,255,.12); stroke-width: 9; }
        .srArc{ fill: none; stroke-width: 9; stroke-linecap: round; stroke-dashoffset: var(--to); animation: srIn 1.2s cubic-bezier(.16,1,.3,1) both; filter: drop-shadow(0 0 5px rgba(255,200,60,.55)); }
        .srRing.gold .srArc{ stroke: #ffd23f; }
        .srRing.green .srArc{ stroke: #5eeaa0; filter: drop-shadow(0 0 5px rgba(80,230,150,.55)); }
        .srRing.blue .srArc{ stroke: #7cc8ff; filter: drop-shadow(0 0 5px rgba(120,190,255,.55)); }
        @keyframes srIn{ from{ stroke-dashoffset: var(--c); } }
        .srNum{ fill: #fff; font-family: var(--font-display); font-weight: 900; font-size: 22px; }
        .srRing figcaption{ display: grid; gap: 1px; }
        .srRing b{ font-size: 11px; font-weight: 800; letter-spacing: .6px; text-transform: uppercase; opacity: .85; }
        .srRing small{ font-size: 11.5px; font-weight: 700; opacity: .85; }
        @media (prefers-reduced-motion: reduce){ .srArc{ animation: none; } }
      `}</style>
        </figure>
    );
}

/** Die letzten Ergebnisse als Punktreihe: Gold = Platz 1, Silber = 2, Bronze = 3, grau = weiter hinten (älteste links). */
export function FormStrip({ places, label }: { places: number[]; label: string }) {
    if (!places.length) return null;
    return (
        <div className="fsWrap" aria-label={label}>
            <span className="fsLabel">{label}</span>
            <span className="fsDots">
                {places.map((p, i) => (
                    <i key={i} className={p === 1 ? "g" : p === 2 ? "s" : p === 3 ? "b" : ""} title={`#${p}`} style={{ animationDelay: `${i * 45}ms` }}>
                        {p}
                    </i>
                ))}
            </span>
            <style>{`
        .fsWrap{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .fsLabel{ font-size: 11px; font-weight: 800; letter-spacing: .8px; text-transform: uppercase; opacity: .85; }
        .fsDots{ display: flex; gap: 5px; flex-wrap: wrap; }
        .fsDots i{ width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-style: normal; font-size: 11px; font-weight: 900; color: #fff; background: rgba(255,255,255,.14); border: 1px solid rgba(255,255,255,.2); animation: fsPop .4s cubic-bezier(.34,1.56,.64,1) both; }
        .fsDots i.g{ background: linear-gradient(180deg, #ffe58a, #e0a420); color: #3d2600; border-color: #fff3b0; box-shadow: 0 0 10px rgba(255,214,10,.5); }
        .fsDots i.s{ background: linear-gradient(180deg, #f1f4f9, #a9b4c4); color: #1f2733; border-color: #fff; }
        .fsDots i.b{ background: linear-gradient(180deg, #f0b27a, #b9743a); color: #3a1c06; border-color: #ffdcb4; }
        @keyframes fsPop{ from{ opacity: 0; transform: scale(.3); } }
        @media (prefers-reduced-motion: reduce){ .fsDots i{ animation: none; } }
      `}</style>
        </div>
    );
}
