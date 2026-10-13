"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";
import { fmtNum, tk, useI18n } from "@/lib/i18n";

export type SongRow = {
    playlist: string;
    title: string;
    artist: string;
    plays: number;
    hits: number;
    rate: number | null;
    artists: number;
    wrong: number;
    avg_ms: number | null;
};

type GroupRow = { who: string; titles: number; artists: number; wrong: number; exploded: number; avg_answer_ms: number | null; avg_hold_before_boom_ms: number | null };
type AliveRow = { bucket: string; answers: number; avg_answer_ms: number | null; exploded: number; avg_hold_before_boom_ms: number | null };
export type Balance = {
    days: number;
    groups: GroupRow[];
    byAlive: AliveRow[];
    wrongBeforeHit: { wrong_tries: number; turns: number }[];
    playlists: { playlist: string; titles: number; artists: number; wrong: number }[];
};
export type FunnelRow = { event: string; total: number; devices: number };

export type AdminAnalyticsData = { songs: SongRow[]; balance: Balance; funnel: FunnelRow[] };

const FUNNEL_LABEL: Record<string, string> = {
    home_view: tk("Startseite besucht"),
    solo_start: tk("Solo gestartet"),
    solo_game_started: tk("Solo-Spiel läuft"),
    host_created: tk("Lobby erstellt (Host)"),
    join_success: tk("Lobby beigetreten"),
    spectate: tk("Zuschauen geklickt"),
    game_finished: tk("Spiel zu Ende gesehen"),
    invite_share: tk("Einladung geteilt"),
    invite_copy: tk("Link kopiert"),
    invite_qr: tk("QR-Code geöffnet"),
    result_share: tk("Ergebnis geteilt"),
    install_click: tk("App installieren geklickt"),
    lang_en: tk("Auf Englisch gestellt"),
    lang_fr: tk("Auf Französisch gestellt"),
    register_success: tk("Konto erstellt"),
};
// Reihenfolge des "Wegs": Besuch -> Spielen -> Weitererzählen -> Bleiben
const FUNNEL_ORDER = Object.keys(FUNNEL_LABEL);

const UNKNOWN_RATE = 50; // unter 50 % Titel-Erkennung gilt ein Song als "kaum bekannt"
const MIN_PLAYS = 5;

function sec(ms: number | null | undefined) {
    return ms == null ? "–" : `${fmtNum(ms / 1000)} s`;
}

/** Lädt Song-, Balance- und Nutzungs-Auswertung (nur Platform-Admins, Prüfung in der DB). */
export function AdminAnalytics() {
    const { tr } = useI18n();
    const supabase = getSupabaseClient();
    const [days, setDays] = useState(30);
    const [data, setData] = useState<AdminAnalyticsData | null>(null);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");
        const [songs, balance, funnel] = await Promise.all([
            supabase.rpc("admin_song_stats", { p_days: 90 }),
            supabase.rpc("admin_balance_stats", { p_days: days }),
            supabase.rpc("admin_funnel", { p_days: days }),
        ]);
        const err = songs.error ?? balance.error ?? funnel.error;
        if (err) {
            setError(err.message);
            return;
        }
        setData({ songs: songs.data as SongRow[], balance: balance.data as Balance, funnel: funnel.data as FunnelRow[] });
    }, [supabase, days]);

    useEffect(() => {
        let cancel = false;
        void (async () => {
            if (!cancel) await load();
        })();
        return () => {
            cancel = true;
        };
    }, [load]);

    if (error) return <div className="aaErr">❌ Auswertung: {error}</div>;
    if (!data) return <Spinner size={18} label={tr("Lade Auswertung…")} />;
    return <AdminAnalyticsView data={data} days={days} onDays={setDays} />;
}

