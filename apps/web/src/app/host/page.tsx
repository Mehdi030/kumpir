"use client";

import Link from "next/link";
import { Suspense } from "react";
import { useMemo, useState, useRef, useCallback } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { HostNotice } from "./HostNotice";

type Privacy = "private" | "public";
type ModeKey = "original" | "teleport" | "reverse";
type RoundSpeed = "fast" | "normal" | "calm";

const ROUND_SPEEDS: Record<
    RoundSpeed,
    { label: string; seconds: number; hint: string; variant: "fast" | "normal" | "calm" }
> = {
    fast: { label: "⚡ Blitz", seconds: 15, hint: "Schnell, hoher Druck.", variant: "fast" },
    normal: { label: "🎯 Standard", seconds: 25, hint: "Ausgewogenes Tempo.", variant: "normal" },
    calm: { label: "🧊 Casual", seconds: 40, hint: "Entspannt, mehr Zeit.", variant: "calm" },
};

const MODES: Record<
    ModeKey,
    {
        label: string;
        icon: string;
        desc: string;
        featured?: boolean;
        disabled?: boolean;
        comingSoon?: boolean;
        variant: "original" | "teleport" | "reverse";
    }
> = {
    original: {
        label: "Original",
        icon: "🥔",
        desc: "Standard-Regeln. Beste Basis für alle.",
        featured: true,
        variant: "original",
    },
    teleport: {
        label: "Teleport",
        icon: "🌀",
        desc: "Die Kartoffel teleportiert sich in Intervallen zu einem zufälligen Spieler.",
        comingSoon: true,
        disabled: true,
        variant: "teleport",
    },
    reverse: {
        label: "Reverse",
        icon: "🔁",
        desc: "Die Richtung wechselt gelegentlich. Mehr Chaos, mehr Lacher.",
        comingSoon: true,
        disabled: true,
        variant: "reverse",
    },
};

function randomHostName() {
    const names = [
        "Baro","Achi","Medo","Sero","Sinan","Albion","Youssef","Angi","Elias","Ben","Jonas","Max","Tim","Leo","Emir","Yusuf","Can","Ali",
        "Omar","David","Paul","Jan","Nico","Tobi","Sami","Ibrahim","Hassan","Amir","Rafael","Matteo","Milan","Deniz",
    ];
    return names[Math.floor(Math.random() * names.length)];
}

/** localStorage as source of truth */
function setStoredName(name: string) {
    if (typeof window === "undefined") return;
    localStorage.setItem("kumpir_player_name", name);
    try { sessionStorage.setItem("kumpir_player_name", name); } catch {}
}

function setStoredPlayerId(id: string) {
    if (typeof window === "undefined") return;
    localStorage.setItem("kumpir_player_id", id);
    try { sessionStorage.setItem("kumpir_player_id", id); } catch {}
}

function getErrorMessage(err: unknown): string {
    if (err instanceof Error) return err.message;
    if (typeof err === "object" && err !== null && "message" in err) {
        const m = (err as { message?: unknown }).message;
        if (typeof m === "string") return m;
    }
    return "Unbekannter Fehler.";
}

