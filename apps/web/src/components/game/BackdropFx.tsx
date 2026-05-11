"use client";

/**
 * Wiederverwendbare Hintergrund-Effekte (Grain + Orbs + Rays + Vignette).
 * Wird von der Game-Page in jeder Phase als gemeinsamer Backdrop genutzt.
 * Spart pro Phase ~30 Zeilen JSX + ~50 Zeilen CSS.
 *
 * `variant` steuert die Farbpalette der Orbs:
 *  - "warm"    (Topic-Vote, Finished — gelb/orange Töne)
 *  - "cool"    (Countdown — cyan/lila Töne)
 *  - "danger"  (Running — rot/orange Töne)
 */
type Props = {
    variant?: "warm" | "cool" | "danger";
    rays?: boolean;
    vignette?: boolean;
};

export function BackdropFx({ variant = "warm", rays = false, vignette = false }: Props) {
    return (
        <>
            <div className="kpFxGrain" aria-hidden />
            <div className="kpFxOrbs" aria-hidden>
                <span className={`kpFxOrb kpFxOrb1 ${variant}`} />
                <span className={`kpFxOrb kpFxOrb2 ${variant}`} />
                <span className={`kpFxOrb kpFxOrb3 ${variant}`} />
            </div>
            {rays ? <div className="kpFxRays" aria-hidden /> : null}
            {vignette ? <div className="kpFxVignette" aria-hidden /> : null}

            <style>{`
                .kpFxGrain {
                    position: absolute; inset: 0;
                    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)' opacity='.35'/%3E%3C/svg%3E");
                    opacity: .10; mix-blend-mode: overlay; pointer-events: none;
                }
                .kpFxOrbs { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
                .kpFxOrb {
                    position: absolute; border-radius: 999px;
                    filter: blur(24px); opacity: .75; mix-blend-mode: screen;
                    animation: kpFxOrbFloat 9s ease-in-out infinite;
                }
                .kpFxOrb1 { width: 520px; height: 520px; left: -140px; top: -140px; }
                .kpFxOrb2 { width: 420px; height: 420px; right: -160px; top: 30px; animation-delay: -1.2s; }
                .kpFxOrb3 { width: 720px; height: 720px; left: 18%; bottom: -340px; animation-delay: -2.0s; }

                .kpFxOrb1.warm   { background: radial-gradient(circle at 30% 30%, rgba(255,214,10,0.22), rgba(255,149,0,0.16), transparent 72%); }
                .kpFxOrb2.warm   { background: radial-gradient(circle at 30% 30%, rgba(34,211,238,0.16), rgba(167,139,250,0.12), transparent 72%); }
                .kpFxOrb3.warm   { background: radial-gradient(circle at 30% 30%, rgba(255,45,85,0.12), rgba(255,149,0,0.14), transparent 72%); }
                .kpFxOrb1.cool   { background: radial-gradient(circle at 30% 30%, rgba(34,211,238,0.20), rgba(167,139,250,0.16), transparent 72%); }
                .kpFxOrb2.cool   { background: radial-gradient(circle at 30% 30%, rgba(167,139,250,0.18), rgba(34,211,238,0.10), transparent 72%); }
                .kpFxOrb3.cool   { background: radial-gradient(circle at 30% 30%, rgba(52,199,89,0.10), rgba(34,211,238,0.10), transparent 72%); }
                .kpFxOrb1.danger { background: radial-gradient(circle at 30% 30%, rgba(255,45,85,0.20), rgba(255,149,0,0.14), transparent 72%); }
                .kpFxOrb2.danger { background: radial-gradient(circle at 30% 30%, rgba(255,69,58,0.16), rgba(255,149,0,0.10), transparent 72%); }
                .kpFxOrb3.danger { background: radial-gradient(circle at 30% 30%, rgba(255,69,58,0.14), rgba(143,15,15,0.18), transparent 72%); }

                .kpFxRays {
                    position: absolute; inset: -120px -120px;
                    background:
                        conic-gradient(from 210deg at 50% 18%,
                            rgba(255,255,255,0.10),
                            rgba(255,255,255,0.00) 22%,
                            rgba(255,214,10,0.08) 40%,
                            rgba(255,255,255,0.00) 60%,
                            rgba(34,211,238,0.08) 76%,
                            rgba(255,255,255,0.00) 100%);
                    filter: blur(12px); opacity: .75; mix-blend-mode: overlay;
                    animation: kpFxRaysSpin 26s linear infinite;
                    pointer-events: none;
                }
                .kpFxVignette {
                    position: absolute; inset: 0;
                    background: radial-gradient(circle at 50% 40%, rgba(0,0,0,0) 0%, rgba(0,0,0,0.22) 60%, rgba(0,0,0,0.55) 100%);
                    pointer-events: none;
                }
                @media (prefers-reduced-motion: reduce) {
                    .kpFxOrb, .kpFxRays { animation: none !important; }
                }
                @keyframes kpFxOrbFloat {
                    0%, 100% { transform: translateY(0) translateX(0); }
                    50% { transform: translateY(18px) translateX(10px); }
                }
                @keyframes kpFxRaysSpin {
                    0% { transform: rotate(0deg); }
                    100% { transform: rotate(360deg); }
                }
            `}</style>
        </>
    );
}
