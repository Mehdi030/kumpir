"use client";

import Link from "next/link";
import Image from "next/image";
import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabaseClient";

type Privacy = "private" | "public";

function makeCode(len = 4) {
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

function getOrCreatePlayerId() {
    const key = "kumpir_player_id";
    const existing = typeof window !== "undefined" ? localStorage.getItem(key) : null;
    if (existing) return existing;

    const id = crypto.randomUUID();
    localStorage.setItem(key, id);
    return id;
}

function setStoredName(name: string) {
    localStorage.setItem("kumpir_player_name", name);
}

export default function HostPage() {
    const [hostName, setHostName] = useState("");
    const [privacy, setPrivacy] = useState<Privacy>("private");
    const [maxPlayers, setMaxPlayers] = useState(8);
    const [roundSeconds, setRoundSeconds] = useState(25);
    const [creating, setCreating] = useState(false);
    const [createError, setCreateError] = useState<string>("");

    // SSR-sicher: erst placeholder, dann client-only Code
    const [previewCode, setPreviewCode] = useState("----");
    useEffect(() => {
        setPreviewCode(makeCode(4));
    }, []);

    const minRound = 10;
    const maxRound = 60;
    const fillPct = Math.round(((roundSeconds - minRound) / (maxRound - minRound)) * 100);

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

    const isReady = isNameValid && !creating;
    const readyLabel = isReady ? "Bereit" : "Nicht bereit";
    const readyHint = isReady ? "Du kannst die Lobby jetzt erstellen." : "Bitte gib mindestens 2 Zeichen beim Namen ein.";

    async function onCreate() {
        if (!isNameValid || creating) return;

        setCreating(true);
        setCreateError("");

        try {
            const playerId = getOrCreatePlayerId();
            const cleanName = hostName.trim();
            setStoredName(cleanName);

            const payload = {
                p_player_id: playerId,
                p_name: cleanName,
                p_max_players: maxPlayers,
                p_round_seconds: roundSeconds,
                // nur drin lassen, wenn dein RPC das wirklich erwartet:
                // p_privacy: privacy,
            };

            const res = await supabase.rpc("rpc_create_lobby", payload);

            // HARTE Debug-Ausgabe (damit nie wieder {} im Overlay steht)
            console.log("[rpc_create_lobby] payload:", payload);
            console.log("[rpc_create_lobby] data:", res.data);
            console.log("[rpc_create_lobby] error:", res.error);

            if (res.error) {
                setCreateError(res.error.message || "RPC Fehler: Lobby konnte nicht erstellt werden.");
                return;
            }

            // Je nach RPC Return-Shape:
            // Variante A: res.data ist ein Objekt {id, code}
            // Variante B: res.data ist ein Array [{id, code}]
            const created =
                Array.isArray(res.data) ? res.data[0] : res.data;

            if (!created?.code) {
                setCreateError("RPC Return ungültig (kein code). Prüfe SQL Return von rpc_create_lobby.");
                return;
            }

            window.location.href = `/lobby/${created.code}`;
        } catch (e: any) {
            console.error("[onCreate] unexpected:", e);
            setCreateError(e?.message || "Unerwarteter Fehler. Bitte neu laden und erneut versuchen.");
        } finally {
            setCreating(false);
        }
    }

    async function copyInvite() {
        // wichtig: window gibt’s nur im Client, aber diese Funktion läuft nur per Buttonclick
        const url = `${window.location.origin}/join?code=${previewCode}`;
        try {
            await navigator.clipboard.writeText(url);
        } catch {
            // ignore
        }
    }

    return (
        <main className="container">
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image src="/logo.png" alt="Kumpir Maskottchen" width={160} height={160} priority className="brandLogoImg" />
            </Link>

            <div className="landingWrap">
                <section className="card" aria-label="Lobby hosten">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Lobby hosten</h1>

                            <span className="chip" title={readyHint} aria-live="polite" aria-label={`Status: ${readyLabel}. ${readyHint}`}>
                <span
                    className="chipDot"
                    aria-hidden
                    style={{
                        background: isReady ? "rgba(34,211,238,.92)" : "rgba(255,255,255,.35)",
                        boxShadow: isReady ? "0 0 0 3px rgba(34,211,238,.18)" : "0 0 0 3px rgba(255,255,255,.10)",
                    }}
                />
                                {readyLabel}
              </span>
                        </div>

                        <p className="p hostSub">Erstelle eine Lobby, teile den Code und starte später im Lobby-Screen.</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Spieler-Details</div>
                                <div className="panelHint">Du kannst das später ändern.</div>
                            </div>

                            <div className="fieldRow">
                                <label className="fieldLabel" htmlFor="hostName">
                                    Dein Name
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

                            {createError ? <div className="fieldHelp fieldHelpError">{createError}</div> : null}

                            <div className="actionsRow">
                                <button
                                    type="button"
                                    className={`btn btnPrimary ${(!isNameValid || creating) ? "btnDisabled" : ""}`}
                                    onClick={onCreate}
                                    disabled={!isNameValid || creating}
                                >
                                    {creating ? "Erstelle Lobby…" : "Lobby erstellen"}
                                </button>

                                <Link href="/" className="btn btnSecondary">
                                    Zurück
                                </Link>
                            </div>
                        </div>

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
                                        <div className="previewName">{hostName.trim() || "Dein Name"}</div>
                                        <div className="previewSub">🔒 Privat • 👥 2–{maxPlayers} • ⏱️ {roundSeconds}s</div>
                                    </div>
                                </div>

                                <div className="codeRow">
                                    <div className="codeLabel">Code</div>
                                    <div className="codePill">{previewCode}</div>
                                </div>

                                <div className="copyRow">
                                    <div className="copyHint">Einladung teilen:</div>
                                    <button type="button" className="btn btnSecondary btnSmall" onClick={copyInvite}>
                                        Link kopieren
                                    </button>
                                </div>
                            </div>

                            {/* QR kommt später */}
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
