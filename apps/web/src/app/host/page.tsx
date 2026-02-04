"use client";

import Link from "next/link";
import Image from "next/image";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Privacy = "private" | "public";

type ModeKey = "classic" | "teleport" | "reverse"; // ✅ hier nur Keys erweitern

type RoundPreset = "rapid" | "classic" | "relaxed";

const ROUND_PRESETS: Record<RoundPreset, { label: string; seconds: number; hint: string }> = {
    rapid: { label: "⚡ Rapid", seconds: 15, hint: "Sehr schnell, hoher Druck." },
    classic: { label: "🎯 Classic", seconds: 25, hint: "Ausgewogenes Tempo für die meisten Runden." },
    relaxed: { label: "🧊 Relaxed", seconds: 40, hint: "Entspanntes Tempo mit mehr Entscheidungsfreiheit." },
};

// ✅ Modi zentral: leicht erweiterbar
const MODES: Record<
    ModeKey,
    {
        label: string;
        icon: string;
        desc: string;
        featured?: boolean; // ✅ Classic besser darstellen
        disabled?: boolean; // optional später
        comingSoon?: boolean; // optional später
    }
> = {
    classic: {
        label: "Classic",
        icon: "🥔",
        desc: "Standard-Regeln. Ideal für die meisten Runden.",
        featured: true,
    },
    teleport: {
        label: "Teleport",
        icon: "🌀",
        desc: "Die Kartoffel teleportiert sich in Intervallen zu einem zufälligen Spieler.",
        comingSoon: true,
        disabled: true,
    },
    reverse: {
        label: "Reverse",
        icon: "🔁",
        desc: "Die Richtung wechselt gelegentlich. Mehr Chaos, mehr Lacher.",
        comingSoon: true,
        disabled: true,
    },
};

function randomHostName() {
    const names = [
        "Baro","Achi","Medo","Sero","Sinan","Albion","Youssef","Angi","Elias",
        "Ben","Jonas","Max","Tim","Leo","Emir","Yusuf","Can","Ali","Omar",
        "David","Paul","Jan","Nico","Tobi","Sami","Ibrahim","Hassan","Amir",
        "Rafael","Matteo","Milan","Deniz",
    ];
    return names[Math.floor(Math.random() * names.length)];
}

