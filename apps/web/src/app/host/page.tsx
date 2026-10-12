"use client";

import { useEffect, useMemo, useState, useRef, useCallback } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { errorText } from "@/lib/errorText";
import { validatePlayerName } from "@/lib/profanity";
import { useAuth } from "@/components/AuthProvider";
import { useProfile } from "@/hooks/useProfile";
import { PlaylistPicker, loadPlaylists, selectedFromExcluded } from "@/components/PlaylistPicker";
import { RulesCard } from "@/components/RulesCard";
import { track } from "@/lib/track";
import { startBotGame, type BotSkill } from "@/lib/botGame";
import { SOLO_SKILL_LABEL } from "@/lib/accountSettings";
import { HomeButton } from "@/components/BackButton";
import { AccountNameNote } from "@/components/AccountNameNote";
import { tk, trNow, useI18n } from "@/lib/i18n";

type ModeKey = "original" | "teleport" | "reverse";
type RoundSpeed = "fast" | "normal" | "calm";
const ROUND_SPEEDS: Record<
    RoundSpeed,
    { label: string; seconds: number; hint: string; variant: "fast" | "normal" | "calm" }
> = {
    fast: { label: tk("⚡ Blitz"), seconds: 15, hint: tk("Schnell, hoher Druck."), variant: "fast" },
    normal: { label: tk("🎯 Standard"), seconds: 25, hint: tk("Ausgewogenes Tempo."), variant: "normal" },
    calm: { label: tk("🧊 Casual"), seconds: 40, hint: tk("Entspannt, mehr Zeit."), variant: "calm" },
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
        desc: tk("Standard-Regeln. Beste Basis für alle."),
        featured: true,
        variant: "original",
    },
    teleport: {
        label: "Teleport",
        icon: "🌀",
        desc: tk("Die Kartoffel springt bei jedem Pass zu einem zufälligen Spieler."),
        disabled: true,
        comingSoon: true,
        variant: "teleport",
    },
    reverse: {
        label: "Reverse",
        icon: "🔁",
        desc: tk("Die Richtung wechselt gelegentlich. Mehr Chaos, mehr Lacher."),
        disabled: true,
        comingSoon: true,
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
    if (err instanceof Error) return errorText(err.message);
    if (typeof err === "object" && err !== null && "message" in err) {
        const m = (err as { message?: unknown }).message;
        if (typeof m === "string") return errorText(m);
    }
    return trNow("Unbekannter Fehler.");
}

