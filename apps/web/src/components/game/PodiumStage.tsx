"use client";

import { useEffect, useState } from "react";
import { PlayerAvatar, type AvatarConfig } from "@/components/game/PlayerAvatar";
import { playFanfare, playRankHit } from "@/lib/gameFx";
import { useI18n } from "@/lib/i18n";

export type PodiumPerson = {
    id: string;
    name: string;
    place: number;
    points: number;
    avatarConfig?: AvatarConfig | null;
    isMe?: boolean;
    /** höchster Erfolg des Spielers (Migration 137), falls angemeldet */
    badge?: { icon: string; title: string } | null;
};

/** Reihenfolge der Auftritte: Platz 3, dann 2, dann der Sieger (Sekunden nach Start) */
const REVEAL_S: Record<number, number> = { 3: 0.35, 2: 1.0, 1: 1.85 };

function CountUp({ to, delayS }: { to: number; delayS: number }) {
    const [v, setV] = useState(0);
    useEffect(() => {
        let raf = 0;
        const t0 = performance.now() + delayS * 1000;
        const dur = 900;
        const tick = (now: number) => {
            const k = Math.max(0, Math.min(1, (now - t0) / dur));
            setV(Math.round(to * (1 - Math.pow(1 - k, 3)) * 100) / 100);
            if (k < 1) raf = requestAnimationFrame(tick);
        };
        raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
    }, [to, delayS]);
    return <>{String(Number.isInteger(to) ? Math.round(v) : v).replace(".", ",")}</>;
}

/**
 * Siegerpodest am Ende (Wunsch Mehdi 2026-11-02): Bühne mit Scheinwerfern, drei Sockel aus Gold/Silber/Bronze,
 * die Plätze 3 → 2 → 1 treten nacheinander auf (mit Ton), Punkte zählen hoch, der Sieger bekommt Krone und Funkeln.
 */
