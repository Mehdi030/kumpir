"use client";

/**
 * Platzhalter-Umrisse statt Drehscheibe (Wunsch Mehdi 2026-11-02): zeigt beim Laden schon die Form der Seite,
 * mit sanftem Schimmer. Für Screenreader steht ein kurzer Text bereit.
 *   rows  – Listenzeilen (Bestenliste), grid – Kacheln (Erfolge, Statistik), card – ein großer Block
 */
export function Skeleton({ kind = "rows", count = 5, label }: { kind?: "rows" | "grid" | "card"; count?: number; label: string }) {
    return (
        <div className={`skWrap ${kind}`} role="status" aria-busy="true" aria-label={label}>
            {kind === "card" ? (
                <i className="skBlock tall" />
            ) : (
                Array.from({ length: count }, (_, i) => <i key={i} className={`skBlock ${kind === "grid" ? "tile" : "row"}`} style={{ animationDelay: `${i * 90}ms` }} />)
            )}
            <style>{`
        .skWrap{ display: grid; gap: 8px; margin-top: 14px; }
        .skWrap.grid{ grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; }
        .skBlock{ display: block; border-radius: 14px; background: linear-gradient(100deg, rgba(255,255,255,.06) 20%, rgba(255,255,255,.2) 50%, rgba(255,255,255,.06) 80%) 0 0 / 220% 100%; border: 1px solid rgba(255,255,255,.08); animation: skShimmer 1.4s linear infinite; }
        .skBlock.row{ height: 46px; }
        .skBlock.tile{ height: 120px; border-radius: 18px; }
        .skBlock.tall{ height: 220px; border-radius: 22px; }
        @keyframes skShimmer{ from{ background-position: 120% 0; } to{ background-position: -120% 0; } }
        @media (prefers-reduced-motion: reduce){ .skBlock{ animation: none; } }
      `}</style>
        </div>
    );
}