export function AdminAnalyticsView({ data, days, onDays }: { data: AdminAnalyticsData; days: number; onDays: (d: number) => void }) {
    const { tr } = useI18n();
    const [playlist, setPlaylist] = useState("alle");
    const [onlyUnknown, setOnlyUnknown] = useState(false);

    const playlists = useMemo(() => ["alle", ...Array.from(new Set(data.songs.map((s) => s.playlist))).sort()], [data.songs]);
    const songs = useMemo(
        () =>
            data.songs.filter(
                (s) => (playlist === "alle" || s.playlist === playlist) && (!onlyUnknown || (s.plays >= MIN_PLAYS && (s.rate ?? 0) < UNKNOWN_RATE))
            ),
        [data.songs, playlist, onlyUnknown]
    );
    const unknownCount = data.songs.filter((s) => s.plays >= MIN_PLAYS && (s.rate ?? 0) < UNKNOWN_RATE).length;
    const funnel = [...data.funnel].sort((a, b) => FUNNEL_ORDER.indexOf(a.event) - FUNNEL_ORDER.indexOf(b.event));
    const homeDevices = data.funnel.find((f) => f.event === "home_view")?.devices ?? 0;
    const totalTurns = data.balance.wrongBeforeHit.reduce((n, w) => n + w.turns, 0);

    return (
        <div className="aa">
            <div className="aaHead">
                <span>{tr("Zeitraum Balance & Nutzung:")}</span>
                {[7, 30, 90].map((d) => (
                    <button key={d} type="button" className={d === days ? "on" : ""} aria-pressed={d === days} onClick={() => onDays(d)}>
                        {tr("{n} Tage", { n: d })}
                    </button>
                ))}
            </div>

            {/* G: Songs */}
            <section className="aaBox" aria-labelledby="aaSongs">
                <h2 id="aaSongs">{tr("🎵 Song-Bekanntheit (nur Menschen)")}</h2>
                <p className="aaHint">
                    {tr("„Erkannt“ = voller Titel bei Menschen als Halter (seit Beginn). Ziel: ≥ 85 %. Rot markiert: unter {rate} % bei mind. {plays} Einsätzen – Kandidaten zum Austauschen ({n}). Interpret/falsch/Zeit aus den letzten 90 Tagen.", { rate: UNKNOWN_RATE, plays: MIN_PLAYS, n: unknownCount })}
                </p>
                <div className="aaFilters">
                    <label>
                        {tr("Playlist")}{" "}
                        <select value={playlist} onChange={(e) => setPlaylist(e.target.value)}>
                            {playlists.map((p) => (
                                <option key={p} value={p}>
                                    {p}
                                </option>
                            ))}
                        </select>
                    </label>
                    <label>
                        <input type="checkbox" checked={onlyUnknown} onChange={(e) => setOnlyUnknown(e.target.checked)} /> {tr("nur kaum bekannte")}
                    </label>
                </div>
                {songs.length === 0 ? (
                    <div className="aaHint">{tr("Noch keine Daten – Songs erscheinen, sobald Menschen sie gespielt haben.")}</div>
                ) : (
                    <div className="aaScroll">
                        <table className="aaTable">
                            <thead>
                                <tr>
                                    <th>{tr("Song")}</th>
                                    <th>{tr("Playlist")}</th>
                                    <th className="r">{tr("Einsätze")}</th>
                                    <th className="r">{tr("Erkannt")}</th>
                                    <th className="r">{tr("Interpret")}</th>
                                    <th className="r">{tr("Falsch")}</th>
                                    <th className="r">{tr("Ø Zeit")}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {songs.map((s) => {
                                    const weak = s.plays >= MIN_PLAYS && (s.rate ?? 0) < UNKNOWN_RATE;
                                    return (
                                        <tr key={`${s.playlist}|${s.title}|${s.artist}`} className={weak ? "weak" : ""}>
                                            <td>
                                                <b>{s.title}</b>
                                                <small>{s.artist}</small>
                                            </td>
                                            <td>{s.playlist}</td>
                                            <td className="r">{s.plays}</td>
                                            <td className="r">{s.rate != null ? `${s.rate} %` : "–"}</td>
                                            <td className="r">{s.artists}</td>
                                            <td className="r">{s.wrong}</td>
                                            <td className="r">{sec(s.avg_ms)}</td>
                                        </tr>
                                    );
                                })}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>

            {/* H: Balance */}
            <section className="aaBox" aria-labelledby="aaBal">
                <h2 id="aaBal">⚖️ {tr("Balance aus echten Spielen ({n} Tage)", { n: data.balance.days })}</h2>
                {data.balance.groups.length === 0 ? (
                    <div className="aaHint">{tr("Noch keine protokollierten Spielzüge im Zeitraum.")}</div>
                ) : (
                    <>
                        <div className="aaScroll">
                            <table className="aaTable">
                                <thead>
                                    <tr>
                                        <th>{tr("Wer")}</th>
                                        <th className="r">{tr("Titel")}</th>
                                        <th className="r">{tr("Interpret")}</th>
                                        <th className="r">{tr("Falsch")}</th>
                                        <th className="r">{tr("Explodiert")}</th>
                                        <th className="r">{tr("Ø Antwort")}</th>
                                        <th className="r">{tr("Ø gehalten bis Knall")}</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {data.balance.groups.map((g) => (
                                        <tr key={g.who}>
                                            <td>
                                                <b>{tr(g.who)}</b>
                                            </td>
                                            <td className="r">{g.titles}</td>
                                            <td className="r">{g.artists}</td>
                                            <td className="r">{g.wrong}</td>
                                            <td className="r">{g.exploded}</td>
                                            <td className="r">{sec(g.avg_answer_ms)}</td>
                                            <td className="r">{sec(g.avg_hold_before_boom_ms)}</td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>

                        <h3>{tr("Nach Spielstand (nur Menschen)")}</h3>
                        <p className="aaHint">{tr("Zeigt, ob das Duell zu hart ist: Antworten Menschen bei 2 Übrigen deutlich langsamer oder explodieren öfter?")}</p>
                        <div className="aaScroll">
                            <table className="aaTable">
                                <thead>
                                    <tr>
                                        <th>{tr("Übrig")}</th>
                                        <th className="r">{tr("Antworten")}</th>
                                        <th className="r">{tr("Ø Antwort")}</th>
                                        <th className="r">{tr("Explodiert")}</th>
                                        <th className="r">{tr("Ø gehalten bis Knall")}</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {data.balance.byAlive.map((a) => (
                                        <tr key={a.bucket}>
                                            <td>{a.bucket.replace(/^\d · |^\d /, "")}</td>
                                            <td className="r">{a.answers}</td>
                                            <td className="r">{sec(a.avg_answer_ms)}</td>
                                            <td className="r">{a.exploded}</td>
                                            <td className="r">{sec(a.avg_hold_before_boom_ms)}</td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>

                        <h3>{tr("Fehlversuche vor einem Treffer (Durchprobieren)")}</h3>
                        <p className="aaHint">{tr("Viele Züge mit 3+ Fehlversuchen sprechen für eine stärkere Strafe bei falschen Antworten.")}</p>
                        <div className="aaBars">
                            {data.balance.wrongBeforeHit.map((w) => (
                                <div key={w.wrong_tries} className="aaBarRow">
                                    <span>{w.wrong_tries >= 5 ? "5+" : w.wrong_tries}</span>
                                    <div className="aaBar">
                                        <i style={{ width: `${totalTurns ? Math.round((w.turns / totalTurns) * 100) : 0}%` }} />
                                    </div>
                                    <span className="r">
                                        {w.turns} ({totalTurns ? Math.round((w.turns / totalTurns) * 100) : 0} %)
                                    </span>
                                </div>
                            ))}
                        </div>
                    </>
                )}
            </section>

            {/* I: Weg der Spieler */}
            <section className="aaBox" aria-labelledby="aaFun">
                <h2 id="aaFun">🧭 {tr("Weg der Spieler ({n} Tage, anonym)", { n: days })}</h2>
                <p className="aaHint">{tr("„Geräte“ = verschiedene Browser (zufällige ID, kein Name). Anteil bezogen auf Startseiten-Besucher.")}</p>
                {funnel.length === 0 ? (
                    <div className="aaHint">{tr("Noch keine Ereignisse im Zeitraum.")}</div>
                ) : (
                    <div className="aaScroll">
                        <table className="aaTable">
                            <thead>
                                <tr>
                                    <th>{tr("Schritt")}</th>
                                    <th className="r">{tr("Geräte")}</th>
                                    <th className="r">{tr("Anteil")}</th>
                                    <th className="r">{tr("Ereignisse")}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {funnel.map((f) => (
                                    <tr key={f.event}>
                                        <td>{tr(FUNNEL_LABEL[f.event] ?? f.event)}</td>
                                        <td className="r">{f.devices}</td>
                                        <td className="r">{homeDevices ? `${Math.round((f.devices / homeDevices) * 100)} %` : "–"}</td>
                                        <td className="r">{f.total}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>

            <style>{`
        .aa{ display:grid; gap:14px; grid-column: 1 / -1; }
        .aaHead{ display:flex; gap:8px; align-items:center; flex-wrap:wrap; font-size:13px; font-weight:700; }
        .aaHead button{ border:1px solid rgba(255,255,255,.28); background:transparent; color:#fff; border-radius:999px; padding:5px 10px; font-weight:700; cursor:pointer; }
        .aaHead button.on{ background: rgba(255,255,255,.9); color:#2b0f04; }
        .aaBox{ padding:16px; border-radius:18px; background: rgba(0,0,0,.2); border:1px solid rgba(255,255,255,.14); display:grid; gap:10px; min-width:0; }
        .aaBox h2{ margin:0; font-size:17px; }
        .aaBox h3{ margin:8px 0 0; font-size:14px; }
        .aaHint{ margin:0; font-size:12px; opacity:.8; line-height:1.45; }
        .aaErr{ padding:12px; border-radius:14px; background: rgba(255,80,80,.18); font-weight:700; }
        .aaFilters{ display:flex; gap:14px; flex-wrap:wrap; font-size:13px; align-items:center; }
        .aaFilters select{ background: rgba(0,0,0,.3); color:#fff; border:1px solid rgba(255,255,255,.25); border-radius:10px; padding:4px 8px; }
        .aaScroll{ overflow-x:auto; max-height: 460px; overflow-y:auto; }
        .aaTable{ width:100%; border-collapse:collapse; font-size:13px; }
        .aaTable th{ text-align:left; font-size:11px; letter-spacing:.5px; text-transform:uppercase; opacity:.7; padding:6px 8px; position:sticky; top:0; background: rgba(40,10,6,.95); }
        .aaTable td{ padding:7px 8px; border-top:1px solid rgba(255,255,255,.08); vertical-align:top; }
        .aaTable td small{ display:block; opacity:.7; }
        .aaTable .r{ text-align:right; white-space:nowrap; }
        .aaTable tr.weak td{ background: rgba(248,113,113,.16); }
        .aaBars{ display:grid; gap:6px; }
        .aaBarRow{ display:grid; grid-template-columns: 32px 1fr 90px; gap:8px; align-items:center; font-size:13px; }
        .aaBarRow .r{ text-align:right; }
        .aaBar{ height:10px; border-radius:999px; background: rgba(255,255,255,.12); overflow:hidden; }
        .aaBar i{ display:block; height:100%; background: linear-gradient(90deg, #ffd23f, #ff9f1c); border-radius:999px; }
      `}</style>
        </div>
    );
}
