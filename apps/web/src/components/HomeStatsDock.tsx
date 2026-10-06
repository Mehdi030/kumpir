"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { fmtSeconds, hitRate, type ProfileStats } from "@/lib/profileStats";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

const dateFmt = (iso: string) => new Date(iso).toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" });

/**
 * Statistik-Dock am linken Bildschirmrand (auf dem Handy unter der Karte).
 * Zugeklappt: die wichtigsten Zahlen. Antippen: mehr Details + Link zum Profil.
 * Für Gäste unsichtbar (ohne Konto gibt es keine Statistik).
 */
export function HomeStatsDock() {
    const { user, loading } = useAuth();
    const [stats, setStats] = useState<ProfileStats | null>(null);
    const [failed, setFailed] = useState(false);
    const [open, setOpen] = useState(false);

    useEffect(() => {
        if (!user?.id || GUEST_ONLY) return;
        let alive = true;
        void getSupabaseClient()
            .rpc("get_my_profile_stats", { p_season: null })
            .then(({ data, error }) => {
                if (!alive) return;
                if (error || !data) setFailed(true);
                else setStats(data as ProfileStats);
            });
        return () => {
            alive = false;
        };
    }, [user?.id]);

    if (GUEST_ONLY || loading || !user) return null;

    const m = stats?.music;
    const t = stats?.totals;
    const matches = (t?.matches ?? 0) + (t?.practiceMatches ?? 0);
    const rate = m ? hitRate(m.titles, m.artists, m.wrong) : null;
    const favorite = stats?.playlists?.[0];

    return (
        <aside className={`sideDock sideDockLeft ${open ? "open" : ""}`} aria-label="Deine Statistik">
            <button type="button" className="sideDockHead" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
                <span>📊 Deine Statistik</span>
                <span className="sideDockToggle" aria-hidden>
                    {open ? "−" : "+"}
                </span>
            </button>

            {failed ? (
                <div className="sideDockNote">Statistik gerade nicht erreichbar.</div>
            ) : !stats ? (
                <div className="sideDockNote">Lade…</div>
            ) : matches === 0 && (m?.titles ?? 0) === 0 ? (
                <div className="sideDockNote">Noch keine Spiele – spiel eine Runde, dann siehst du hier deine Zahlen.</div>
            ) : (
                <>
                    <div className="sideDockTiles">
                        <Tile label="Matches" value={matches} />
                        <Tile label="Siege" value={t?.matchWins ?? 0} />
                        <Tile label="Titel erkannt" value={m?.titles ?? 0} />
                        <Tile label="Trefferquote" value={rate === null ? "–" : `${rate}%`} />
                    </div>

                    {open ? (
                        <div className="sideDockMore">
                            <Row label="Interpreten erkannt" value={m?.artists ?? 0} />
                            <Row label="Falsche Antworten" value={m?.wrong ?? 0} />
                            <Row label="Ø Antwortzeit" value={fmtSeconds(m?.avgAnswerMs)} />
                            <Row label="Schnellster Titel" value={fmtSeconds(m?.fastestTitleMs)} />
                            <Row label="Beste Combo" value={m?.bestCombo ?? 0} />
                            {favorite ? <Row label="Lieblings-Playlist" value={favorite.playlist} /> : null}

                            {stats.recent.length ? (
                                <>
                                    <div className="sideDockSub">Letzte Matches</div>
                                    <ul className="sideDockRecent">
                                        {stats.recent.slice(0, 3).map((r, i) => (
                                            <li key={i}>
                                                <span>{dateFmt(r.finished_at)}</span>
                                                <span>
                                                    Platz {r.place}/{r.players_count}
                                                </span>
                                                <span>{r.total_points} P.</span>
                                            </li>
                                        ))}
                                    </ul>
                                </>
                            ) : null}
                            <Link href="/profile" className="sideDockLink">
                                Alle Details im Profil →
                            </Link>
                        </div>
                    ) : (
                        <button type="button" className="sideDockHint" onClick={() => setOpen(true)}>
                            Tippen für mehr
                        </button>
                    )}
                </>
            )}
        </aside>
    );
}

function Tile({ label, value }: { label: string; value: number | string }) {
    return (
        <div className="sideDockTile">
            <div className="sideDockVal">{value}</div>
            <div className="sideDockLabel">{label}</div>
        </div>
    );
}

function Row({ label, value }: { label: string; value: number | string }) {
    return (
        <div className="sideDockRow">
            <span>{label}</span>
            <b>{value}</b>
        </div>
    );
}