function setStoredName(name: string) {
    if (typeof window === "undefined") return;
    localStorage.setItem("kumpir_player_name", name);
}
function setStoredPlayerId(id: string) {
    if (typeof window === "undefined") return;
    localStorage.setItem("kumpir_player_id", id);
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

    const [roundPreset, setRoundPreset] = useState<RoundPreset>("classic");
    const roundSeconds = ROUND_PRESETS[roundPreset].seconds;

    // ✅ Mode state
    const [mode, setMode] = useState<ModeKey>("classic");
    const activeMode = MODES[mode];

    const [creating, setCreating] = useState(false);
    const [createError, setCreateError] = useState<string>("");
    const [createdCode, setCreatedCode] = useState<string>("");

    const isNameValid = hostName.trim().length >= 2;

    const nameError = useMemo(() => {
        if (!hostName.length) return "";
        if (!isNameValid) return "Mindestens 2 Zeichen.";
        return "";
    }, [hostName, isNameValid]);

    const canCreate = isNameValid && !creating;

    async function onCreate() {
        setCreateError("");
        setCreatedCode("");
        if (!isNameValid || creating) return;

        setCreating(true);
        try {
            const cleanName = hostName.trim();
            setStoredName(cleanName);

            const { data, error } = await supabase.rpc("rpc_create_lobby", {
                p_host_name: cleanName,
                p_privacy: privacy,
                p_max_players: maxPlayers,
                p_round_seconds: roundSeconds,
                // ✅ optional: wenn du es DB-seitig speichern willst, musst du RPC + Schema erweitern
                // p_mode: mode,
            });

            if (error) {
                setCreateError(error.message || "Lobby konnte nicht erstellt werden.");
                return;
            }

            const created = Array.isArray(data) ? data[0] : data;
            const code = String(created?.code ?? "").toUpperCase();
            const hostPlayerId = String(created?.host_player_id ?? "");

            if (!code || code.length !== 4) {
                setCreateError("RPC Return ungültig (kein code).");
                return;
            }
            if (!hostPlayerId) {
                setCreateError("RPC Return ungültig (kein host_player_id).");
                return;
            }

            setStoredPlayerId(hostPlayerId);
            setCreatedCode(code);
        } catch (e: unknown) {
            setCreateError(getErrorMessage(e));
        } finally {
            setCreating(false);
        }
    }

    function goLobby() {
        if (!createdCode) return;
        router.push(`/lobby/${createdCode}`);
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
                        <div
                            className="hostTitleRow"
                            style={{ justifyContent: "space-between", gap: 12, alignItems: "center" }}
                        >
                            <h1 className="h1">Lobby hosten</h1>

                            {createdCode ? (
                                <div
                                    className="metaPill"
                                    title="Lobby-Code"
                                    style={{
                                        fontWeight: 900,
                                        letterSpacing: 2,
                                        paddingInline: 14,
                                        paddingBlock: 8,
                                        cursor: "pointer",
                                        userSelect: "none",
                                        background:
                                            "linear-gradient(90deg, #22D3EE, #A78BFA, #F08A1A, #22D3EE)",
                                        backgroundSize: "200% 200%",
                                        color: "rgba(16,12,8,0.92)",
                                        border: "1px solid rgba(255,255,255,0.22)",
                                    }}
                                    onClick={goLobby}
                                >
                                    {createdCode}
                                </div>
                            ) : null}
                        </div>

                        <p className="p hostSub">Erstelle eine Lobby, teile den Code und spiel mit deinen Freunden!</p>
                    </header>

                    <div className="hostGrid" style={{ gridTemplateColumns: "1fr" }}>
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Spieler-Details</div>
                                <div className="panelHint">Du kannst das später ändern.</div>
                            </div>

                            {/* ✅ Preview: Rundendauer + Modus sichtbar */}
                            <div className="previewCard" style={{ marginBottom: 12 }}>
                                <div
                                    style={{
                                        display: "flex",
                                        alignItems: "center",
                                        justifyContent: "space-between",
                                        gap: 12,
                                        marginBottom: 8,
                                    }}
                                >
                                    <div style={{ fontWeight: 900 }}>Aktuelle Einstellungen</div>

                                    {/* kleine Chips rechts */}
                                    <div style={{ display: "flex", gap: 8, flexWrap: "wrap", justifyContent: "flex-end" }}>
                                        <span className="metaPill" style={{ paddingInline: 12, paddingBlock: 6 }}>
                                            ⏱️ {roundSeconds}s
                                        </span>

                                        <span
                                            className="metaPill"
                                            style={{
                                                paddingInline: 12,
                                                paddingBlock: 6,
                                                border:
                                                    activeMode.featured
                                                        ? "1px solid rgba(255,255,255,0.32)"
                                                        : "1px solid rgba(255,255,255,0.18)",
                                                background: activeMode.featured
                                                    ? "linear-gradient(90deg, rgba(34,211,238,0.18), rgba(167,139,250,0.18))"
                                                    : undefined,
                                                fontWeight: activeMode.featured ? 900 : 800,
                                            }}
                                            title="Modus"
                                        >
                                            {activeMode.icon} {activeMode.label}
                                            {activeMode.featured ? " ✨" : ""}
                                        </span>
                                    </div>
                                </div>

                                <div className="fieldHelp" style={{ opacity: 0.9 }}>
                                    {activeMode.desc}
                                </div>
                            </div>

                            {createdCode ? (
                                <div className="previewCard" style={{ marginBottom: 12 }}>
                                    <div style={{ fontWeight: 900, marginBottom: 8 }}>Lobby erstellt</div>
                                    <div className="fieldHelp" style={{ opacity: 0.9 }}>
                                        Klick auf den Code oben oder geh direkt in den Warteraum.
                                    </div>

                                    <div className="actionsRow" style={{ marginTop: 12, alignItems: "center" }}>
                                        <button type="button" className="btn btnPrimary" onClick={goLobby}>
                                            Zur Lobby
                                        </button>
                                        <Link href={`/join?code=${createdCode}`} className="btn btnSecondary">
                                            Join testen
                                        </Link>
                                    </div>
                                </div>
                            ) : null}

                            <div className="fieldBlock">
                                <div className="fieldTop">
                                    <div className="fieldTitle">Dein Name</div>
                                    <div className="fieldHint">Mindestens 2 Zeichen</div>
                                </div>

                                <div className="pillInputWrap">
                                    <span className="pillIcon" aria-hidden>
                                        👤
                                    </span>
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
                                        <button
                                            type="button"
                                            className="pillStepBtn"
                                            onClick={() => setMaxPlayers((p) => Math.max(2, p - 1))}
                                        >
                                            −
                                        </button>
                                        <div className="pillStepValue">{maxPlayers}</div>
                                        <button
                                            type="button"
                                            className="pillStepBtn"
                                            onClick={() => setMaxPlayers((p) => Math.min(12, p + 1))}
                                        >
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
                                        <button
                                            type="button"
                                            className="pillSegBtn"
                                            disabled
                                            aria-disabled="true"
                                            title="Kommt später"
                                        >
                                            🌐 Public
                                        </button>
                                    </div>
                                </div>
                            </div>

                            {/* ✅ Modus */}
                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Modus</div>
                                    <div className="pillCardHint">Wähle die Regeln für die Runde</div>
                                </div>

                                <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                    {(Object.keys(MODES) as ModeKey[]).map((key) => {
                                        const m = MODES[key];
                                        const active = mode === key;

                                        const premiumStyle = m.featured
                                            ? {
                                                border: active
                                                    ? "1px solid rgba(255,255,255,0.38)"
                                                    : "1px solid rgba(255,255,255,0.22)",
                                                background: active
                                                    ? "linear-gradient(90deg, rgba(34,211,238,0.22), rgba(167,139,250,0.22))"
                                                    : "linear-gradient(90deg, rgba(34,211,238,0.10), rgba(167,139,250,0.10))",
                                                fontWeight: 900 as const,
                                            }
                                            : undefined;

                                        return (
                                            <button
                                                key={key}
                                                type="button"
                                                className={`pillSegBtn ${active ? "pillSegActive" : ""}`}
                                                onClick={() => setMode(key)}
                                                aria-pressed={active}
                                                disabled={!!m.disabled}
                                                title={m.comingSoon ? "Kommt bald" : undefined}
                                                style={premiumStyle}
                                            >
                                                {m.icon} {m.label}
                                                {m.featured ? (
                                                    <span style={{ marginLeft: 6, opacity: 0.95 }}>✨</span>
                                                ) : m.comingSoon ? (
                                                    <span style={{ marginLeft: 8, opacity: 0.8, fontWeight: 900 }}>
                                                        SOON
                                                    </span>
                                                ) : null}
                                            </button>
                                        );
                                    })}
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 10, opacity: 0.9 }}>
                                    <span style={{ fontWeight: 900 }}>{activeMode.icon} {activeMode.label}:</span>{" "}
                                    {activeMode.desc}
                                </div>
                            </div>

                            {/* ✅ Rundendauer */}
                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Rundendauer</div>
                                    <div className="pillCardHint">{ROUND_PRESETS[roundPreset].hint}</div>
                                </div>
                                <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                    {(Object.keys(ROUND_PRESETS) as RoundPreset[]).map((key) => (
                                        <button
                                            key={key}
                                            type="button"
                                            className={`pillSegBtn ${roundPreset === key ? "pillSegActive" : ""}`}
                                            onClick={() => setRoundPreset(key)}
                                            aria-pressed={roundPreset === key}
                                            style={
                                                key === "classic"
                                                    ? {
                                                        border:
                                                            roundPreset === "classic"
                                                                ? "1px solid rgba(255,255,255,0.38)"
                                                                : "1px solid rgba(255,255,255,0.22)",
                                                        background:
                                                            roundPreset === "classic"
                                                                ? "linear-gradient(90deg, rgba(240,138,26,0.22), rgba(34,211,238,0.18))"
                                                                : undefined,
                                                        fontWeight: 900,
                                                    }
                                                    : undefined
                                            }
                                        >
                                            {ROUND_PRESETS[key].label}{" "}
                                            <span style={{ marginLeft: 6, opacity: 0.9, fontWeight: 900 }}>
                                                {ROUND_PRESETS[key].seconds}s
                                            </span>
                                            {key === "classic" ? <span style={{ marginLeft: 6 }}>⭐</span> : null}
                                        </button>
                                    ))}
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
                                    {creating ? "⏳ Lobby wird erstellt…" : createdCode ? "✅ Neu erstellen" : "🚀 Lobby erstellen"}
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
