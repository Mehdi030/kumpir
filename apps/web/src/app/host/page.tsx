"use client";

import Link from "next/link";
import Image from "next/image";
import { useMemo, useState } from "react";

type Privacy = "private" | "public";

function makeCode(len = 6) {
    const chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    let out = "";
    for (let i = 0; i < len; i++) out += chars[Math.floor(Math.random() * chars.length)];
    return out;
}

function randomHostName() {
    const a = ["Schnelle", "Crispy", "Wilde", "Freche", "Legendäre", "Heisse", "Golden", "Turbo", "Chillige", "Mutige"];
    const b = ["Kartoffel", "Kumpir", "Lobby", "Crew", "Runde", "Gang", "Truppe", "Squad", "Clique", "Party"];
    return `${a[Math.floor(Math.random() * a.length)]} ${b[Math.floor(Math.random() * b.length)]}`;
}

export default function HostPage() {
    const [hostName, setHostName] = useState("");
    const [privacy, setPrivacy] = useState<Privacy>("private");
    const [maxPlayers, setMaxPlayers] = useState(8);
    const [roundSeconds, setRoundSeconds] = useState(25);
    const [creating, setCreating] = useState(false);

    const lobbyCode = useMemo(() => makeCode(6), []);

    const minRound = 10;
    const maxRound = 60;
    const fillPct = Math.round(((roundSeconds - minRound) / (maxRound - minRound)) * 100);

    // Orange Fill + dunkler Track
    const sliderBg = `linear-gradient(90deg,
        rgba(243,209,161,.95) 0%,
        rgba(231,185,126,.95) ${fillPct}%,
        rgba(0,0,0,.28) ${fillPct}%,
        rgba(0,0,0,.28) 100%)`;

    const isNameValid = hostName.trim().length >= 2;

    const nameError = useMemo(() => {
        if (hostName.length === 0) return "";
        if (!isNameValid) return "Mindestens 2 Zeichen.";
        return "";
    }, [hostName, isNameValid]);

    async function onCreate() {
        if (!isNameValid || creating) return;
        setCreating(true);

        try {
            // TODO: echtes Create-Lobby (Supabase/API)
            await new Promise((r) => setTimeout(r, 450));
            window.location.href = `/lobby/${lobbyCode}`;
        } finally {
            setCreating(false);
        }
    }

    async function copyInvite() {
        const url = `${window.location.origin}/join?code=${lobbyCode}`;
        try {
            await navigator.clipboard.writeText(url);
        } catch {
            // optional: toast/snackbar
        }
    }

    return (
        <main className="container">
            {/* Brand Logo */}
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image
                    src="/logo.png"
                    alt="Kumpir Maskottchen"
                    width={160}
                    height={160}
                    priority
                    className="brandLogoImg"
                />
            </Link>

            <div className="landingWrap">
                <section className="card" aria-label="Lobby hosten">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Lobby hosten</h1>
                            <span className="chip">
                                <span className="chipDot" aria-hidden />
                                Ready
                            </span>
                        </div>
                        <p className="p hostSub">
                            Erstelle eine Lobby, teile den Code und starte später im Lobby-Screen.
                        </p>
                    </header>

                    <div className="hostGrid">
                        {/* LEFT: FORM */}
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Host-Details</div>
                                <div className="panelHint">Du kannst das später ändern.</div>
                            </div>

                            <div className="fieldRow">
                                <label className="fieldLabel" htmlFor="hostName">
                                    Host-Name
                                </label>

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
                                    {nameError || "Wird in der Lobby angezeigt."}
                                </div>
                            </div>

                            <div className="divider" />

                            {/* PRIVACY + MAX PLAYERS NEBENEINANDER */}
                            <div className="settingsRow">
                                {/* PRIVACY (Public disabled / future) */}
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

                                        <button
                                            type="button"
                                            className="segBtn"
                                            disabled
                                            aria-disabled="true"
                                            title="Kommt später"
                                        >
                                            🌐 Public (später)
                                        </button>
                                    </div>

                                    <div className="settingHelp">
                                        Privat = nur mit Code. Public folgt später.
                                    </div>
                                </div>

                                {/* MAX PLAYERS */}
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

                            {/* ROUND DURATION */}
                            <div className="settingBlock">
                                <div className="settingLabel">Rundendauer</div>

                                <div className="sliderRow">
                                    <input
                                        className="slider"
                                        type="range"
                                        min={minRound}
                                        max={maxRound}
                                        step={5}
                                        value={roundSeconds}
                                        onChange={(e) => setRoundSeconds(Number(e.target.value))}
                                        style={{ background: sliderBg }}
                                        aria-label="Rundendauer"
                                    />
                                    <div className="sliderValue">{roundSeconds}s</div>
                                </div>

                                <div className="settingHelp">Je kürzer, desto stressiger.</div>
                            </div>

                            <div className="actionsRow">
                                <button
                                    type="button"
                                    className={`btn btnPrimary ${(!isNameValid || creating) ? "btnDisabled" : ""}`}
                                    onClick={onCreate}
                                    disabled={!isNameValid || creating}
                                >
                                    {creating ? "Erstelle Lobby…" : "Lobby erstellen"}
                                </button>

                                {/* statt "Lieber beitreten": Zurück (später global auf allen Seiten) */}
                                <Link href="/" className="btn btnSecondary">
                                    Zurück
                                </Link>
                            </div>

                            <p className="trustLine">
                                Kein Account nötig. Später kannst du Auth hinzufügen – die UI bleibt kompatibel.
                            </p>
                        </div>

                        {/* RIGHT: PREVIEW (kompakt) */}
                        <div className="panel panelAlt">
                            <div className="panelHead">
                                <div className="panelTitle">Lobby-Preview</div>
                                <div className="panelHint">Kurz & wichtig</div>
                            </div>

                            <div className="previewCard">
                                <div className="previewTop">
                                    <div className="avatar" aria-hidden>
                                        {hostName.trim().slice(0, 1).toUpperCase() || "H"}
                                    </div>
                                    <div className="previewMeta">
                                        <div className="previewName">{hostName.trim() || "Host-Name"}</div>
                                        <div className="previewSub">
                                            🔒 Privat • 👥 2–{maxPlayers} • ⏱️ {roundSeconds}s
                                        </div>
                                    </div>
                                </div>

                                <div className="codeRow">
                                    <div className="codeLabel">Code</div>
                                    <div className="codePill">{lobbyCode}</div>
                                </div>

                                <div className="copyRow">
                                    <div className="copyHint">Einladung teilen:</div>
                                    <button type="button" className="btn btnSecondary btnSmall" onClick={copyInvite}>
                                        Link kopieren
                                    </button>
                                </div>
                            </div>

                            {/* QR absichtlich entfernt (kommt später) */}
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
