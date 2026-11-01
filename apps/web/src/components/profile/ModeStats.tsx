"use client";

import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useI18n } from "@/lib/i18n";

type ModeData = { matches: number; wins: number; practice: number; hits: number; answers: number; bestTotal: number; avgPlace: number | null };
type Stats = Partial<Record<"buzzer" | "year", ModeData>>;

/** Eigene Auswertung für Buzzer und Jahr raten (Migration 133): Spiele, Siege, Trefferquote, Bestwert, Ø-Platz – gewertet nur mit mindestens 2 Menschen. */
export function ModeStats({ userId }: { userId: string }) {
    const { tr } = useI18n();
    const [d, setD] = useState<Stats | null>(null);
    useEffect(() => {
        let cancel = false;
        void getSupabaseClient()
            .rpc("get_my_mode_stats")
            .then(({ data, error }) => {
                if (!cancel && !error && data) setD(data as Stats);
            });
        return () => {
            cancel = true;
        };
    }, [userId]);
    const modes: { key: "buzzer" | "year"; icon: string; title: string; hit: string }[] = [
        { key: "buzzer", icon: "🔔", title: tr("Buzzer"), hit: tr("Richtige Antworten") },
        { key: "year", icon: "📅", title: tr("Jahr raten"), hit: tr("Volltreffer") },
    ];
    const shown = modes.filter((m) => d?.[m.key]);
    if (!shown.length) return null;
    return (
        <section className="msStat" aria-label={tr("Modus-Statistik")}>
            {shown.map((m) => {
                const x = d![m.key]!;
                const acc = x.answers > 0 ? Math.round((x.hits / x.answers) * 100) : 0;
                return (
                    <div key={m.key} className="msCard">
                        <h2>
                            {m.icon} {m.title}
                        </h2>
                        <div className="msBoxes">
                            <div>
                                <small>{tr("Spiele")}</small>
                                <b>{x.matches}</b>
                            </div>
                            <div>
                                <small>{tr("Siege")}</small>
                                <b>{x.wins}</b>
                            </div>
                            <div>
                                <small>{m.hit}</small>
                                <b>{x.hits}</b>
                            </div>
                            <div>
                                <small>{tr("Trefferquote")}</small>
                                <b>{acc} %</b>
                            </div>
                            <div>
                                <small>{tr("Bestwert")}</small>
                                <b>{x.bestTotal}</b>
                            </div>
                            <div>
                                <small>{tr("Ø Platz")}</small>
                                <b>{x.avgPlace ?? "–"}</b>
                            </div>
                        </div>
                        {x.practice > 0 ? <p className="msNote">{tr("Dazu {n} Übungsspiele (zählen nicht für Spiele und Siege).", { n: x.practice })}</p> : null}
                    </div>
                );
            })}
            <style>{`
                .msStat{ margin-top: 18px; display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 12px; }
                .msCard{ padding: 16px; border-radius: 22px; background: rgba(255,255,255,.05); border: 1px solid rgba(255,255,255,.14); display: grid; gap: 10px; }
                .msCard h2{ margin: 0; font-size: 20px; }
                .msBoxes{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
                .msBoxes > div{ padding: 9px 6px; border-radius: 14px; background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.12); text-align: center; display: grid; gap: 3px; }
                .msBoxes small{ font-size: 10px; font-weight: 800; letter-spacing: .5px; text-transform: uppercase; opacity: .7; }
                .msBoxes b{ font-size: 20px; font-weight: 950; }
                .msNote{ margin: 0; font-size: 12.5px; font-weight: 700; opacity: .65; }
            `}</style>
        </section>
    );
}
