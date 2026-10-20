"use client";

import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { fmtNum, useI18n } from "@/lib/i18n";
import { catIcon } from "@/lib/rouletteCats";

type RouletteStatsData = {
    matches: number;
    wins: number;
    practiceMatches: number;
    rounds: number;
    words: number;
    bad: number;
    bestRound: { correct: number; category: string; letter: string } | null;
    categories: { name: string; rounds: number; words: number; best: number; avg: number }[];
    recent: { category: string; letter: string; correct: number; place: number; ranked: boolean; at: string }[];
};

/** Eigene Roulette-Auswertung (Migration 130): Spiele, Siege, richtige Wörter, Trefferquote, beste Runde, Kategorien, letzte Runden. */
export function RouletteStats({ userId }: { userId: string }) {
    const { tr } = useI18n();
    const [d, setD] = useState<RouletteStatsData | null>(null);

    useEffect(() => {
        let cancel = false;
        void getSupabaseClient()
            .rpc("get_my_roulette_stats")
            .then(({ data, error }) => {
                if (!cancel && !error && data) setD(data as RouletteStatsData);
            });
        return () => {
            cancel = true;
        };
    }, [userId]);

    if (!d || d.rounds === 0) {
        return d ? (
            <section className="rsStat" aria-label={tr("Roulette")}>
                <h2>🎰 {tr("Roulette")}</h2>
                <p className="rsStatEmpty">{tr("Noch keine Roulette-Runde gespielt – danach siehst du hier deine Wörter, Kategorien und Bestleistungen.")}</p>
                <style>{CSS}</style>
            </section>
        ) : null;
    }

    const attempts = d.words + d.bad;
    const acc = attempts > 0 ? Math.round((d.words / attempts) * 100) : 0;
    const boxes: [string, string][] = [
        [tr("Spiele"), String(d.matches)],
        [tr("Siege"), String(d.wins)],
        [tr("Richtige Wörter"), fmtNum(d.words, 0)],
        [tr("Trefferquote"), `${acc} %`],
    ];
    const maxWords = Math.max(1, ...d.categories.map((c) => c.words));

    return (
        <section className="rsStat" aria-label={tr("Roulette")}>
            <h2>🎰 {tr("Roulette")}</h2>
            <div className="rsStatBoxes">
                {boxes.map(([l, v]) => (
                    <div key={l} className="rsStatBox">
                        <div className="rsStatLabel">{l}</div>
                        <div className="rsStatValue">{v}</div>
                    </div>
                ))}
            </div>
            {d.bestRound ? (
                <div className="rsBest">
                    <span className="rsBestLetter">{d.bestRound.letter}</span>
                    <div>
                        <small>{tr("Beste Runde")}</small>
                        <b>
                            {d.bestRound.correct} {tr("richtige Wörter")}
                        </b>
                        <span>
                            {catIcon(d.bestRound.category)} {d.bestRound.category}
                        </span>
                    </div>
                </div>
            ) : null}
            {d.practiceMatches > 0 ? <p className="rsStatNote">{tr("Dazu {n} Übungsspiele (zählen nicht für Spiele und Siege).", { n: d.practiceMatches })}</p> : null}
            <h3>{tr("Deine Kategorien")}</h3>
            <ul className="rsCatList">
                {d.categories.slice(0, 8).map((c, i) => (
                    <li key={c.name}>
                        <span className="rsCatName">
                            {i === 0 ? "⭐ " : ""}
                            {catIcon(c.name)} {c.name}
                        </span>
                        <span className="rsCatBar" aria-hidden>
                            <i style={{ width: `${Math.max(6, (c.words / maxWords) * 100)}%` }} />
                        </span>
                        <span className="rsCatNum">
                            {c.words} <small>{tr("Wörter")}</small> · Ø {fmtNum(c.avg)} · {tr("Bestwert")} {c.best}
                        </span>
                    </li>
                ))}
            </ul>
            <h3>{tr("Letzte Runden")}</h3>
            <ul className="rsRecent">
                {d.recent.map((r, i) => (
                    <li key={i}>
                        <span className="rsRecentLetter">{r.letter}</span>
                        <span>
                            {catIcon(r.category)} {r.category}
                        </span>
                        <b>{r.correct}</b>
                        <span className={`rsPlace ${r.place === 1 ? "first" : ""}`}>{r.place === 1 ? "🥇" : `${r.place}.`}</span>
                    </li>
                ))}
            </ul>
            <style>{CSS}</style>
        </section>
    );
}

