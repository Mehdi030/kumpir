"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { useProfile } from "@/hooks/useProfile";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getSessionToken } from "@/lib/playerSession";
import { MUSIC_GENRE_KEYS } from "@/lib/musicGenres";
import { startGame } from "@/actions/startGame";
import { Spinner } from "@/components/Spinner";
import { useI18n } from "@/lib/i18n";

const NAMES = ["Baro", "Medo", "Sero", "Sinan", "Elias", "Jonas", "Max", "Leo", "Emir", "Can", "Ali", "Omar", "Nico", "Sami", "Amir", "Milan"];
const BOTS: { name: string; skill: 1 | 2 | 3 }[] = [
    { name: "Bot Anna", skill: 1 },
    { name: "Bot Ben", skill: 2 },
    { name: "Bot Cleo", skill: 1 },
];

// Suchmaschinen-Crawler führen JavaScript aus – die sollen keine echten Lobbys anlegen.
// Bewusst konkrete Namen statt nur "bot" (sonst träfe es z. B. Handys der Marke CUBOT).
// Wird jemand fälschlich erkannt, sieht er einen Start-Knopf statt eines Auto-Starts.
const CRAWLER_UA = /googlebot|bingbot|yandex|baiduspider|duckduckbot|applebot|petalbot|ahrefsbot|semrushbot|crawler|spider|slurp|lighthouse|headlesschrome/i;

function storedName(): string {
    try {
        return (localStorage.getItem("kumpir_player_name") || "").trim();
    } catch {
        return "";
    }
}

/**
 * Solo gegen Bots: erstellt mit EINEM Tipp eine Lobby, fügt 3 Bots hinzu und startet die Themenwahl.
 * Gedacht für alle, die Kumpir erst einmal allein ausprobieren wollen.
 */
export default function SoloPage() {
    const router = useRouter();
    const { t } = useI18n();
    const { user, loading: authLoading } = useAuth();
    const { profile, loading: profileLoading } = useProfile();
    const [step, setStep] = useState<"solo.creating" | "solo.bots" | "solo.go">("solo.creating");
    const [error, setError] = useState("");
    const [needsTap, setNeedsTap] = useState(false);
    const startedRef = useRef(false);

    const run = useCallback(async () => {
        setError("");
        try {
            const supabase = getSupabaseClient();
            const name = (profile?.username || storedName() || NAMES[Math.floor(Math.random() * NAMES.length)]!).slice(0, 24);

            const { data, error: cErr } = await supabase.rpc("rpc_create_lobby", {
                p_host_name: name,
                p_privacy: "private",
                p_max_players: 6,
                p_round_seconds: 25,
                p_user_id: user?.id ?? null,
                p_round_speed: "normal",
            });
            if (cErr) throw new Error(cErr.message);
            const row = Array.isArray(data) ? data[0] : data;
            const code = String(row?.code ?? "").toUpperCase();
            const me = String(row?.host_player_id ?? "");
            if (code.length !== 4 || !me) throw new Error("Lobby konnte nicht erstellt werden.");

            try {
                localStorage.setItem("kumpir_player_name", name);
                localStorage.setItem("kumpir_player_id", me);
                sessionStorage.setItem("kumpir_player_name", name);
                sessionStorage.setItem("kumpir_player_id", me);
            } catch {
                /* private mode */
            }

            const join = await supabase.rpc("rpc_join_lobby", { p_code: code, p_player_id: me, p_name: name, p_user_id: user?.id ?? null });
            if (join.error) throw new Error(join.error.message);

            setStep("solo.bots");
            const { data: lobby, error: lErr } = await supabase.from("lobbies").select("id").eq("code", code).single();
            if (lErr || !lobby?.id) throw new Error(lErr?.message ?? "Lobby nicht gefunden.");

            await supabase.rpc("set_lobby_topic_filter", { p_lobby_id: lobby.id, p_me_player_id: me, p_categories: MUSIC_GENRE_KEYS });
            for (const b of BOTS) {
                const { error: bErr } = await supabase.rpc("rpc_add_bot", { p_lobby_id: lobby.id, p_me_player_id: me, p_bot_name: b.name, p_skill: b.skill });
                if (bErr) throw new Error(bErr.message);
            }

            setStep("solo.go");
            const res = await startGame(code, me, getSessionToken() ?? "");
            if (!res.ok) throw new Error("error" in res ? res.error : "Start fehlgeschlagen.");
            router.replace(`/game/${code}`);
        } catch (e: unknown) {
            setError(e instanceof Error ? e.message : "Unbekannter Fehler.");
        }
    }, [profile?.username, router, user?.id]);

    useEffect(() => {
        if (startedRef.current) return;
        if (authLoading || profileLoading) return; // erst wissen, ob ein Konto da ist (Name, Statistik)
        startedRef.current = true;
        if (CRAWLER_UA.test(navigator.userAgent)) {
            // nach dem Rendern umschalten (kein setState direkt im Effekt)
            window.setTimeout(() => setNeedsTap(true), 0);
            return;
        }
        void run();
    }, [authLoading, profileLoading, run]);

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" style={{ textAlign: "center" }} aria-label="Solo-Spiel wird vorbereitet">
                    <div style={{ fontSize: 44 }} aria-hidden>
                        🤖
                    </div>
                    <h1 className="h1" style={{ fontSize: 34, marginTop: 6 }}>
                        {t("solo.title")}
                    </h1>
                    {needsTap && !error ? (
                        <div className="ctaRow" style={{ marginTop: 16 }}>
                            <button
                                type="button"
                                className="btn btnPrimary btnXL"
                                onClick={() => {
                                    setNeedsTap(false);
                                    void run();
                                }}
                            >
                                {t("home.solo")}
                            </button>
                        </div>
                    ) : error ? (
                        <>
                            <p className="p" style={{ marginTop: 12, color: "#ffd0c8" }}>
                                {t("solo.failed")} {error}
                            </p>
                            <div className="ctaRow" style={{ marginTop: 16 }}>
                                <button
                                    type="button"
                                    className="btn btnPrimary btnXL"
                                    onClick={() => {
                                        startedRef.current = true;
                                        void run();
                                    }}
                                >
                                    {t("solo.retry")}
                                </button>
                                <Link href="/" className="btn btnSecondary btnXL">
                                    {t("solo.home")}
                                </Link>
                            </div>
                        </>
                    ) : (
                        <div style={{ marginTop: 16, display: "grid", placeItems: "center", gap: 10 }} role="status" aria-live="polite">
                            <Spinner size={26} label={t(step)} />
                            <p className="p" style={{ opacity: 0.8, fontSize: 14, maxWidth: 360 }}>
                                {t("solo.info")}
                            </p>
                        </div>
                    )}
                </section>
            </div>
        </main>
    );
}