export default function HostPage() {
    const supabase = getSupabaseClient();
    const router = useRouter();
    const { user } = useAuth();
    const { profile, savePreferences } = useProfile();
    const { tr } = useI18n();

    const [hostName, setHostName] = useState("");
    // Mit Konto steht der Name fest (Spielername, sonst Benutzername) – ändern nur in den Einstellungen.
    useEffect(() => {
        const u = profile?.playerName;
        if (u) setHostName(u.slice(0, 24));
    }, [profile?.playerName]);
    const [maxPlayers, setMaxPlayers] = useState(6);
    // Öffentlich = im Hauptmenü unter "Offene Lobbys" sichtbar (Migration 104). Standard an, Wahl wird gemerkt.
    const [isPublic, setIsPublic] = useState(true);
    useEffect(() => {
        try {
            if (window.localStorage.getItem("kumpir_host_public") === "0") setIsPublic(false);
        } catch {
            /* privater Modus */
        }
    }, []);
    const togglePublic = useCallback(() => {
        setIsPublic((v) => {
            try {
                window.localStorage.setItem("kumpir_host_public", v ? "0" : "1");
            } catch {
                /* privater Modus */
            }
            return !v;
        });
    }, []);

    const [roundSpeed, setRoundSpeed] = useState<RoundSpeed | null>("normal");
    // Original ist aktuell der einzige spielbare Modus (Teleport/Reverse
    // sind mit "SOON" gesperrt) -- direkt vorausgewählt, damit man nicht
    // erst klicken muss.
    const [mode, setMode] = useState<ModeKey | null>("original");
    // Anzahl Runden pro Match: nach jeder Runde Zwischenstand + neues Themen-Voting.
    const [seriesTotal, setSeriesTotal] = useState<1 | 3 | 5>(1);

    // Gespeicherte Host-Standards aus den Konto-Einstellungen (einmal beim Laden übernehmen).
    // Playlists: Standard alle; im Konto rausgenommene bleiben draußen (wird beim Erstellen gemerkt)
    const [allPlaylists, setAllPlaylists] = useState<string[]>([]);
    const [playlists, setPlaylists] = useState<string[]>([]);
    useEffect(() => {
        let alive = true;
        void loadPlaylists().then((list) => {
            if (!alive) return;
            const names = list.map((p) => p.name);
            setAllPlaylists(names);
            setPlaylists((cur) => (cur.length ? cur : names));
        });
        return () => {
            alive = false;
        };
    }, []);
    const appliedPlaylistPrefs = useRef(false);
    useEffect(() => {
        const ex = profile?.preferences?.host?.excludedPlaylists;
        if (!ex || !allPlaylists.length || appliedPlaylistPrefs.current) return;
        appliedPlaylistPrefs.current = true;
        setPlaylists(selectedFromExcluded(allPlaylists, ex));
    }, [profile?.preferences?.host?.excludedPlaylists, allPlaylists]);

    const appliedHostPrefs = useRef(false);
    useEffect(() => {
        const h = profile?.preferences?.host;
        if (!h || appliedHostPrefs.current) return;
        appliedHostPrefs.current = true;
        if (h.maxPlayers) setMaxPlayers(h.maxPlayers);
        if (h.speed) setRoundSpeed(h.speed);
        if (h.rounds) setSeriesTotal(h.rounds);
    }, [profile?.preferences?.host]);

    const activeMode = mode ? MODES[mode] : null;
    const activeSpeed = roundSpeed ? ROUND_SPEEDS[roundSpeed] : null;

    const [creating, setCreating] = useState(false);
    const [createError, setCreateError] = useState("");

    // Kategorie: mit Freunden (Lobby + Code) oder direkt gegen Bots (ein Klick, sofort Spiel)
    const [category, setCategory] = useState<"friends" | "bots">("friends");
    useEffect(() => {
        if (new URLSearchParams(window.location.search).get("modus") === "bots") setCategory("bots");
    }, []);
    const [botCount, setBotCount] = useState(3);
    const [botSkill, setBotSkill] = useState<BotSkill>("mixed");
    const appliedSoloPrefs = useRef(false);
    useEffect(() => {
        const s = profile?.preferences?.solo;
        if (!s || appliedSoloPrefs.current) return;
        appliedSoloPrefs.current = true;
        if (s.bots) setBotCount(Math.max(1, Math.min(5, s.bots)));
        if (s.skill) setBotSkill(s.skill);
    }, [profile?.preferences?.solo]);
    const [botBusy, setBotBusy] = useState(false);
    const [botError, setBotError] = useState("");

    const inFlightRef = useRef(false);

    const nameValidation = useMemo(() => validatePlayerName(hostName), [hostName]);
    const isNameValid = nameValidation.ok;
    // Angemeldet: Name kommt aus dem Konto (Spielername, sonst Benutzername) – kein Eingabefeld (Wunsch Mehdi)
    const nameFromAccount = !!user;
    const nameError = useMemo(() => {
        if (!hostName.length) return "";
        if ("message" in nameValidation) return nameValidation.message;
        return "";
    }, [hostName, nameValidation]);

    const canCreate = isNameValid && !!roundSpeed && !!mode && !creating;

    const onCreate = useCallback<() => Promise<void>>(async () => {
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
                p_privacy: "private",
                p_max_players: maxPlayers,
                p_round_seconds: roundSeconds,
                p_user_id: user?.id ?? null,
                p_round_speed: roundSpeed,
            });

            if (error) {
                setCreateError(errorText(error.message, tr("Lobby konnte nicht erstellt werden.")));
                return;
            }

            const row = Array.isArray(data) ? data[0] : data;
            const code = String(row?.code ?? "").toUpperCase();
            const hostPlayerId = String(row?.host_player_id ?? "");

            if (!code || code.length !== 4) {
                setCreateError(tr("Lobby konnte nicht erstellt werden."));
                return;
            }
            if (!hostPlayerId) {
                setCreateError(tr("Lobby konnte nicht erstellt werden."));
                return;
            }

            setStoredPlayerId(hostPlayerId);

            const ensure = await supabase.rpc("rpc_join_lobby", {
                p_code: code,
                p_player_id: hostPlayerId,
                p_name: cleanName,
                p_user_id: user?.id ?? null,
            });

            if (ensure.error) {
                setCreateError(errorText(ensure.error.message, tr("Host konnte nicht als Spieler eingetragen werden.")));
                return;
            }

            // Musik läuft jetzt immer (kein Aus/An-Schalter mehr) -- jede Runde
            // zieht aus den Musik-Kategorien, bis es einen echten neuen Modus
            // dafür gibt. set_lobby_topic_filter läuft deshalb immer mit,
            // unabhängig von mode/answerMode.
            {
                const { data: lobbyRow, error: lobbyErr } = await supabase
                    .from("lobbies")
                    .select("id")
                    .eq("code", code)
                    .single();

                if (!lobbyErr && lobbyRow?.id) {
                    if (isPublic) {
                        await supabase.rpc("set_lobby_privacy", {
                            p_lobby_id: lobbyRow.id,
                            p_me_player_id: hostPlayerId,
                            p_privacy: "public",
                        });
                    }
                    if (mode && mode !== "original") {
                        await supabase.rpc("set_lobby_mode", {
                            p_lobby_id: lobbyRow.id,
                            p_me_player_id: hostPlayerId,
                            p_mode: mode,
                        });
                    }
                    if (seriesTotal !== 1) {
                        await supabase.rpc("set_lobby_series", {
                            p_lobby_id: lobbyRow.id,
                            p_me_player_id: hostPlayerId,
                            p_total: seriesTotal,
                        });
                    }
                    // Alle ausgewählt -> leerer Filter = "alle", auch künftig neue Playlists
                    const allSelected = !allPlaylists.length || allPlaylists.every((n) => playlists.includes(n));
                    await supabase.rpc("set_lobby_topic_filter", {
                        p_lobby_id: lobbyRow.id,
                        p_me_player_id: hostPlayerId,
                        p_categories: allSelected ? [] : playlists,
                    });
                    if (user?.id && allPlaylists.length) {
                        const excluded = allPlaylists.filter((n) => !playlists.includes(n));
                        const before = profile?.preferences?.host?.excludedPlaylists ?? [];
                        if ([...excluded].sort().join("|") !== [...before].sort().join("|")) {
                            void savePreferences({ host: { excludedPlaylists: excluded } });
                        }
                    }
                }
            }

            track("host_created");
            router.push(`/lobby/${code}`);
        } catch (e: unknown) {
            setCreateError(getErrorMessage(e));
        } finally {
            setCreating(false);
            inFlightRef.current = false;
        }
    }, [canCreate, hostName, roundSpeed, mode, seriesTotal, isPublic, tr, supabase, maxPlayers, router, user?.id, allPlaylists, playlists, profile?.preferences?.host?.excludedPlaylists, savePreferences]);

    const onStartBots = async () => {
        setBotError("");
        if (!isNameValid || botBusy || !roundSpeed) return;
        setBotBusy(true);
        try {
            const cleanName = hostName.trim();
            setStoredName(cleanName);
            const allSelected = !allPlaylists.length || allPlaylists.every((n) => playlists.includes(n));
            track("solo_start");
            const code = await startBotGame({
                name: cleanName,
                userId: user?.id ?? null,
                bots: botCount,
                skill: botSkill,
                speed: roundSpeed,
                roundSeconds: ROUND_SPEEDS[roundSpeed].seconds,
                seriesTotal,
                topicFilter: allSelected ? [] : playlists,
            });
            // Auswahl fürs nächste Mal im Konto merken
            if (user?.id) {
                const s = profile?.preferences?.solo;
                if (s?.bots !== botCount || s?.skill !== botSkill) void savePreferences({ solo: { bots: botCount, skill: botSkill } });
            }
            track("solo_game_started");
            router.push(`/game/${code}`);
        } catch (e: unknown) {
            setBotError(errorText(e instanceof Error ? e.message : ""));
            setBotBusy(false);
        }
    };

    return (
        <main className="container hostMain">
            <div className="landingWrap">
                <section className="card" aria-label={tr("Spiel erstellen")}>
                    <HomeButton corner />
                    <header className="hostHeader">
                        <div className="hostTitleRow" style={{ justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                            <h1 className="h1">{category === "bots" ? tr("Gegen Bots") : tr("Lobby hosten")}</h1>
                        </div>
                        <p className="p hostSub">
                            {category === "bots" ? tr("Bots aussuchen, Stärke wählen, los – das Spiel startet sofort.") : tr("Erstelle eine Lobby, teile den Code und spiel mit deinen Freunden!")}
                        </p>
                    </header>

                    <div className="hostCats" role="tablist" aria-label={tr("Art des Spiels")}>
                        <button type="button" role="tab" aria-selected={category === "friends"} className={`hostCat ${category === "friends" ? "on" : ""}`} onClick={() => setCategory("friends")}>
                            <span className="hostCatIcon" aria-hidden>👥</span>
                            <span className="hostCatTitle">{tr("Mit Freunden")}</span>
                            <span className="hostCatText">{tr("Lobby + Code zum Teilen")}</span>
                        </button>
                        <button type="button" role="tab" aria-selected={category === "bots"} className={`hostCat ${category === "bots" ? "on" : ""}`} onClick={() => setCategory("bots")}>
                            <span className="hostCatIcon" aria-hidden>🤖</span>
                            <span className="hostCatTitle">{tr("Gegen Bots")}</span>
                            <span className="hostCatText">{tr("Allein spielen, sofort los")}</span>
                        </button>
                    </div>

                    <div className="hostGrid" style={{ gridTemplateColumns: "1fr" }}>
                        <div className="panel">
                            {nameFromAccount ? (hostName ? <AccountNameNote name={hostName} /> : null) : (
                            <>
                            <div className="panelHead">
                                <div className="panelTitle">{tr("Spieler-Details")}</div>
                                <div className="panelHint">{tr("Du kannst das später ändern.")}</div>
                            </div>

                            <div className="fieldBlock">
                                <div className="fieldTop">
                                    <div className="fieldTitle">{tr("Dein Name")}</div>
                                    <div className="fieldHint">{tr("Mindestens 2 Zeichen")}</div>
                                </div>

                                <div className="pillInputWrap">
                                    <span className="pillIcon" aria-hidden>👤</span>
                                    <input
                                        className="pillInput"
                                        value={hostName}
                                        onChange={(e) => setHostName(e.target.value)}
                                        placeholder={tr("z. B. Steve")}
                                        autoComplete="nickname"
                                        maxLength={24}
                                        aria-label={tr("Dein Name")}
                                    />
                                    <div className="pillRight" aria-hidden>
                                        <button
                                            type="button"
                                            className="pillIconBtn"
                                            onClick={() => setHostName(randomHostName())}
                                            title={tr("Zufälliger Name")}
                                        >
                                            🎲
                                        </button>
                                        <span className="pillChip">{Math.min(hostName.trim().length, 24)}/24</span>
                                    </div>
                                </div>

                                {nameError ? <div className="fieldHelp fieldHelpError">{nameError}</div> : null}
                            </div>

                            <div className="divider" />
                            </>
                            )}

                            {category === "friends" ? (
                            <>
                            <div className="pillCard">
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">{tr("Max. Spieler")}</div>
                                    <div className="pillCardHint">{tr("Empfohlen: 4–8 · max. 12")}</div>
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


                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">{tr("Modus")}</div>
                                    <div className="pillCardHint">{tr("Wähle die Regeln für die Runde")}</div>
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
                                                title={m.comingSoon ? tr("Kommt bald") : undefined}
                                            >
                                                <span className="segIcon" aria-hidden>{m.icon}</span>
                                                <span className="segLabel">{m.label}</span>
                                                {m.featured ? <span className="segBadge">✨</span> : null}
                                                {m.comingSoon ? <span className="segSoon">{tr("BALD")}</span> : null}
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
                                            {tr(activeMode.desc)}
                                        </>
                                    ) : (
                                        <span style={{ fontWeight: 900 }}>{tr("Bitte Modus auswählen.")}</span>
                                    )}
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">{tr("Tempo")}</div>
                                    <div className="pillCardHint">{activeSpeed ? tr(activeSpeed.hint) : tr("Bitte auswählen.")}</div>
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
                                                <span className="segLabel">{tr(s.label)}</span>
                                            </button>
                                        );
                                    })}
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">{tr("Runden pro Match")}</div>
                                    <div className="pillCardHint">
                                        {seriesTotal === 1 ? tr("Eine einzelne Runde") : tr("{n} Runden mit Zwischenstand und Gesamtwertung", { n: seriesTotal })}
                                    </div>
                                </div>
                                <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                    {([1, 3, 5] as const).map((n) => (
                                        <button
                                            key={n}
                                            type="button"
                                            className={`pillSegBtn segChoice ${seriesTotal === n ? "segChoiceActive" : ""}`}
                                            onClick={() => setSeriesTotal(n)}
                                            aria-pressed={seriesTotal === n}
                                        >
                                            <span className="segLabel">{n === 1 ? tr("1 Runde") : tr("{n} Runden", { n })}</span>
                                        </button>
                                    ))}
                                </div>
                                <div className="fieldHelp" style={{ marginTop: 10, opacity: 0.9 }}>
                                    {tr("Nach jeder Runde (bis nur noch einer übrig ist) wird der Zwischenstand gespeichert und es geht wieder ins Themen-Voting.")}
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">🎵 Playlists</div>
                                    <div className="pillCardHint">{tr("Antippen = rausnehmen")}</div>
                                </div>
                                <div className="fieldHelp" style={{ opacity: 0.9, marginBottom: 8 }}>
                                    {tr("Jede Runde wird eine der ausgewählten Playlists gespielt – der Halter hört einen Song-Schnipsel und muss Titel oder Interpret erraten.")}
                                </div>
                                <PlaylistPicker selected={playlists} onChange={setPlaylists} />
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
                                    {creating ? tr("⏳ Lobby wird erstellt…") : tr("🚀 Lobby erstellen")}
                                </button>
                                <button
                                    type="button"
                                    className={`publicToggle ${isPublic ? "on" : ""}`}
                                    role="switch"
                                    aria-checked={isPublic}
                                    onClick={togglePublic}
                                >
                                    <span className="publicToggleText">
                                        <b>{isPublic ? tr("🌍 Öffentlich") : tr("🔒 Nur mit Code")}</b>
                                        <span>{isPublic ? tr("Alle sehen die Lobby im Hauptmenü und können direkt beitreten") : tr("Nur wer den Code oder eine Einladung hat, kommt rein")}</span>
                                    </span>
                                    <span className="publicSwitch" aria-hidden>
                                        <span />
                                    </span>
                                </button>

                            </div>
                            </>
                            ) : (
                            <>
                                <div className="pillCard">
                                    <div className="pillCardTop">
                                        <div className="pillCardTitle">{tr("Wie viele Bots?")}</div>
                                        <div className="pillCardHint">{tr("1 bis 5 Gegner")}</div>
                                    </div>
                                    <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                        {[1, 2, 3, 4, 5].map((n) => (
                                            <button
                                                key={n}
                                                type="button"
                                                className={`pillSegBtn segChoice ${botCount === n ? "segChoiceActive" : ""}`}
                                                onClick={() => setBotCount(n)}
                                                aria-pressed={botCount === n}
                                            >
                                                <span className="segLabel">{"🤖".repeat(Math.min(n, 3))}{n > 3 ? "+" : ""} {n}</span>
                                            </button>
                                        ))}
                                    </div>
                                </div>

                                <div className="pillCard" style={{ marginTop: 14 }}>
                                    <div className="pillCardTop">
                                        <div className="pillCardTitle">{tr("Stärke")}</div>
                                        <div className="pillCardHint">
                                            {botSkill === "1" ? tr("Raten oft daneben, lassen sich Zeit") : botSkill === "2" ? tr("Kennen viele Songs") : botSkill === "3" ? tr("Schnell und treffsicher") : tr("Bunt gemischt – vom Anfänger bis zum Profi")}
                                        </div>
                                    </div>
                                    <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                        {(["1", "2", "3", "mixed"] as BotSkill[]).map((k) => (
                                            <button
                                                key={k}
                                                type="button"
                                                className={`pillSegBtn segChoice ${botSkill === k ? "segChoiceActive" : ""}`}
                                                onClick={() => setBotSkill(k)}
                                                aria-pressed={botSkill === k}
                                            >
                                                <span className="segLabel">
                                                    {k === "1" ? "🌱" : k === "2" ? "🎧" : k === "3" ? "🔥" : "🎲"} {tr(SOLO_SKILL_LABEL[k])}
                                                </span>
                                            </button>
                                        ))}
                                    </div>
                                </div>

                                <div className="pillCard" style={{ marginTop: 14 }}>
                                    <div className="pillCardTop">
                                        <div className="pillCardTitle">{tr("Tempo")}</div>
                                        <div className="pillCardHint">{activeSpeed ? tr(activeSpeed.hint) : tr("Bitte auswählen.")}</div>
                                    </div>
                                    <div className="pillSeg" style={{ flexWrap: "wrap" }}>
                                        {(Object.keys(ROUND_SPEEDS) as RoundSpeed[]).map((key) => (
                                            <button
                                                key={key}
                                                type="button"
                                                className={`pillSegBtn segChoice ${roundSpeed === key ? "segChoiceActive" : ""}`}
                                                data-variant={ROUND_SPEEDS[key].variant}
                                                onClick={() => setRoundSpeed(key)}
                                                aria-pressed={roundSpeed === key}
                                            >
                                                <span className="segLabel">{tr(ROUND_SPEEDS[key].label)}</span>
                                            </button>
                                        ))}
                                    </div>
                                </div>

                                {botError ? (
                                    <div className="fieldHelp fieldHelpError" style={{ marginTop: 12 }}>
                                        {botError}
                                    </div>
                                ) : null}

                                <div className="actionsRow" style={{ alignItems: "center", marginTop: 14 }}>
                                    <button
                                        type="button"
                                        onClick={() => void onStartBots()}
                                        disabled={!isNameValid || botBusy || !roundSpeed}
                                        className={`btn btnPrimary btnXL ${isNameValid && !botBusy ? "btnGlow" : "btnDisabled"}`}
                                    >
                                        {botBusy ? tr("⏳ Bots machen sich bereit…") : botCount === 1 ? tr("🤖 Gegen 1 Bot spielen") : tr("🤖 Gegen {n} Bots spielen", { n: botCount })}
                                    </button>
                                </div>
                            </>
                            )}
                        </div>
                    </div>
                </section>

                <RulesCard defaultOpen={false} variant="outside" />
            </div>
        </main>
    );
}