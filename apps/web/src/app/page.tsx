"use client";

import Link from "next/link";
import { Suspense, useEffect } from "react";
import { AuthMini } from "@/components/AuthMini";
import { LobbyExitNotice } from "@/components/LobbyExitNotice";
import { OpenLobbies } from "@/components/OpenLobbies";
import { HomeFriends, HomeFriendsButton } from "@/components/HomeFriends";
import { HomePotato } from "@/components/HomePotato";
import { HomeStatsSection } from "@/components/HomeStatsSection";
import { LanguageSwitch } from "@/components/LanguageSwitch";
import { PwaSetup } from "@/components/PwaSetup";
import { useI18n } from "@/lib/i18n";
import { useMediaQuery } from "@/hooks/useMediaQuery";
import { track } from "@/lib/track";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

export default function Home() {
    const { t } = useI18n();
    // Breite Bildschirme: Statistik links, Freunde rechts als feste Leisten. Sonst je ein Knopf in der Karte.
    // So passt das Hauptmenü immer auf einen Bildschirm, ohne Scrollen (Wunsch Mehdi 2026-10-12).
    const wide = useMediaQuery("(min-width: 1300px)");
    useEffect(() => {
        track("home_view");
    }, []);
    const STEPS = [
        { icon: "🎲", title: t("home.step1.title"), text: t("home.step1.text") },
        { icon: "🎧", title: t("home.step2.title"), text: t("home.step2.text") },
        { icon: "💥", title: t("home.step3.title"), text: t("home.step3.text") },
    ];
    return (
        <main className="container homeMain">
            <div className="landingWrap landingWrapDecor">
                <div className="potatoBg" aria-hidden="true">
                    <HomePotato />
                </div>

                <section className="card homeCard" aria-label="Kumpir Startseite">
                    <Suspense fallback={null}>
                        <LobbyExitNotice />
                    </Suspense>

                    <div className="homeTop">
                        <span className="homeBadge">{t("home.players")}</span>
                        <div className="homeTopRight">
                            <LanguageSwitch />
                            {!AUTH_DISABLED ? <AuthMini nextPath="/" variant="header" /> : null}
                        </div>
                    </div>

                    <header className="homeHero">
                        <h1 className="h1 homeTitle">Kumpir</h1>
                        <p className="homeTagline">{t("home.tagline")}</p>
                    </header>

                    <div className="ctaRow homeCta">
                        <Link href="/host" className="btn btnPrimary btnXL">
                            {t("home.play")}
                        </Link>
                        <Link href="/join" className="btn btnSecondary btnXL">
                            {t("home.join")}
                        </Link>
                    </div>
                    <p className="homeFree">{t("home.free")}</p>

                    <div className="homeSteps">
                        {STEPS.map((s, i) => (
                            <div key={s.title} className="homeStep">
                                <div className="homeStepIcon" aria-hidden>
                                    {s.icon}
                                </div>
                                <div className="homeStepTitle">
                                    {i + 1}. {s.title}
                                </div>
                                <div className="homeStepText">{s.text}</div>
                            </div>
                        ))}
                    </div>

                    {!wide ? (
                        <>
                            <div className="homeQuick">
                                <HomeStatsSection variant="chip" />
                                <HomeFriendsButton />
                            </div>
                            {/* Schmal: offene Lobbys unter dem Freunde-Knopf, nur wenn es welche gibt */}
                            <OpenLobbies variant="inline" />
                        </>
                    ) : null}
                    <PwaSetup showHint />
                </section>

                {wide ? (
                    <>
                        <HomeStatsSection variant="dock" />
                        <HomeFriends withOpenLobbies />
                    </>
                ) : null}

                <footer className="homeFooter">
                    v{process.env.NEXT_PUBLIC_BUILD_SHA ?? "dev"} ·{" "}
                    <a href="https://github.com/microsoft/fluentui-emoji" target="_blank" rel="noopener noreferrer">
                        Emojis: Microsoft Fluent Emoji
                    </a>{" "}
                    (MIT)
                </footer>
            </div>
        </main>
    );
}