export function PodiumStage({ people, mode = "original" }: { people: PodiumPerson[]; mode?: string }) {
    const { tr } = useI18n();
    const top = [...people].sort((a, b) => a.place - b.place).slice(0, 3);

    useEffect(() => {
        const timers: number[] = [];
        const places = new Set(top.map((p) => p.place));
        if (places.has(3)) timers.push(window.setTimeout(() => playRankHit(0.3), REVEAL_S[3] * 1000));
        if (places.has(2)) timers.push(window.setTimeout(() => playRankHit(0.65), REVEAL_S[2] * 1000));
        timers.push(window.setTimeout(() => playFanfare(), REVEAL_S[1] * 1000));
        return () => timers.forEach((t) => window.clearTimeout(t));
        // einmal beim Erscheinen – spätere Aktualisierungen der Liste sollen nicht noch mal jubeln
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    // links Platz 2, Mitte Platz 1, rechts Platz 3
    const order = top.length >= 3 ? [top[1], top[0], top[2]] : [top[1], top[0]];

    return (
        <div className="pdStage" data-mode={mode} role="img" aria-label={top.map((p) => `${p.place}. ${p.name}`).join(", ")}>
            <div className="pdBeam b1" aria-hidden />
            <div className="pdBeam b2" aria-hidden />
            <div className="pdBeam b3" aria-hidden />
            <div className="pdSteps" data-n={order.length}>
                {order.map((p) => {
                    const at = REVEAL_S[p.place] ?? 1;
                    const lead = p.place === 1;
                    return (
                        <div key={p.id} className={`pdStep p${Math.min(p.place, 3)}`} style={{ ["--at" as string]: `${at}s` }}>
                            <div className="pdFigure">
                                {lead ? (
                                    <>
                                        <span className="pdCrown" aria-hidden>👑</span>
                                        <i className="pdSpark s1" aria-hidden>✦</i>
                                        <i className="pdSpark s2" aria-hidden>✧</i>
                                        <i className="pdSpark s3" aria-hidden>✦</i>
                                    </>
                                ) : null}
                                <div className="pdAvatar">
                                    <PlayerAvatar seed={p.name} config={p.avatarConfig} size={lead ? 104 : 74} />
                                    <span className="pdMedal" aria-hidden>{["🥇", "🥈", "🥉"][Math.min(p.place, 3) - 1]}</span>
                                </div>
                                <div className="pdPlaque" title={p.name}>
                                    <span className="pdName">{p.name}</span>
                                    {p.badge ? (
                                        <span className="pdBadge" title={p.badge.title}>
                                            {p.badge.icon}
                                        </span>
                                    ) : null}
                                </div>
                            </div>
                            <div className="pdBlock">
                                {mode === "buzzer" ? <span className="pdBuzz" aria-hidden /> : null}
                                <span className="pdNo">{p.place}</span>
                                <span className="pdPts">
                                    <CountUp to={p.points} delayS={at + 0.2} /> {tr("P.")}
                                </span>
                            </div>
                        </div>
                    );
                })}
            </div>
            {mode === "year" ? (
                <div className="pdTimeline" aria-hidden>
                    {["1970", "1980", "1990", "2000", "2010", "2020"].map((y) => (
                        <span key={y}>{y}</span>
                    ))}
                </div>
            ) : null}
            <div className="pdFloor" aria-hidden />
            <style>{`
        .pdStage{ position: relative; width: min(640px, 100%); margin: 6px auto 0; padding: 22px 8px 0; isolation: isolate; }
        .pdFloor{ position: absolute; left: -4%; right: -4%; bottom: -14px; height: 34px; z-index: -1; border-radius: 50%;
          background: radial-gradient(ellipse at 50% 50%, rgba(255,226,140,.34), rgba(255,170,40,.10) 55%, transparent 72%); filter: blur(2px); }
        .pdBeam{ position: absolute; top: -30px; bottom: 6px; width: 34%; z-index: -1; pointer-events: none; opacity: 0;
          background: linear-gradient(180deg, rgba(255,246,214,.55), rgba(255,236,170,.10) 70%, transparent);
          clip-path: polygon(40% 0, 60% 0, 100% 100%, 0 100%); mix-blend-mode: screen; animation: pdBeamIn 1.2s var(--bd, .1s) ease-out forwards; }
        .pdBeam.b1{ left: 2%; --bd: .5s; } .pdBeam.b2{ left: 33%; --bd: 1.7s; width: 34%; } .pdBeam.b3{ right: 2%; --bd: .2s; }
        @keyframes pdBeamIn{ from{ opacity: 0; } to{ opacity: .85; } }
        .pdSteps{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); align-items: end; gap: 10px; }
        .pdSteps[data-n="2"]{ grid-template-columns: repeat(2, minmax(0, 1fr)); width: 72%; margin: 0 auto; }
        .pdStep{ display: grid; justify-items: center; align-content: end; min-width: 0; gap: 8px; opacity: 0; animation: pdRise .9s var(--at, 0s) cubic-bezier(.16,1,.3,1) forwards; }
        @keyframes pdRise{ from{ opacity: 0; transform: translateY(46px) scale(.92); } to{ opacity: 1; transform: none; } }
        .pdFigure{ position: relative; display: grid; justify-items: center; gap: 6px; max-width: 100%; }
        .pdAvatar{ position: relative; border-radius: 50%; padding: 4px; background: radial-gradient(circle at 38% 32%, rgba(255,246,214,.75), rgba(255,200,80,.28) 72%);
          box-shadow: 0 10px 26px rgba(0,0,0,.4); }
        .pdStep.p1 .pdAvatar{ box-shadow: 0 0 0 4px rgba(255,214,10,.55), 0 0 46px rgba(255,214,10,.5), 0 14px 30px rgba(0,0,0,.45); animation: pdBob 3.2s 2.6s ease-in-out infinite; }
        .pdStep.p2 .pdAvatar{ background: radial-gradient(circle at 38% 32%, #fff, rgba(200,214,235,.4) 72%); box-shadow: 0 0 0 3px rgba(226,232,240,.6), 0 12px 26px rgba(0,0,0,.4); }
        .pdStep.p3 .pdAvatar{ background: radial-gradient(circle at 38% 32%, #ffe9d2, rgba(214,134,70,.4) 72%); box-shadow: 0 0 0 3px rgba(222,148,84,.65), 0 12px 26px rgba(0,0,0,.4); }
        .pdMedal{ position: absolute; right: -8px; bottom: -6px; font-size: 26px; filter: drop-shadow(0 3px 5px rgba(0,0,0,.5)); }
        .pdStep.p1 .pdMedal{ font-size: 32px; }
        .pdCrown{ position: absolute; top: -34px; left: 50%; transform: translateX(-50%) rotate(-7deg); font-size: 40px; filter: drop-shadow(0 6px 8px rgba(0,0,0,.5)); animation: pdCrownIn .8s 2.2s cubic-bezier(.34,1.56,.64,1) both; }
        @keyframes pdCrownIn{ from{ opacity: 0; transform: translateX(-50%) translateY(-26px) rotate(-30deg) scale(.5); } }
        .pdSpark{ position: absolute; font-style: normal; color: #fff3b0; text-shadow: 0 0 12px rgba(255,214,10,.95); pointer-events: none; opacity: 0; animation: pdTwinkle 2.4s ease-in-out infinite; }
        .pdSpark.s1{ top: 6px; left: -22px; font-size: 22px; animation-delay: 2.4s; } .pdSpark.s2{ top: 36px; right: -26px; font-size: 26px; animation-delay: 3.0s; } .pdSpark.s3{ top: -14px; right: -6px; font-size: 16px; animation-delay: 3.5s; }
        @keyframes pdTwinkle{ 0%,100%{ opacity: 0; transform: scale(.4) rotate(0); } 50%{ opacity: 1; transform: scale(1.1) rotate(25deg); } }
        @keyframes pdBob{ 0%,100%{ transform: translateY(0); } 50%{ transform: translateY(-5px); } }
        .pdPlaque{ display: inline-flex; align-items: center; gap: 5px; max-width: 100%; padding: 4px 12px; border-radius: 999px; font-weight: 800; font-size: 14px;
          background: rgba(22,8,6,.55); border: 1px solid rgba(255,255,255,.2); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); }
        .pdStep.p1 .pdPlaque{ font-size: 17px; border-color: rgba(255,224,138,.75); background: rgba(60,34,4,.62); }
        .pdName{ overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
        .pdBadge{ font-size: 14px; flex: none; }
        .pdBlock{ position: relative; width: 100%; display: grid; justify-items: center; align-content: start; gap: 2px; padding-top: 12px; border-radius: 12px 12px 4px 4px; overflow: hidden;
          border: 1px solid rgba(255,255,255,.3); box-shadow: inset 0 2px 0 rgba(255,255,255,.35), inset 0 -18px 28px rgba(0,0,0,.28), 0 18px 30px rgba(0,0,0,.35); }
        .pdBlock::before{ content: ""; position: absolute; inset: 0; background: linear-gradient(105deg, transparent 38%, rgba(255,255,255,.34) 50%, transparent 62%); transform: translateX(-120%); animation: pdShine 4.5s 3s ease-in-out infinite; }
        @keyframes pdShine{ 0%,60%{ transform: translateX(-120%); } 100%{ transform: translateX(120%); } }
        .pdStep.p1 .pdBlock{ height: 150px; background: linear-gradient(180deg, #ffe58a, #e0a420 55%, #a86f08); border-color: rgba(255,240,180,.85); color: #3d2600; }
        .pdStep.p2 .pdBlock{ height: 108px; background: linear-gradient(180deg, #f1f4f9, #b4bfce 55%, #7d8899); border-color: rgba(255,255,255,.8); color: #1f2733; }
        .pdStep.p3 .pdBlock{ height: 78px; background: linear-gradient(180deg, #f0b27a, #c07a3e 55%, #8a5222); border-color: rgba(255,220,180,.7); color: #3a1c06; }
        .pdNo{ font-family: var(--font-display); font-size: 40px; font-weight: 900; line-height: 1; text-shadow: 0 1px 0 rgba(255,255,255,.5), 0 -1px 1px rgba(0,0,0,.25); }
        .pdStep.p3 .pdNo{ font-size: 30px; } .pdStep.p2 .pdNo{ font-size: 34px; }
        .pdPts{ font-size: 13px; font-weight: 900; letter-spacing: .3px; font-variant-numeric: tabular-nums; }
        /* ---- Modus-Looks (Wunsch Mehdi 2026-11-02): das Podest passt zum gespielten Spiel ---- */
        /* Roulette: Spielautomat – Lampenkranz um jeden Sockel, Ziffern wie auf Walzen */
        .pdStage[data-mode="letters"] .pdBlock{ border-radius: 14px 14px 4px 4px; border: 3px solid #1d0b2e; box-shadow: inset 0 2px 0 rgba(255,255,255,.4), inset 0 -18px 28px rgba(0,0,0,.28), 0 0 0 2px rgba(255,214,10,.55), 0 18px 30px rgba(0,0,0,.4); }
        .pdStage[data-mode="letters"] .pdBlock::after{ content: ""; position: absolute; left: 6px; right: 6px; top: 5px; height: 6px;
          background: radial-gradient(circle, #fff7c2 0 2px, transparent 2.6px) 0 0 / 14px 6px repeat-x; filter: drop-shadow(0 0 3px #ffd23f); animation: pdLamps 1.1s steps(2) infinite; }
        @keyframes pdLamps{ 50%{ background-position: 7px 0; opacity: .75; } }
        .pdStage[data-mode="letters"] .pdNo{ background: rgba(20,6,34,.82); color: #ffe08a; text-shadow: 0 0 10px rgba(255,214,10,.8); padding: 0 12px; border-radius: 8px; margin-top: 8px; box-shadow: inset 0 3px 8px rgba(0,0,0,.6); }
        .pdStage[data-mode="letters"] .pdPlaque{ background: rgba(34,10,52,.7); border-color: rgba(255,214,10,.6); }
        /* Buzzer: Game-Show-Pult – roter Buzzer oben auf jedem Sockel, Leuchtstreifen vorn */
        .pdStage[data-mode="buzzer"] .pdBlock{ border-radius: 10px 10px 3px 3px; overflow: visible; }
        .pdStage[data-mode="buzzer"] .pdBuzz{ position: absolute; top: -9px; left: 50%; width: 38px; height: 16px; transform: translateX(-50%); border-radius: 50% / 70% 70% 30% 30%;
          background: radial-gradient(ellipse at 50% 30%, #ff9a8c, #e5301f 55%, #8c1008); box-shadow: 0 3px 0 #5a0a05, 0 0 14px rgba(255,70,50,.7); animation: pdBuzz 2.4s ease-in-out infinite; }
        @keyframes pdBuzz{ 0%,100%{ box-shadow: 0 3px 0 #5a0a05, 0 0 8px rgba(255,70,50,.4); } 50%{ box-shadow: 0 3px 0 #5a0a05, 0 0 20px rgba(255,90,70,.95); } }
        .pdStage[data-mode="buzzer"] .pdBlock::after{ content: ""; position: absolute; left: 10%; right: 10%; bottom: 8px; height: 4px; border-radius: 4px; background: linear-gradient(90deg, transparent, rgba(255,255,255,.75), transparent); opacity: .7; }
        .pdStage[data-mode="buzzer"] .pdNo{ margin-top: 8px; }
        .pdStage[data-mode="buzzer"] .pdStep{ gap: 16px; }
        .pdStage[data-mode="buzzer"] .pdBlock::before{ display: none; }
        /* Zeitreise: Zeitleiste unter dem Podest, Sockel mit Skalenstrichen */
        .pdTimeline{ display: flex; justify-content: space-between; margin: 10px 4px 0; padding-top: 6px; font-size: 11px; font-weight: 800; letter-spacing: .5px; opacity: .85;
          border-top: 2px solid rgba(255,255,255,.5); background: repeating-linear-gradient(90deg, rgba(255,255,255,.5) 0 1px, transparent 1px 12px) 0 0 / 100% 6px no-repeat; }
        .pdStage[data-mode="year"] .pdBlock::after{ content: ""; position: absolute; inset: auto 0 0 0; height: 34%; background: repeating-linear-gradient(90deg, rgba(0,0,0,.2) 0 2px, transparent 2px 10px); }
        .pdStage[data-mode="year"] .pdFloor{ bottom: 18px; }
        @media (max-width: 899px){
          .pdStage{ padding-top: 30px; }
          .pdStep.p1 .pdBlock{ height: 104px; } .pdStep.p2 .pdBlock{ height: 76px; } .pdStep.p3 .pdBlock{ height: 54px; }
          .pdStep .pdAvatar img{ width: 54px !important; height: 54px !important; }
          .pdStep.p1 .pdAvatar img{ width: 74px !important; height: 74px !important; }
          .pdNo{ font-size: 30px; } .pdStep.p2 .pdNo{ font-size: 26px; } .pdStep.p3 .pdNo{ font-size: 22px; }
          .pdPlaque{ font-size: 12.5px; padding: 3px 9px; } .pdStep.p1 .pdPlaque{ font-size: 14px; }
          .pdCrown{ font-size: 30px; top: -26px; }
        }
        @media (min-width: 900px) and (max-height: 820px){
          .pdStage{ padding-top: 26px; width: min(520px, 100%); }
          .pdStep.p1 .pdBlock{ height: 104px; } .pdStep.p2 .pdBlock{ height: 76px; } .pdStep.p3 .pdBlock{ height: 54px; }
          .pdStep .pdAvatar img{ width: 56px !important; height: 56px !important; }
          .pdStep.p1 .pdAvatar img{ width: 78px !important; height: 78px !important; }
          .pdNo{ font-size: 30px; } .pdStep.p2 .pdNo{ font-size: 26px; } .pdStep.p3 .pdNo{ font-size: 22px; }
        }
        @media (prefers-reduced-motion: reduce){
          .pdStep, .pdCrown, .pdBeam{ animation-duration: .01s; animation-delay: 0s; }
          .pdBlock::before, .pdSpark, .pdStep.p1 .pdAvatar{ animation: none; }
        }
      `}</style>
        </div>
    );
}