const CSS = `
.rsStat{ margin-top: 18px; padding: 16px; border-radius: 22px; background: rgba(255,255,255,.05); border: 1px solid rgba(255,255,255,.14); display: grid; gap: 12px; }
.rsStat h2{ margin: 0; font-size: 22px; }
.rsStat h3{ margin: 6px 0 0; font-size: 13px; font-weight: 900; letter-spacing: 1.2px; text-transform: uppercase; opacity: .7; }
.rsStatEmpty{ margin: 0; opacity: .75; font-weight: 700; }
.rsStatBoxes{ display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 10px; }
.rsStatBox{ padding: 12px; border-radius: 16px; background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.12); text-align: center; display: grid; gap: 4px; }
.rsStatLabel{ font-size: 10.5px; font-weight: 800; letter-spacing: .6px; text-transform: uppercase; opacity: .7; }
.rsStatValue{ font-size: 24px; font-weight: 950; }
.rsStatNote{ margin: 0; font-size: 12.5px; font-weight: 700; opacity: .65; }
.rsBest{ display: flex; align-items: center; gap: 14px; padding: 12px 14px; border-radius: 18px; background: linear-gradient(160deg, rgba(255,210,63,.25), rgba(255,140,40,.08)); border: 1px solid rgba(255,210,63,.5); }
.rsBest > div{ display: grid; gap: 1px; }
.rsBest small{ font-size: 10.5px; font-weight: 900; letter-spacing: 1.2px; text-transform: uppercase; opacity: .75; }
.rsBest b{ font-size: 20px; }
.rsBest span:not(.rsBestLetter){ font-size: 13px; font-weight: 800; opacity: .85; }
.rsBestLetter{ flex: none; width: 52px; height: 52px; border-radius: 15px; display: grid; place-items: center; font-family: var(--font-display); font-weight: 900; font-size: 34px; color: #2a1200; background: linear-gradient(160deg, #fff0a8, #ffc22e 60%, #ff9d2e); }
.rsCatList, .rsRecent{ list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.rsCatList li{ display: grid; grid-template-columns: minmax(110px, 1.1fr) minmax(60px, 1.2fr) auto; gap: 10px; align-items: center; font-size: 13.5px; font-weight: 800; }
.rsCatBar{ height: 9px; border-radius: 999px; background: rgba(255,255,255,.1); overflow: hidden; }
.rsCatBar i{ display: block; height: 100%; border-radius: 999px; background: linear-gradient(90deg, #ffd23f, #ff9d2e); }
.rsCatNum{ font-size: 12px; opacity: .8; text-align: right; white-space: nowrap; }
.rsCatNum small{ opacity: .7; }
@media (max-width: 560px){ .rsCatList li{ grid-template-columns: 1fr auto; } .rsCatBar{ grid-column: 1 / -1; order: 3; } }
.rsRecent li{ display: grid; grid-template-columns: 30px 1fr auto 34px; gap: 10px; align-items: center; padding: 6px 10px; border-radius: 12px; background: rgba(255,255,255,.05); font-size: 13.5px; font-weight: 800; }
.rsRecentLetter{ display: grid; place-items: center; width: 26px; height: 26px; border-radius: 8px; background: #ffc22e; color: #2a1200; font-weight: 900; }
.rsRecent b{ color: #8dffb8; font-size: 16px; }
.rsPlace{ text-align: right; opacity: .85; }
`;