export default function HostPage() {
    const supabase = getSupabaseClient();
    const router = useRouter();

    const [hostName, setHostName] = useState("");
    const [privacy, setPrivacy] = useState<Privacy>("private");
    const [maxPlayers, setMaxPlayers] = useState(8);

    const [roundSpeed, setRoundSpeed] = useState<RoundSpeed | null>(null);
    const [mode, setMode] = useState<ModeKey | null>(null);

    const activeMode = mode ? MODES[mode] : null;
    const activeSpeed = roundSpeed ? ROUND_SPEEDS[roundSpeed] : null;

    const [creating, setCreating] = useState(false);
    const [createError, setCreateError] = useState("");

    const inFlightRef = useRef(false);

    const isNameValid = hostName.trim().length >= 2;
    const nameError = useMemo(() => {
        if (!hostName.length) return "";
        if (!isNameValid) return "Mindestens 2 Zeichen.";
        return "";
    }, [hostName, isNameValid]);

    const canCreate = isNameValid && !!roundSpeed && !!mode && !creating;

    const onCreate = useCallback(async () => {
        setCreateError("");
        if (!canCreate) return;
        if (inFlightRef.current) return;

        inFlightRef.current = true;
        setCreating(true);

        try {
            const cleanName = hostName.trim();
            setStoredName(cleanName);

            const roundSeconds = ROUND_SPEEDS[roundSpeed!].seconds;

            const { data, error } = await supabase.rpc("rpc_create_lobby", {
                p_host_name: cleanName,
                p_privacy: privacy,
                p_max_players: maxPlayers,
                p_round_seconds: roundSeconds,
            });

            if (error) {
                setCreateError(error.message || "Lobby konnte nicht erstellt werden.");
                return;
            }

            const row = Array.isArray(data) ? data[0] : data;
            const code = String(row?.code ?? "").toUpperCase();
            const hostPlayerId = String(row?.host_player_id ?? "");

            if (!code || code.length !== 4) {
                setCreateError("RPC Return ungültig (kein code).");
                return;
            }
            if (!hostPlayerId) {
                setCreateError("RPC Return ungültig (kein host_player_id).");
                return;
            }

            setStoredPlayerId(hostPlayerId);

            const ensure = await supabase.rpc("rpc_join_lobby", {
                p_code: code,
                p_player_id: hostPlayerId,
                p_name: cleanName,
            });

            if (ensure.error) {
                setCreateError(ensure.error.message || "Host konnte nicht als Spieler eingetragen werden.");
                return;
            }

            router.push(`/lobby/${code}`);
        } catch (e: unknown) {
            setCreateError(getErrorMessage(e));
        } finally {
            setCreating(false);
            inFlightRef.current = false;
        }
    }, [canCreate, hostName, roundSpeed, supabase, privacy, maxPlayers, router]);

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby hosten">
                    {/* ✅ Suspense boundary required for useSearchParams (inside HostNotice) */}
                    <Suspense fallback={null}>
                        <HostNotice />
                    </Suspense>

                    <header className="hostHeader">
                        <div className="hostTitleRow" style={{ justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                            <h1 className="h1">Lobby hosten</h1>
                        </div>
                        <p className="p hostSub">Erstelle eine Lobby, teile den Code und spiel mit deinen Freunden!</p>
                    </header>

                    <div className="hostGrid" style={{ gridTemplateColumns: "1fr" }}>
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Spieler-Details</div>
                                <div className="panelHint">Du kannst das später ändern.</div>
                            </div>

                            <div className="fieldBlock">
                                <div className="fieldTop">
                                    <div className="fieldTitle">Dein Name</div>
                                    <div className="fieldHint">Mindestens 2 Zeichen</div>
                                </div>

                                <div className="pillInputWrap">
                                    <span className="pillIcon" aria-hidden>👤</span>
                                    <input
                                        className="pillInput"
                                        value={hostName}
                                        onChange={(e) => setHostName(e.target.value)}
                                        placeholder="z.B. Steve"
                                        autoComplete="nickname"
                                        maxLength={24}
                                        aria-label="Host Name"
                                    />
                                    <div className="pillRight" aria-hidden>
                                        <button
                                            type="button"
                                            className="pillIconBtn"
                                            onClick={() => setHostName(randomHostName())}
                                            title="Zufälliger Name"
                                        >
                                            🎲
                                        </button>
                                        <span className="pillChip">{Math.min(hostName.trim().length, 24)}/24</span>
                                    </div>
                                </div>

                                {nameError ? <div className="fieldHelp fieldHelpError">{nameError}</div> : null}
                            </div>

                            <div className="divider" />

                            <div className="pillGrid2">
                                <div className="pillCard">
                                    <div className="pillCardTop">
                                        <div className="pillCardTitle">Max. Spieler</div>
                                        <div className="pillCardHint">Empfohlen: 6–10</div>
                                    </div>
                                    <div className="pillStepper">
                                        <button type="button" className="pillStepBtn" onClick={() => setMaxPlayers((p) => Math.max(2, p - 1))}>
                                            −
                                        </button>
                                        <div className="pillStepValue">{maxPlayers}</div>
                                        <button type="button" className="pillStepBtn" onClick={() => setMaxPlayers((p) => Math.min(12, p + 1))}>
                                            +
                                        </button>
                                    </div>
                                </div>

                                <div className="pillCard">
                                    <div className="pillCardTop">
                                        <div className="pillCardTitle">Privatsphäre</div>
                                        <div className="pillCardHint">Public später</div>
                                    </div>
                                    <div className="pillSeg">
                                        <button
                                            type="button"
                                            className={`pillSegBtn ${privacy === "private" ? "pillSegActive" : ""}`}
                                            onClick={() => setPrivacy("private")}
                                        >
                                            🔒 Privat
                                        </button>
                                        <button type="button" className="pillSegBtn" disabled aria-disabled="true" title="Kommt später">
                                            🌐 Public
                                        </button>
                                    </div>
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Modus</div>
                                    <div className="pillCardHint">Wähle die Regeln für die Runde</div>
                                </div>

                                <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                    {(Object.keys(MODES) as ModeKey[]).map((key) => {
                                        const m = MODES[key];
                                        const active = mode === key;

                                        return (
                                            <button
                                                key={key}
                                                type="button"
                                                className={`pillSegBtn segChoice ${active ? "segChoiceActive" : ""} ${m.featured ? "segChoiceFeatured" : ""}`}
                                                data-variant={m.variant}
                                                onClick={() => setMode(key)}
                                                aria-pressed={active}
                                                disabled={!!m.disabled}
                                                title={m.comingSoon ? "Kommt bald" : undefined}
                                            >
                                                <span className="segIcon" aria-hidden>{m.icon}</span>
                                                <span className="segLabel">{m.label}</span>
                                                {m.featured ? <span className="segBadge">✨</span> : null}
                                                {m.comingSoon ? <span className="segSoon">SOON</span> : null}
                                            </button>
                                        );
                                    })}
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 10, opacity: 0.9 }}>
                                    {activeMode ? (
                                        <>
                      <span style={{ fontWeight: 900 }}>
                        {activeMode.icon} {activeMode.label}:
                      </span>{" "}
                                            {activeMode.desc}
                                        </>
                                    ) : (
                                        <span style={{ fontWeight: 900 }}>Bitte Modus auswählen.</span>
                                    )}
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Rundendauer</div>
                                    <div className="pillCardHint">{activeSpeed ? activeSpeed.hint : "Bitte auswählen."}</div>
                                </div>

                                <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                    {(Object.keys(ROUND_SPEEDS) as RoundSpeed[]).map((key) => {
                                        const s = ROUND_SPEEDS[key];
                                        const active = roundSpeed === key;

                                        return (
                                            <button
                                                key={key}
                                                type="button"
                                                className={`pillSegBtn segChoice ${active ? "segChoiceActive" : ""}`}
                                                data-variant={s.variant}
                                                onClick={() => setRoundSpeed(key)}
                                                aria-pressed={active}
                                            >
                                                <span className="segLabel">{s.label}</span>
                                            </button>
                                        );
                                    })}
                                </div>
                            </div>

                            {createError ? (
                                <div className="fieldHelp fieldHelpError" style={{ marginTop: 12 }}>
                                    {createError}
                                </div>
                            ) : null}

                            <div className="actionsRow" style={{ alignItems: "center", marginTop: 14 }}>
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