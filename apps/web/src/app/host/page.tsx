"use client";

import Link from "next/link";
import Image from "next/image";
import { useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useAuth } from "@/components/AuthProvider";
import { AuthMini } from "@/components/AuthMini";

type Privacy = "private" | "public";
type RoundPreset = "rapid" | "classic" | "relaxed";

const ROUND_PRESETS: Record<RoundPreset, { label: string; seconds: number; hint: string }> = {
    rapid: { label: "⚡ Rapid", seconds: 15, hint: "Sehr schnell, hoher Druck." },
    classic: { label: "🎯 Classic", seconds: 25, hint: "Ausgewogenes Tempo für die meisten Runden." },
    relaxed: { label: "🧊 Relaxed", seconds: 40, hint: "Entspanntes Tempo mit mehr Entscheidungsfreiheit." },
};

function randomHostName() {
    const names = [
        "Baro", "Achi", "Medo", "Sero",
        "Sinan", "Albion", "Youssef", "Angi", "Elias",
        "Ben", "Jonas", "Max", "Tim", "Leo",
        "Emir", "Yusuf", "Can", "Ali", "Omar",
        "David", "Paul", "Jan", "Nico", "Tobi",
        "Sami", "Ibrahim", "Hassan", "Amir",
        "Rafael", "Matteo", "Milan", "Deniz",
    ];
    return names[Math.floor(Math.random() * names.length)];
}

function setStoredName(name: string) {
    localStorage.setItem("kumpir_player_name", name);
}
function setStoredPlayerId(id: string) {
    localStorage.setItem("kumpir_player_id", id);
}

