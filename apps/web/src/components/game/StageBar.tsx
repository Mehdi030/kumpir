"use client";

import { PlayerAvatar, type AvatarConfig } from "@/components/game/PlayerAvatar";
import { useI18n } from "@/lib/i18n";

export type StageStat = { key: string; label: string; value: string; title?: string; tone?: "duel" | "overtime" | "opt" };

/**
 * Große Leiste oben im Spiel (Wunsch Mehdi 2026-10-13, ersetzt die kleine Info-Leiste):
 *  - links: wer gerade dran ist – großer Avatar + Name, wechselt mit Animation
 *  - Mitte: die Zündschnur brennt ab (Funken am Ende, wird zum Schluss rot und zittert)
 *  - rechts: Spielstand (Playlist, Runde, Zug, Tempo, Im Spiel)
 */
export function StageBar({
    holderId,
    holderName,
    holderAvatar,
    holderIsMe,
    heat,
    fuseActive,
    stats,
}: {
    holderId: string | null;
    holderName: string;
    holderAvatar: AvatarConfig | null;
    holderIsMe: boolean;
    /** 0 = Zündschnur voll, 1 = gleich knallt es */
    heat: number;
    fuseActive: boolean;
    stats: StageStat[];
}) {
    const { tr } = useI18n();
    const h = Math.max(0, Math.min(1, heat));
    const left = fuseActive ? 1 - h : 1;
    const stage = h > 0.85 ? "crit" : h > 0.66 ? "hot" : h > 0.4 ? "warm" : "calm";

    return (
        <div className={`stageBar ${stage} ${holderIsMe ? "mine" : ""}`} role="group" aria-label={tr("Spielstand")}>
            <div className="sbHolder" key={holderId ?? "none"}>
                <span className="sbAvatar">
                    <PlayerAvatar seed={holderName} config={holderAvatar} mood={h > 0.66 ? "panic" : "normal"} size={58} />
                    <span className="sbPotato" aria-hidden>
                        🥔
                    </span>
                </span>
                <span className="sbWho">
                    <small>{holderIsMe ? tr("Du bist dran!") : tr("Am Zug")}</small>
                    <b title={holderName}>{holderIsMe ? tr("Du") : holderName}</b>
                </span>
            </div>

            <div className="sbFuse" aria-hidden>
                <div className="sbFuseTrack">
                    <div className="sbFuseRope" style={{ transform: `scaleX(${left})` }} />
                    {fuseActive ? (
                        <span className="sbSpark" style={{ left: `${left * 100}%` }}>
                            <i />
                            <i />
                            <i />
                            <i />
                        </span>
                    ) : null}
                </div>
                <span className="sbFuseLabel">
                    {!fuseActive ? tr("Zündschnur") : stage === "crit" ? tr("Gleich knallt's!") : stage === "hot" ? tr("Es wird heiß!") : tr("Zündschnur brennt")}
                </span>
            </div>

            <div className="sbStats">
                {stats.map((s) => (
                    <div key={s.key} className={`sbStat ${s.tone ?? ""}`} title={s.title}>
                        <span className="sbLabel">{s.label}</span>
                        <span className="sbValue">{s.value}</span>
                    </div>
                ))}
            </div>

            <style>{`
        .stageBar{ position: fixed; top: 12px; left: 50%; transform: translateX(-50%); z-index: 55; width: min(1040px, calc(100vw - 250px));
          display: grid; grid-template-columns: minmax(150px, .9fr) minmax(180px, 1.4fr) auto; align-items: center; gap: 16px; padding: 10px 14px;
          border-radius: 22px; background: linear-gradient(180deg, rgba(28,24,40,.86), rgba(14,12,24,.86)); border: 1px solid rgba(255,255,255,.14);
          box-shadow: 0 16px 44px rgba(0,0,0,.42), inset 0 1px 0 rgba(255,255,255,.08); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
          transition: border-color .4s ease, box-shadow .4s ease; }
        .stageBar.hot{ border-color: rgba(255,140,60,.55); }
        .stageBar.crit{ border-color: rgba(255,70,50,.85); box-shadow: 0 16px 44px rgba(0,0,0,.42), 0 0 34px rgba(255,60,40,.35); animation: sbShake .35s linear infinite; }
        .stageBar.mine{ background: linear-gradient(180deg, rgba(70,30,14,.9), rgba(36,14,8,.9)); }
        @keyframes sbShake{ 0%,100%{ transform: translateX(-50%); } 25%{ transform: translateX(calc(-50% - 1.5px)); } 75%{ transform: translateX(calc(-50% + 1.5px)); } }

        .sbHolder{ display: flex; align-items: center; gap: 12px; min-width: 0; animation: sbIn .45s cubic-bezier(.16,1,.3,1); }
        @keyframes sbIn{ from{ opacity: 0; transform: translateX(-24px) scale(.94); } }
        .sbAvatar{ position: relative; flex: none; width: 62px; height: 62px; border-radius: 50%; display: grid; place-items: center;
          background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.5), rgba(255,170,30,.15) 70%); box-shadow: 0 0 0 3px #ffd23f, 0 0 22px rgba(255,210,63,.45); }
        .sbAvatar img{ width: 58px; height: 58px; border-radius: 50%; }
        .sbPotato{ position: absolute; right: -8px; bottom: -6px; font-size: 24px; filter: drop-shadow(0 3px 4px rgba(0,0,0,.5)); animation: sbBob 1.2s ease-in-out infinite; }
        .stageBar.hot .sbPotato, .stageBar.crit .sbPotato{ animation-duration: .45s; }
        @keyframes sbBob{ 0%,100%{ transform: rotate(-8deg); } 50%{ transform: rotate(10deg) translateY(-2px); } }
        .sbWho{ display: grid; min-width: 0; line-height: 1.1; }
        .sbWho small{ font-size: 10.5px; font-weight: 900; letter-spacing: 1.4px; text-transform: uppercase; color: #ffd23f; }
        .sbWho b{ font-family: var(--font-display); font-size: clamp(20px, 2.4vw, 28px); font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

        .sbFuse{ display: grid; gap: 6px; min-width: 0; }
        .sbFuseTrack{ position: relative; height: 14px; border-radius: 999px; background: rgba(255,255,255,.1); box-shadow: inset 0 1px 3px rgba(0,0,0,.5); }
        .sbFuseRope{ position: absolute; inset: 0; border-radius: 999px; transform-origin: left center; transition: transform .25s linear, background .5s ease;
          background: repeating-linear-gradient(-45deg, #c98a3c 0 6px, #a86a28 6px 12px); }
        .stageBar.warm .sbFuseRope{ background: repeating-linear-gradient(-45deg, #e09a3a 0 6px, #c4761f 6px 12px); }
        .stageBar.hot .sbFuseRope{ background: repeating-linear-gradient(-45deg, #f07a2a 0 6px, #d35418 6px 12px); }
        .stageBar.crit .sbFuseRope{ background: repeating-linear-gradient(-45deg, #ff4a3a 0 6px, #d02018 6px 12px); }
        .sbSpark{ position: absolute; top: 50%; width: 0; height: 0; transition: left .25s linear; }
        .sbSpark::before{ content: ""; position: absolute; left: -9px; top: -9px; width: 18px; height: 18px; border-radius: 50%;
          background: radial-gradient(circle, #fff6c2 0, #ffd23f 35%, rgba(255,120,40,.6) 60%, transparent 72%); animation: sbGlow .3s ease-in-out infinite alternate; }
        .sbSpark i{ position: absolute; left: -2px; top: -2px; width: 4px; height: 4px; border-radius: 50%; background: #ffd23f; animation: sbFly .6s linear infinite; }
        .sbSpark i:nth-child(1){ --x: -12px; --y: -14px; }
        .sbSpark i:nth-child(2){ --x: 8px; --y: -16px; animation-delay: .15s; }
        .sbSpark i:nth-child(3){ --x: -6px; --y: 12px; animation-delay: .3s; background: #ff8a3c; }
        .sbSpark i:nth-child(4){ --x: 12px; --y: 10px; animation-delay: .45s; }
        @keyframes sbFly{ from{ opacity: 1; transform: translate(0,0) scale(1); } to{ opacity: 0; transform: translate(var(--x), var(--y)) scale(.3); } }
        @keyframes sbGlow{ from{ transform: scale(.85); } to{ transform: scale(1.2); } }
        .sbFuseLabel{ font-size: 11px; font-weight: 900; letter-spacing: 1px; text-transform: uppercase; opacity: .7; }
        .stageBar.hot .sbFuseLabel{ color: #ffb37a; opacity: 1; }
        .stageBar.crit .sbFuseLabel{ color: #ff8a7a; opacity: 1; }

        .sbStats{ display: flex; gap: 2px; }
        .sbStat{ display: grid; gap: 1px; padding: 4px 10px; text-align: center; border-radius: 12px; }
        .sbStat + .sbStat{ border-left: 1px solid rgba(255,255,255,.1); border-radius: 0; }
        .sbLabel{ font-size: 9.5px; font-weight: 900; letter-spacing: 1.2px; text-transform: uppercase; color: rgba(255,255,255,.5); white-space: nowrap; }
        .sbValue{ font-size: 15px; font-weight: 900; white-space: nowrap; max-width: 170px; overflow: hidden; text-overflow: ellipsis; }
        .sbStat.duel{ background: rgba(150,20,20,.45); }
        .sbStat.duel .sbValue, .sbStat.overtime .sbValue{ color: #ffc2b8; }

        @media (max-width: 1000px){ .sbStat.opt{ display: none; } }
        @media (max-width: 760px){
          .stageBar{ top: 60px; width: calc(100vw - 16px); grid-template-columns: minmax(0, 1fr) auto; gap: 8px 10px; padding: 8px 10px; border-radius: 18px; }
          .sbFuse{ grid-column: 1 / -1; grid-row: 2; }
          .sbAvatar{ width: 46px; height: 46px; } .sbAvatar img{ width: 42px; height: 42px; }
          .sbPotato{ font-size: 18px; }
          .sbStat{ padding: 2px 7px; } .sbValue{ font-size: 13px; } .sbLabel{ font-size: 8.5px; letter-spacing: .6px; }
        }
        @media (prefers-reduced-motion: reduce){ .stageBar, .sbHolder, .sbPotato, .sbSpark::before, .sbSpark i{ animation: none !important; } }
      `}</style>
        </div>
    );
}

