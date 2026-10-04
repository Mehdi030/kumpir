"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useAchievements } from "@/hooks/useAchievements";
import { useProfile } from "@/hooks/useProfile";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

type Season = { arena_points: number; sets_played: number; set_wins: number; rank: number } | null;

function seasonKey() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

function fmtHold(ms: number) {
    if (!ms) return "–";
    const sec = Math.floor(ms / 1000);
    if (sec < 60) return `${sec} s`;
    const m = Math.floor(sec / 60);
    if (m < 60) return `${m} min`;
    return `${Math.floor(m / 60)} h ${m % 60} min`;
}

export default function ProfilePage() {
    const { profile, user, loading } = useProfile();
    const { stats, unlocked, catalog } = useAchievements(user?.id ?? null);
    const supabase = getSupabaseClient();

    const [season, setSeason] = useState<Season>(null);
    const [pw, setPw] = useState("");
    const [pw2, setPw2] = useState("");
    const [pwMsg, setPwMsg] = useState<{ ok: boolean; text: string } | null>(null);
    const [pwBusy, setPwBusy] = useState(false);

    useEffect(() => {
        if (!user?.id) return;
        let cancel = false;
        void (async () => {
            const { data } = await supabase
                .from("season_leaderboard_view")
                .select("arena_points,sets_played,set_wins,rank")
                .eq("season", seasonKey())
                .eq("user_id", user.id)
                .maybeSingle();
            if (!cancel) setSeason((data as unknown as Season) ?? null);
        })();
        return () => {
            cancel = true;
        };
    }, [supabase, user?.id]);

    const changePassword = useCallback(async () => {
        setPwMsg(null);
        if (pw.length < 8) return setPwMsg({ ok: false, text: "Das Passwort braucht mindestens 8 Zeichen." });
        if (pw !== pw2) return setPwMsg({ ok: false, text: "Die beiden Passwörter sind nicht gleich." });
        setPwBusy(true);
        const { error } = await supabase.auth.updateUser({ password: pw });
        setPwBusy(false);
        if (error) return setPwMsg({ ok: false, text: error.message });
        setPw("");
        setPw2("");
        setPwMsg({ ok: true, text: "Passwort geändert." });
    }, [pw, pw2, supabase]);

    const logout = useCallback(async () => {
        await supabase.auth.signOut();
        window.location.assign("/");
    }, [supabase]);

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <section className="card">
                    <h1 className="h1">Konto</h1>
                    <p className="p hostSub">Accounts sind hier gerade deaktiviert – du spielst als Gast.</p>
                    <Link href="/" className="btn btnSecondary" style={{ marginTop: 14 }}>← Startseite</Link>
                </section>
            </main>
        );
    }

    if (loading) {
        return (
            <main className="container">
                <Spinner size={28} label="Lade…" />
            </main>
        );
    }

    if (!user || !profile) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" style={{ textAlign: "center" }}>
                        <div style={{ fontSize: 44 }}>👤</div>
                        <h1 className="h1" style={{ fontSize: 40 }}>Dein Konto</h1>
                        <p className="p hostSub" style={{ margin: "10px auto 0", maxWidth: 420 }}>
                            Mit einem Konto speichert Kumpir deine Siege, Saison-Punkte und Achievements und du findest deine Freunde wieder.
                        </p>
                        <div className="ctaRow" style={{ marginTop: 20 }}>
                            <Link href="/login?next=/profile" className="btn btnPrimary btnXL">Anmelden</Link>
                            <Link href="/register?next=/profile" className="btn btnSecondary btnXL">Konto erstellen</Link>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    const name = profile.username ?? profile.email?.split("@")[0] ?? "Spieler";

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card">
                    <div className="profHead">
                        <div className="profAvatar" aria-hidden>
                            {name.slice(0, 1).toUpperCase()}
                        </div>
                        <div className="profWho">
                            <h1 className="h1 profName">{name}</h1>
                            <div className="profMail">
                                {profile.email} {profile.emailVerified ? <span className="profOk">✓ bestätigt</span> : <span className="profWarn">nicht bestätigt</span>}
                            </div>
                        </div>
                        <Link href="/" className="btn btnSecondary btnSmall profBack">
                            ← Start
                        </Link>
                    </div>

                    <div className="profGrid">
                        <Stat label="Spiele" value={stats ? String(stats.games_played) : "0"} />
                        <Stat label="Siege" value={stats ? String(stats.wins) : "0"} />
                        <Stat label="Pässe" value={stats ? String(stats.total_passes) : "0"} />
                        <Stat label="Clutch-Pässe" value={stats ? String(stats.total_clutch_passes) : "0"} />
                        <Stat label="Schnellster Pass" value={stats?.fastest_pass_ms != null ? `${(stats.fastest_pass_ms / 1000).toFixed(2)} s` : "–"} />
                        <Stat label="Haltezeit gesamt" value={fmtHold(stats?.total_hold_ms ?? 0)} />
                    </div>

                    <div className="profSeason">
                        <div className="profSeasonTitle">🗓️ Saison-Punkte (dieser Monat)</div>
                        {season ? (
                            <div className="profSeasonRow">
                                <b>{season.arena_points}</b> Punkte · Platz <b>{season.rank}</b> · {season.set_wins}× Rundensieg
                            </div>
                        ) : (
                            <div className="profSeasonRow muted">Noch keine Runde in dieser Saison gespielt.</div>
                        )}
                    </div>

                    <div className="profLinks">
                        <Link href="/achievements" className="profLink">
                            <span>🏅</span>
                            <b>Achievements</b>
                            <small>{unlocked.length} von {catalog.length || "…"} freigeschaltet</small>
                        </Link>
                        <Link href="/friends" className="profLink">
                            <span>👥</span>
                            <b>Freunde</b>
                            <small>Freunde & gemerkte Lobbies</small>
                        </Link>
                        <Link href="/leaderboard" className="profLink">
                            <span>🏆</span>
                            <b>Bestenliste</b>
                            <small>Saison & Allzeit</small>
                        </Link>
                    </div>

                    <div className="profBox">
                        <h2 className="profH2">Passwort ändern</h2>
                        <div className="profPw">
                            <input className="input" type="password" placeholder="Neues Passwort (mind. 8 Zeichen)" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" />
                            <input
                                className="input"
                                type="password"
                                placeholder="Nochmal eingeben"
                                value={pw2}
                                onChange={(e) => setPw2(e.target.value)}
                                onKeyDown={(e) => {
                                    if (e.key === "Enter") void changePassword();
                                }}
                                autoComplete="new-password"
                            />
                            <button type="button" className="btn btnSecondary" onClick={() => void changePassword()} disabled={pwBusy || !pw}>
                                {pwBusy ? "…" : "Speichern"}
                            </button>
                        </div>
                        {pwMsg ? <div className={`fieldHelp ${pwMsg.ok ? "" : "fieldHelpError"}`} style={{ marginTop: 8 }}>{pwMsg.text}</div> : null}
                    </div>

                    <div style={{ marginTop: 18, display: "flex", justifyContent: "center" }}>
                        <button type="button" className="btn btnSecondary" onClick={() => void logout()}>
                            Abmelden
                        </button>
                    </div>

                    <style>{`
            .profHead{ display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
            .profAvatar{ width:68px; height:68px; border-radius:50%; display:grid; place-items:center; font-size:30px; font-weight:800; color:#2b0f04; background: radial-gradient(circle at 35% 30%, #ffe27a, #ffb21a 75%); box-shadow: 0 0 0 4px rgba(255,255,255,.2), 0 10px 24px rgba(0,0,0,.3); flex:none; font-family: var(--font-display); }
            .profWho{ flex:1; min-width:180px; }
            .profName{ font-size: clamp(28px,6vw,40px) !important; }
            .profMail{ font-size:13px; opacity:.8; margin-top:2px; word-break:break-all; }
            .profOk{ color:#8df0a6; font-weight:700; margin-left:6px; }
            .profWarn{ color:#ffd28a; font-weight:700; margin-left:6px; }
            .profBack{ align-self:flex-start; }
            .profGrid{ display:grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap:10px; margin-top:22px; }
            .profStat{ padding:14px; border-radius:18px; background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.14); text-align:center; }
            .profStatVal{ font-size:24px; font-weight:800; font-family: var(--font-display); color:#ffe08a; }
            .profStatLabel{ font-size:11px; font-weight:700; letter-spacing:.8px; text-transform:uppercase; opacity:.65; margin-top:2px; }
            .profSeason{ margin-top:14px; padding:14px 16px; border-radius:18px; background: rgba(255,210,63,.12); border:1px solid rgba(255,210,63,.35); }
            .profSeasonTitle{ font-weight:800; font-size:14px; }
            .profSeasonRow{ margin-top:4px; font-size:15px; }
            .profSeasonRow.muted{ opacity:.7; }
            .profLinks{ display:grid; grid-template-columns: repeat(auto-fit, minmax(190px,1fr)); gap:10px; margin-top:14px; }
            .profLink{ display:grid; grid-template-columns:34px 1fr; column-gap:10px; padding:12px 14px; border-radius:18px; background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.14); color:#fff; text-decoration:none; transition: background .15s ease, transform .15s ease; }
            .profLink:hover{ background: rgba(255,255,255,.15); transform: translateY(-1px); }
            .profLink span{ grid-row: span 2; font-size:24px; align-self:center; }
            .profLink small{ opacity:.7; font-size:12px; }
            .profBox{ margin-top:18px; padding:16px; border-radius:18px; background: rgba(0,0,0,.18); border:1px solid rgba(255,255,255,.12); }
            .profH2{ margin:0 0 10px; font-size:16px; }
            .profPw{ display:grid; grid-template-columns: 1fr 1fr auto; gap:8px; }
            @media (max-width:720px){ .profPw{ grid-template-columns: 1fr; } }
          `}</style>
                </section>
            </div>
        </main>
    );
}

function Stat({ label, value }: { label: string; value: string }) {
    return (
        <div className="profStat">
            <div className="profStatVal">{value}</div>
            <div className="profStatLabel">{label}</div>
        </div>
    );
}