export default function HostPage() {
    const supabase = getSupabaseClient();
    const { user, loading } = useAuth();

    // Vercel/Supabase: NEXT_PUBLIC_AUTH_DISABLED=1 => Login/Gates aus
    const authDisabled = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

    const [hostName, setHostName] = useState("");
    const [privacy, setPrivacy] = useState<Privacy>("private");
    const [maxPlayers, setMaxPlayers] = useState(8);

    const [roundPreset, setRoundPreset] = useState<RoundPreset>("classic");
    const roundSeconds = ROUND_PRESETS[roundPreset].seconds;

    const [creating, setCreating] = useState(false);
    const [createError, setCreateError] = useState<string>("");

    // 🔐 Hard Gate nur wenn Auth an ist
    useEffect(() => {
        if (authDisabled) return;
        if (!loading && !user) {
            window.location.href = `/login?next=${encodeURIComponent("/host")}`;
        }
    }, [authDisabled, loading, user]);

    const isNameValid = hostName.trim().length >= 2;

    const nameError = useMemo(() => {
        if (hostName.length === 0) return "";
        if (!isNameValid) return "Mindestens 2 Zeichen.";
        return "";
    }, [hostName, isNameValid]);

    const canCreate = isNameValid && !creating && (authDisabled ? true : (!!user && !loading));

    async function onCreate() {
        if (!isNameValid || creating) return;
        if (!authDisabled && loading) return;

        if (!authDisabled && !user) {
            setCreateError("Bitte einloggen, um eine Lobby zu erstellen.");
            return;
        }

        setCreating(true);
        setCreateError("");

        try {
            const cleanName = hostName.trim();
            setStoredName(cleanName);

            // ✅ rpc_create_lobby erstellt bereits:
            // - lobbies row
            // - host player row (player_id == lobbies.host_player_id)
            const { data: lobbyData, error: lobbyErr } = await supabase.rpc("rpc_create_lobby", {
                p_host_name: cleanName,
                p_privacy: privacy,
                p_max_players: maxPlayers,
                p_round_seconds: roundSeconds,
            });

            if (lobbyErr) {
                setCreateError(lobbyErr.message || "Lobby konnte nicht erstellt werden.");
                return;
            }

            const created = Array.isArray(lobbyData) ? lobbyData[0] : lobbyData;
            const code = String(created?.code ?? "").toUpperCase();

            if (!code || code.length !== 4) {
                setCreateError("RPC Return ungültig (kein code).");
                return;
            }

            // ✅ host_player_id aus lobbies holen (kein join_lobby mehr!)
            const { data: lobbyRow, error: selErr } = await supabase
                .from("lobbies")
                .select("host_player_id")
                .eq("code", code)
                .single();

            if (selErr || !lobbyRow?.host_player_id) {
                setCreateError("Konnte host_player_id nicht laden (lobbies.select).");
                return;
            }

            setStoredPlayerId(String(lobbyRow.host_player_id));
            window.location.href = `/lobby/${code}`;
        } catch (e: any) {
            setCreateError(e?.message || "Unerwarteter Fehler.");
        } finally {
            setCreating(false);
        }
    }

    // Info-Screen wenn Auth aktiv und nicht eingeloggt
    if (!authDisabled && !loading && !user) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" aria-label="Weiterleitung">
                        <h1 className="h1">Login erforderlich</h1>
                        <p className="p subline">Damit du eine Lobby hosten kannst.</p>

                        <div className="panel" style={{ marginTop: 14 }}>
                            <div className="panelHead">
                                <div className="panelTitle">Warum Login?</div>
                                <div className="panelHint">Kurz erklärt</div>
                            </div>

                            <ul style={{ margin: 0, paddingLeft: 18, lineHeight: 1.35 }}>
                                <li><b>Kontrolle:</b> Du verwaltest deine Lobby – Start, Ablauf und Einstellungen liegen bei dir.</li>
                                <li><b>Statistiken:</b> Später kannst du Spiele auswerten, Fortschritt sehen und Highlights tracken.</li>
                                <li><b>Komfort:</b> Einstellungen bleiben gespeichert und neue Features stehen dir automatisch zur Verfügung.</li>
                            </ul>
                        </div>

                        <div className="actionsRow" style={{ marginTop: 14 }}>
                            <Link className="btn btnPrimary" href={`/login?next=${encodeURIComponent("/host")}`}>
                                Zum Login
                            </Link>
                            <Link href="/" className="btn btnSecondary">
                                ← Zurück
                            </Link>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    return (
        <main className="container">
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image
                    src="/logo.png"
                    alt="Kumpir Maskottchen"
                    width={400}
                    height={400}
                    priority
                    className="brandLogoImg"
                />
            </Link>

            <div className="landingWrap">
                <section className="card" aria-label="Lobby hosten">
                    <header className="hostHeader">
                        <div className="hostTitleRow" style={{ justifyContent: "space-between", gap: 12 }}>
                            <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                                <h1 className="h1">Lobby hosten</h1>
                            </div>

                            {!authDisabled ? <AuthMini nextPath="/host" variant="header" /> : null}
                        </div>

                        <p className="p hostSub">Erstelle eine Lobby, teile den Code und spiel mit deinen Freunden!</p>
                    </header>

                    <div className="hostGrid" style={{ gridTemplateColumns: "1fr" }}>
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Spieler-Details</div>
                                <div className="panelHint">Du kannst das später ändern.</div>
                            </div>

                            <div className="fieldRow">
                                <label className="fieldLabel" htmlFor="hostName">Dein Name</label>

                                <div className="fieldControl">
                                    <input
                                        id="hostName"
                                        className={`input ${nameError ? "inputError" : ""}`}
                                        value={hostName}
                                        onChange={(e) => setHostName(e.target.value)}
                                        placeholder="z.B. Steve"
                                        autoComplete="nickname"
                                        maxLength={24}
                                    />
                                    <button
                                        type="button"
                                        className="iconBtn"
                                        onClick={() => setHostName(randomHostName())}
                                        aria-label="Zufälligen Namen wählen"
                                        title="Zufälliger Name"
                                    >
                                        🎲
                                    </button>
                                </div>

                                <div className={`fieldHelp ${nameError ? "fieldHelpError" : ""}`}>
                                    {nameError || "So sehen dich andere Spieler."}
                                </div>
                            </div>

                            <div className="divider" />

                            <div className="settingsRow">
                                <div className="settingBlock">
                                    <div className="settingLabel">Privatsphäre</div>

                                    <div className="seg">
                                        <button
                                            type="button"
                                            className={`segBtn ${privacy === "private" ? "segActive" : ""}`}
                                            onClick={() => setPrivacy("private")}
                                        >
                                            🔒 Privat
                                        </button>

                                        <button type="button" className="segBtn" disabled aria-disabled="true" title="Kommt später">
                                            🌐 Public (später)
                                        </button>
                                    </div>

                                    <div className="settingHelp">Privat = nur mit Code. Public folgt später.</div>
                                </div>

                                <div className="settingBlock">
                                    <div className="settingLabel">Max. Spieler</div>

                                    <div className="stepper">
                                        <button
                                            type="button"
                                            className="stepBtn"
                                            onClick={() => setMaxPlayers((p) => Math.max(2, p - 1))}
                                            aria-label="Weniger Spieler"
                                        >
                                            −
                                        </button>
                                        <div className="stepValue">{maxPlayers}</div>
                                        <button
                                            type="button"
                                            className="stepBtn"
                                            onClick={() => setMaxPlayers((p) => Math.min(12, p + 1))}
                                            aria-label="Mehr Spieler"
                                        >
                                            +
                                        </button>
                                    </div>

                                    <div className="settingHelp">Empfohlen: 6–10 Spieler.</div>
                                </div>
                            </div>

                            <div className="settingBlock" style={{ marginTop: 18 }}>
                                <div className="settingLabel">Rundendauer</div>

                                <div className="seg" style={{ marginTop: 8, display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center" }}>
                                    {(Object.keys(ROUND_PRESETS) as RoundPreset[]).map((key) => (
                                        <button
                                            key={key}
                                            type="button"
                                            className={`segBtn ${roundPreset === key ? "segActive" : ""}`}
                                            onClick={() => setRoundPreset(key)}
                                            aria-pressed={roundPreset === key}
                                            style={{ minWidth: 110 }}
                                        >
                                            {ROUND_PRESETS[key].label}
                                        </button>
                                    ))}
                                </div>

                                <div className="settingHelp">{ROUND_PRESETS[roundPreset].hint}</div>
                            </div>

                            {createError ? <div className="fieldHelp fieldHelpError">{createError}</div> : null}

                            <div className="actionsRow" style={{ alignItems: "center" }}>
                                <button
                                    type="button"
                                    onClick={onCreate}
                                    disabled={!canCreate}
                                    className={`btn btnPrimary btnXL ${canCreate ? "btnGlow" : "btnDisabled"}`}
                                >
                                    {creating ? "⏳ Lobby wird erstellt…" : "🚀 Lobby erstellen"}
                                </button>

                                <Link href="/" className="btn btnSecondary btnSmall">
                                    ← Zurück
                                </Link>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}