/** Herzschlag am Bildschirmrand, wenn es knapp wird – immer schneller, für alle sichtbar (für den Halter stärker). */
export function HeartbeatEdge({ heat, strong }: { heat: number; strong: boolean }) {
    const h = Math.max(0, Math.min(1, heat));
    if (h < 0.66) return null;
    // in Stufen, damit die Animation nicht bei jedem Rendern neu startet
    const lvl = Math.round(((h - 0.66) / 0.34) * 4) / 4;
    const dur = (1.1 - lvl * 0.6).toFixed(2);
    return (
        <div className={`hbEdge ${strong ? "strong" : ""}`} style={{ ["--dur" as string]: `${dur}s`, ["--lvl" as string]: lvl }} aria-hidden>
            <style>{`
        .hbEdge{ position: fixed; inset: 0; z-index: 4; pointer-events: none; animation: hbBeat var(--dur) ease-in-out infinite; }
        @keyframes hbBeat{
          0%, 100%{ box-shadow: inset 0 0 0 0 rgba(255,50,40,0); }
          15%{ box-shadow: inset 0 0 calc(40px + var(--lvl) * 50px) calc(4px + var(--lvl) * 6px) rgba(255,50,40,.38); }
          30%{ box-shadow: inset 0 0 calc(20px + var(--lvl) * 20px) 0 rgba(255,50,40,.12); }
          45%{ box-shadow: inset 0 0 calc(34px + var(--lvl) * 40px) calc(2px + var(--lvl) * 4px) rgba(255,50,40,.3); }
        }
        .hbEdge:not(.strong){ opacity: .55; }
        @media (prefers-reduced-motion: reduce){ .hbEdge{ animation: none; box-shadow: inset 0 0 40px 2px rgba(255,50,40,.25); } }
      `}</style>
        </div>
    );
}
