"use client";

import { useState } from "react";
import { fmtSeconds, hitRate, seasonKey, seasonLabel, strongestPlaylist, titleRate, type ProfileStats } from "@/lib/profileStats";
import { renderRecapCard } from "@/lib/recapCard";
import { shareOrDownloadPng } from "@/lib/resultCard";
import { Spinner } from "@/components/Spinner";

type Props = {
    data: ProfileStats;
    username: string;
    /** Gewählter Monat für den Rückblick ("YYYY-MM"). */
    season: string;
    onSeasonChange: (season: string) => void;
    seasonLoading?: boolean;
};

function fmtDate(iso: string): string {
    const d = new Date(iso);
    return d.toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" }) + " · " + d.toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
}

/**
 * Konto-Statistik im Profil: gewertete Zähler (Matches/Runden getrennt), Musik-Werte pro Playlist,
 * Monats-Rückblick (teilbar), häufigste Gegner und die letzten 20 Matches.
 */
export function AccountStats({ data, username, season, onSeasonChange, seasonLoading = false }: Props) {
    const [shareBusy, setShareBusy] = useState(false);
    const [shareMsg, setShareMsg] = useState("");

    const { totals, music, playlists, recent, opponents, recap } = data;
    const empty = totals.matches === 0 && totals.practiceMatches === 0 && recent.length === 0;
    const rate = hitRate(music.titles, music.artists, music.wrong);
    const strongest = strongestPlaylist(playlists);
    const recapRate = hitRate(recap.titles, recap.artists, recap.wrong);
    const thisMonth = seasonKey(0);
    const lastMonth = seasonKey(-1);

    const shareRecap = async () => {
        if (shareBusy) return;
        setShareBusy(true);
        setShareMsg("");
        try {
            const lines = [
                recap.favoritePlaylist ? `Lieblings-Playlist: ${recap.favoritePlaylist}` : "",
                recap.bestPlaylist ? `Stärkste Playlist: ${recap.bestPlaylist}` : "",
            ].filter(Boolean);
            const blob = await renderRecapCard({
                username,
                monthLabel: seasonLabel(recap.season),
                tiles: [
                    { label: "Saison-Platz", value: recap.rank ? `#${recap.rank}` : "–" },
                    { label: "Saison-Punkte", value: String(recap.seasonPoints ?? 0) },
                    { label: "Matches", value: `${recap.matches}` },
                    { label: "Match-Siege", value: `${recap.matchWins}` },
                    { label: "Titel erkannt", value: String(recap.titles) },
                    { label: "Trefferquote", value: recapRate != null ? `${recapRate} %` : "–" },
                ],
                lines,
                siteUrl: window.location.origin,
            });
            const res = await shareOrDownloadPng(blob, `kumpir-${recap.season}.png`, `Mein Kumpir-Monat ${seasonLabel(recap.season)} – spiel mit: ${window.location.origin}`, "Kumpir-Rückblick");
            if (res === "saved") setShareMsg("✅ Bild gespeichert");
        } catch {
            setShareMsg("⚠️ Bild konnte nicht erstellt werden");
        } finally {
            setShareBusy(false);
            window.setTimeout(() => setShareMsg(""), 2500);
        }
    };

    if (empty) {
        return (
            <div className="accEmpty">
                🎧 Noch keine Spiele mit diesem Konto. Spiel eine Runde – danach siehst du hier deinen Verlauf, deine Musik-Werte und deine Gegner.
                <style>{STYLES}</style>
            </div>
        );
    }

    return (
        <div className="acc">
            {/* F: gewertete Zähler, Matches und Runden getrennt */}
            <div className="accGrid">
                <Tile label="Matches" value={totals.matches} />
                <Tile label="Match-Siege" value={totals.matchWins} />
                <Tile label="Runden" value={totals.rounds} />
                <Tile label="Rundensiege" value={totals.roundWins} />
            </div>
            {totals.practiceMatches > 0 ? (
                <div className="accNote">+ {totals.practiceMatches} Übungsspiel{totals.practiceMatches === 1 ? "" : "e"} (nur ein Mensch, nicht gewertet)</div>
            ) : null}

            {/* B: Musik */}
            <section className="accBox" aria-labelledby="accMusic">
                <h2 className="accH2" id="accMusic">
                    🎵 Musik <small>inkl. Übungsspiele</small>
                </h2>
                <div className="accGrid accGrid3">
                    <Tile label="Titel erkannt" value={music.titles} />
                    <Tile label="Nur Interpret" value={music.artists} />
                    <Tile label="Trefferquote" value={rate != null ? `${rate} %` : "–"} />
                    <Tile label="Ø Antwortzeit" value={fmtSeconds(music.avgAnswerMs)} />
                    <Tile label="Schnellster Titel" value={fmtSeconds(music.fastestTitleMs)} />
                    <Tile label="Beste Serie" value={music.bestCombo ? `${music.bestCombo} in Folge` : "–"} />
                </div>
                {strongest ? (
                    <div className="accStrong">
                        💪 Deine Stärke: <b>{strongest}</b>
                    </div>
                ) : null}
                {playlists.length > 0 ? (
                    <div className="accLists">
                        {playlists.map((p) => {
                            const tr = titleRate(p.titles, p.artists, p.wrong);
                            return (
                                <div key={p.playlist} className="accList">
                                    <div className="accListHead">
                                        <b>{p.playlist}</b>
                                        <span>{tr != null ? `${tr} % Titel` : "–"}</span>
                                    </div>
                                    <div className="accBar" role="img" aria-label={`${p.playlist}: ${tr ?? 0} Prozent Titel erkannt`}>
                                        <span style={{ width: `${tr ?? 0}%` }} />
                                    </div>
                                    <div className="accListSub">
                                        {p.titles} Titel · {p.artists} Interpret · {p.wrong} falsch · {p.rounds} Runde{p.rounds === 1 ? "" : "n"}
                                        {p.wins ? ` · ${p.wins}× gewonnen` : ""}
                                    </div>
                                </div>
                            );
                        })}
                    </div>
                ) : null}
            </section>

            {/* E: Monats-Rückblick */}
            <section className="accBox accRecap" aria-labelledby="accRecap">
                <div className="accRecapHead">
                    <h2 className="accH2" id="accRecap">
                        🗓️ Monats-Rückblick · {seasonLabel(recap.season)}
                    </h2>
                    <div className="accTabs" role="group" aria-label="Monat wählen">
                        <button type="button" className={season === thisMonth ? "on" : ""} aria-pressed={season === thisMonth} onClick={() => onSeasonChange(thisMonth)}>
                            Dieser Monat
                        </button>
                        <button type="button" className={season === lastMonth ? "on" : ""} aria-pressed={season === lastMonth} onClick={() => onSeasonChange(lastMonth)}>
                            Letzter Monat
                        </button>
                    </div>
                </div>
                {seasonLoading ? (
                    <Spinner size={18} label="Lade…" />
                ) : recap.rounds === 0 ? (
                    <div className="accNote">In diesem Monat noch keine Runde gespielt.</div>
                ) : (
                    <>
                        <div className="accGrid accGrid3">
                            <Tile label="Saison-Platz" value={recap.rank ? `#${recap.rank}` : "–"} />
                            <Tile label="Saison-Punkte" value={recap.seasonPoints ?? 0} />
                            <Tile label="Matches (Siege)" value={`${recap.matches} (${recap.matchWins})`} />
                            <Tile label="Titel erkannt" value={recap.titles} />
                            <Tile label="Trefferquote" value={recapRate != null ? `${recapRate} %` : "–"} />
                            <Tile label="Beste Runde" value={recap.bestRoundPoints != null ? `${recap.bestRoundPoints} P.` : "–"} />
                        </div>
                        <div className="accRecapLines">
                            {recap.favoritePlaylist ? (
                                <span>
                                    ❤️ Lieblings-Playlist: <b>{recap.favoritePlaylist}</b>
                                </span>
                            ) : null}
                            {recap.bestPlaylist ? (
                                <span>
                                    💪 Stärkste Playlist: <b>{recap.bestPlaylist}</b>
                                </span>
                            ) : null}
                            {recap.fastestTitleMs != null ? (
                                <span>
                                    ⚡ Schnellster Titel: <b>{fmtSeconds(recap.fastestTitleMs)}</b>
                                </span>
                            ) : null}
                        </div>
                        <div className="accShare">
                            <button type="button" className="btn btnSecondary btnSmall" onClick={() => void shareRecap()} disabled={shareBusy}>
                                {shareBusy ? <Spinner size={14} label="Erstelle Bild…" /> : "📤 Rückblick teilen"}
                            </button>
                            <span aria-live="polite">{shareMsg}</span>
                        </div>
                    </>
                )}
            </section>

            {/* C: Gegner */}
            <section className="accBox" aria-labelledby="accOpp">
                <h2 className="accH2" id="accOpp">
                    ⚔️ Deine häufigsten Gegner
                </h2>
                {opponents.length === 0 ? (
                    <div className="accNote">Noch keine Matches gegen andere Konten.</div>
                ) : (
                    <ul className="accOpp">
                        {opponents.map((o) => (
                            <li key={o.username}>
                                <b>{o.username}</b>
                                <span>
                                    {o.matches} Match{o.matches === 1 ? "" : "es"} · <span className="win">{o.wins} gewonnen</span> · <span className="loss">{o.losses} verloren</span>
                                </span>
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            {/* A: Verlauf */}
            <section className="accBox" aria-labelledby="accHist">
                <h2 className="accH2" id="accHist">
                    🕘 Letzte Matches
                </h2>
                <ul className="accHist">
                    {recent.map((m) => (
                        <li key={m.finished_at} className={m.place === 1 ? "first" : ""}>
                            <div className="accHistPlace" aria-label={`Platz ${m.place} von ${m.players_count}`}>
                                {m.place === 1 ? "🏆" : `${m.place}.`}
                                <small>/{m.players_count}</small>
                            </div>
                            <div className="accHistMain">
                                <div className="accHistTop">
                                    <b>{(m.playlists ?? []).filter(Boolean).join(" · ") || "Match"}</b>
                                    {!m.ranked ? <span className="accBadge">Übung</span> : null}
                                </div>
                                <div className="accHistSub">
                                    {fmtDate(m.finished_at)} · {m.rounds_total} Runde{m.rounds_total === 1 ? "" : "n"} · {m.humans_count} Mensch{m.humans_count === 1 ? "" : "en"}
                                    {m.bots_count ? ` + ${m.bots_count} Bot${m.bots_count === 1 ? "" : "s"}` : ""}
                                </div>
                            </div>
                            <div className="accHistRight">
                                <b>{m.total_points} P.</b>
                                <small>
                                    🎵 {m.title_hits}
                                    {m.artist_hits ? ` +${m.artist_hits}` : ""}
                                </small>
                            </div>
                        </li>
                    ))}
                </ul>
            </section>

            <style>{STYLES}</style>
        </div>
    );
}

function Tile({ label, value }: { label: string; value: string | number }) {
    return (
        <div className="accTile">
            <div className="accTileVal">{value}</div>
            <div className="accTileLabel">{label}</div>
        </div>
    );
}

const STYLES = `
.acc{ display:grid; gap:14px; margin-top:22px; }
.accEmpty{ margin-top:22px; padding:16px; border-radius:18px; background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.14); font-size:15px; line-height:1.45; }
.accGrid{ display:grid; grid-template-columns: repeat(4, minmax(0,1fr)); gap:10px; }
.accGrid3{ grid-template-columns: repeat(3, minmax(0,1fr)); }
.accTile{ padding:12px 8px; border-radius:16px; background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.14); text-align:center; min-width:0; }
.accTileVal{ font-size:22px; font-weight:800; font-family: var(--font-display); color:#ffe08a; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.accTileLabel{ font-size:11px; font-weight:700; letter-spacing:.6px; text-transform:uppercase; opacity:.75; margin-top:2px; }
.accNote{ font-size:13px; opacity:.8; }
.accBox{ padding:16px; border-radius:18px; background: rgba(0,0,0,.18); border:1px solid rgba(255,255,255,.12); display:grid; gap:12px; }
.accH2{ margin:0; font-size:17px; }
.accH2 small{ font-size:12px; font-weight:600; opacity:.7; margin-left:6px; }
.accStrong{ font-size:15px; }
.accLists{ display:grid; gap:10px; }
.accListHead{ display:flex; justify-content:space-between; gap:10px; font-size:14px; }
.accListHead span{ opacity:.85; font-weight:700; }
.accBar{ height:8px; border-radius:999px; background: rgba(255,255,255,.12); overflow:hidden; margin-top:4px; }
.accBar span{ display:block; height:100%; border-radius:999px; background: linear-gradient(90deg, #ffd23f, #ff9f1c); }
.accListSub{ font-size:12px; opacity:.75; margin-top:3px; }
.accRecap{ background: rgba(255,210,63,.12); border-color: rgba(255,210,63,.35); }
.accRecapHead{ display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap; }
.accTabs{ display:inline-flex; border-radius:999px; border:1px solid rgba(255,255,255,.28); overflow:hidden; }
.accTabs button{ border:0; background:transparent; color:#fff; font-weight:700; font-size:12px; padding:6px 10px; cursor:pointer; }
.accTabs button.on{ background: rgba(255,255,255,.9); color:#2b0f04; }
.accRecapLines{ display:flex; flex-wrap:wrap; gap:6px 16px; font-size:14px; }
.accShare{ display:flex; gap:10px; align-items:center; flex-wrap:wrap; font-size:13px; font-weight:700; }
.accOpp, .accHist{ list-style:none; margin:0; padding:0; display:grid; gap:8px; }
.accOpp li{ display:flex; justify-content:space-between; gap:10px; flex-wrap:wrap; padding:10px 12px; border-radius:14px; background: rgba(255,255,255,.07); font-size:14px; }
.accOpp .win{ color:#8df0a6; font-weight:700; }
.accOpp .loss{ color:#ffb4a8; font-weight:700; }
.accHist li{ display:grid; grid-template-columns: 52px 1fr auto; gap:10px; align-items:center; padding:10px 12px; border-radius:14px; background: rgba(255,255,255,.07); }
.accHist li.first{ background: rgba(255,214,10,.14); border:1px solid rgba(255,214,10,.35); }
.accHistPlace{ font-size:20px; font-weight:800; font-family: var(--font-display); text-align:center; }
.accHistPlace small{ font-size:12px; opacity:.7; font-weight:700; }
.accHistMain{ min-width:0; }
.accHistTop{ display:flex; gap:8px; align-items:center; min-width:0; }
.accHistTop b{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:14px; }
.accBadge{ flex:none; font-size:11px; font-weight:800; padding:2px 8px; border-radius:999px; background: rgba(255,255,255,.18); }
.accHistSub{ font-size:12px; opacity:.75; margin-top:2px; }
.accHistRight{ text-align:right; display:grid; font-size:14px; }
.accHistRight b{ color:#ffe08a; }
.accHistRight small{ opacity:.8; }
@media (max-width:560px){
  .accGrid{ grid-template-columns: repeat(2, minmax(0,1fr)); }
  .accGrid3{ grid-template-columns: repeat(2, minmax(0,1fr)); }
}
`;
