"use client";

import { useState } from "react";
import { fmtSeconds, seasonKey, seasonLabel, strongestPlaylist, titleRate, type ProfileStats } from "@/lib/profileStats";
import { renderRecapCard } from "@/lib/recapCard";
import { shareOrDownloadPng } from "@/lib/resultCard";
import { Spinner } from "@/components/Spinner";
import { dateLocale, useI18n } from "@/lib/i18n";

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
    return d.toLocaleDateString(dateLocale(), { day: "2-digit", month: "2-digit" }) + " · " + d.toLocaleTimeString(dateLocale(), { hour: "2-digit", minute: "2-digit" });
}

/**
 * Konto-Statistik im Profil: gewertete Zähler (Matches/Runden getrennt), Musik-Werte pro Playlist,
 * Monats-Rückblick (teilbar), häufigste Gegner und die letzten 20 Matches.
 */
export function AccountStats({ data, username, season, onSeasonChange, seasonLoading = false }: Props) {
    const { tr } = useI18n();
    const [shareBusy, setShareBusy] = useState(false);
    const [shareMsg, setShareMsg] = useState("");

    const { totals, music, playlists, recent, opponents, recap } = data;
    const empty = totals.matches === 0 && totals.practiceMatches === 0 && recent.length === 0;
    // Nur Künstler zählt kaum (viel leichter) – Quote = Titel-Treffer an allen Versuchen
    const rate = titleRate(music.titles, music.artists, music.wrong);
    const both = music.both ?? 0;
    const strongest = strongestPlaylist(playlists);
    const recapRate = titleRate(recap.titles, recap.artists, recap.wrong);
    const thisMonth = seasonKey(0);
    const lastMonth = seasonKey(-1);

    const shareRecap = async () => {
        if (shareBusy) return;
        setShareBusy(true);
        setShareMsg("");
        try {
            const lines = [
                recap.favoritePlaylist ? `${tr("Lieblings-Playlist:")} ${recap.favoritePlaylist}` : "",
                recap.bestPlaylist ? `${tr("Stärkste Playlist:")} ${recap.bestPlaylist}` : "",
            ].filter(Boolean);
            const blob = await renderRecapCard({
                username,
                monthLabel: seasonLabel(recap.season),
                tiles: [
                    { label: tr("Saison-Platz"), value: recap.rank ? `#${recap.rank}` : "–" },
                    { label: tr("Saison-Punkte"), value: String(recap.seasonPoints ?? 0) },
                    { label: tr("Matches"), value: `${recap.matches}` },
                    { label: tr("Match-Siege"), value: `${recap.matchWins}` },
                    { label: tr("Titel erkannt"), value: String(recap.titles) },
                    { label: tr("Titel-Quote"), value: recapRate != null ? `${recapRate} %` : "–" },
                ],
                lines,
                siteUrl: window.location.origin,
            });
            const res = await shareOrDownloadPng(blob, `kumpir-${recap.season}.png`, tr("Mein Kumpir-Monat {month} – spiel mit: {url}", { month: seasonLabel(recap.season), url: window.location.origin }), tr("Kumpir-Rückblick"));
            if (res === "saved") setShareMsg(tr("✅ Bild gespeichert"));
        } catch {
            setShareMsg(tr("⚠️ Bild konnte nicht erstellt werden"));
        } finally {
            setShareBusy(false);
            window.setTimeout(() => setShareMsg(""), 2500);
        }
    };

    if (empty) {
        return (
            <div className="accEmpty">
                {tr("🎧 Noch keine Spiele mit diesem Konto. Spiel eine Runde – danach siehst du hier deinen Verlauf, deine Musik-Werte und deine Gegner.")}
                <style>{STYLES}</style>
            </div>
        );
    }

    return (
        <div className="acc">
            {/* F: gewertete Zähler, Matches und Runden getrennt */}
            <div className="accGrid">
                <Tile label={tr("Matches")} value={totals.matches} />
                <Tile label={tr("Match-Siege")} value={totals.matchWins} />
                <Tile label={tr("Runden")} value={totals.rounds} />
                <Tile label={tr("Rundensiege")} value={totals.roundWins} />
            </div>
            {totals.practiceMatches > 0 ? (
                <div className="accNote">{totals.practiceMatches === 1 ? tr("+ 1 Übungsspiel (nur ein Mensch, nicht gewertet)") : tr("+ {n} Übungsspiele (nur ein Mensch, nicht gewertet)", { n: totals.practiceMatches })}</div>
            ) : null}

            {/* B: Musik */}
            <section className="accBox" aria-labelledby="accMusic">
                <h2 className="accH2" id="accMusic">
                    🎵 {tr("Musik")} <small>{tr("inkl. Übungsspiele")}</small>
                </h2>
                <div className="accGrid accGrid3">
                    <Tile label={tr("🎯 Titel + Künstler")} value={both} strong />
                    <Tile label={tr("🎵 Nur Titel")} value={music.titles - both} strong />
                    <Tile label={tr("Titel-Quote")} value={rate != null ? `${rate} %` : "–"} />
                    <Tile label={tr("Ø Antwortzeit")} value={fmtSeconds(music.avgAnswerMs)} />
                    <Tile label={tr("Schnellster Titel")} value={fmtSeconds(music.fastestTitleMs)} />
                    <Tile label={tr("Beste Serie")} value={music.bestCombo ? tr("{n} in Folge", { n: music.bestCombo }) : "–"} />
                </div>
                <div className="accNote">
                    {tr("Nur Künstler: {n}× (zählt kaum, weil es viel leichter ist).", { n: music.artists })} {tr("„Titel + Künstler“ wird seit Oktober 2026 getrennt gezählt.")}
                </div>
                {strongest ? (
                    <div className="accStrong">
                        💪 {tr("Deine Stärke:")} <b>{strongest}</b>
                    </div>
                ) : null}
                {playlists.length > 0 ? (
                    <div className="accLists">
                        {playlists.map((p) => {
                            const rateT = titleRate(p.titles, p.artists, p.wrong);
                            return (
                                <div key={p.playlist} className="accList">
                                    <div className="accListHead">
                                        <b>{p.playlist}</b>
                                        <span>{rateT != null ? tr("{n} % Titel", { n: rateT }) : "–"}</span>
                                    </div>
                                    <div className="accBar" role="img" aria-label={tr("{name}: {n} Prozent Titel erkannt", { name: p.playlist, n: rateT ?? 0 })}>
                                        <span style={{ width: `${rateT ?? 0}%` }} />
                                    </div>
                                    <div className="accListSub">
                                        {tr("{b} Titel + Künstler · {t} nur Titel · {w} falsch · {r} Runden", { b: p.both ?? 0, t: p.titles - (p.both ?? 0), w: p.wrong, r: p.rounds })}
                                        {p.wins ? ` · ${tr("{n}× gewonnen", { n: p.wins })}` : ""}
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
                        🗓️ {tr("Monats-Rückblick")} · {seasonLabel(recap.season)}
                    </h2>
                    <div className="accTabs" role="group" aria-label={tr("Monat wählen")}>
                        <button type="button" className={season === thisMonth ? "on" : ""} aria-pressed={season === thisMonth} onClick={() => onSeasonChange(thisMonth)}>
                            {tr("Dieser Monat")}
                        </button>
                        <button type="button" className={season === lastMonth ? "on" : ""} aria-pressed={season === lastMonth} onClick={() => onSeasonChange(lastMonth)}>
                            {tr("Letzter Monat")}
                        </button>
                    </div>
                </div>
                {seasonLoading ? (
                    <Spinner size={18} label={tr("Lade…")} />
                ) : recap.rounds === 0 ? (
                    <div className="accNote">{tr("In diesem Monat noch keine Runde gespielt.")}</div>
                ) : (
                    <>
                        <div className="accGrid accGrid3">
                            <Tile label={tr("Saison-Platz")} value={recap.rank ? `#${recap.rank}` : "–"} />
                            <Tile label={tr("Saison-Punkte")} value={recap.seasonPoints ?? 0} />
                            <Tile label={tr("Matches (Siege)")} value={`${recap.matches} (${recap.matchWins})`} />
                            <Tile label={tr("🎯 Titel + Künstler")} value={recap.both ?? 0} strong />
                            <Tile label={tr("🎵 Nur Titel")} value={recap.titles - (recap.both ?? 0)} strong />
                            <Tile label={tr("Titel-Quote")} value={recapRate != null ? `${recapRate} %` : "–"} />
                        </div>
                        <div className="accRecapLines">
                            {recap.favoritePlaylist ? (
                                <span>
                                    ❤️ {tr("Lieblings-Playlist:")} <b>{recap.favoritePlaylist}</b>
                                </span>
                            ) : null}
                            {recap.bestPlaylist ? (
                                <span>
                                    💪 {tr("Stärkste Playlist:")} <b>{recap.bestPlaylist}</b>
                                </span>
                            ) : null}
                            {recap.bestRoundPoints != null ? (
                                <span>
                                    🏅 {tr("Beste Runde:")} <b>{tr("{n} P.", { n: recap.bestRoundPoints })}</b>
                                </span>
                            ) : null}
                            {recap.fastestTitleMs != null ? (
                                <span>
                                    ⚡ {tr("Schnellster Titel:")} <b>{fmtSeconds(recap.fastestTitleMs)}</b>
                                </span>
                            ) : null}
                        </div>
                        <div className="accShare">
                            <button type="button" className="btn btnSecondary btnSmall" onClick={() => void shareRecap()} disabled={shareBusy}>
                                {shareBusy ? <Spinner size={14} label={tr("Erstelle Bild…")} /> : tr("📤 Rückblick teilen")}
                            </button>
                            <span aria-live="polite">{shareMsg}</span>
                        </div>
                    </>
                )}
            </section>

            {/* C: Gegner */}
            <section className="accBox" aria-labelledby="accOpp">
                <h2 className="accH2" id="accOpp">
                    ⚔️ {tr("Deine häufigsten Gegner")}
                </h2>
                {opponents.length === 0 ? (
                    <div className="accNote">{tr("Noch keine Matches gegen andere Konten.")}</div>
                ) : (
                    <ul className="accOpp">
                        {opponents.map((o) => (
                            <li key={o.username}>
                                <b>{o.username}</b>
                                <span>
                                    {tr("{n} Matches", { n: o.matches })} · <span className="win">{tr("{n} gewonnen", { n: o.wins })}</span> · <span className="loss">{tr("{n} verloren", { n: o.losses })}</span>
                                </span>
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            {/* A: Verlauf */}
            <section className="accBox" aria-labelledby="accHist">
                <h2 className="accH2" id="accHist">
                    🕘 {tr("Letzte Matches")}
                </h2>
                <ul className="accHist">
                    {recent.map((m) => (
                        <li key={m.finished_at} className={m.place === 1 ? "first" : ""}>
                            <div className="accHistPlace" aria-label={tr("Platz {p} von {n}", { p: m.place, n: m.players_count })}>
                                {m.place === 1 ? "🏆" : `${m.place}.`}
                                <small>/{m.players_count}</small>
                            </div>
                            <div className="accHistMain">
                                <div className="accHistTop">
                                    <b>{(m.playlists ?? []).filter(Boolean).join(" · ") || tr("Match")}</b>
                                    {!m.ranked ? <span className="accBadge">{tr("Übung")}</span> : null}
                                </div>
                                <div className="accHistSub">
                                    {fmtDate(m.finished_at)} · {tr("{n} Runden", { n: m.rounds_total })} · {tr("{n} Menschen", { n: m.humans_count })}
                                    {m.bots_count ? ` + ${tr("{n} Bots", { n: m.bots_count })}` : ""}
                                </div>
                            </div>
                            <div className="accHistRight">
                                <b>{tr("{n} P.", { n: m.total_points })}</b>
                                <small>
                                    {m.both_hits ? `🎯 ${m.both_hits} · ` : ""}🎵 {m.title_hits - (m.both_hits ?? 0)}
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

function Tile({ label, value, strong = false }: { label: string; value: string | number; strong?: boolean }) {
    return (
        <div className={`accTile ${strong ? "strong" : ""}`}>
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
.accTile.strong{ background: rgba(255,210,63,.14); border-color: rgba(255,210,63,.45); }
.accTile.strong .accTileVal{ font-size:26px; }
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
