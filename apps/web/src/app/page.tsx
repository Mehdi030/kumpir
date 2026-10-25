"use client";

import { AchievementRecap } from "@/components/AchievementRecap";
import Link from "next/link";
import { Suspense, useEffect } from "react";
import { AuthMini } from "@/components/AuthMini";
import { LobbyExitNotice } from "@/components/LobbyExitNotice";
import { OpenLobbies } from "@/components/OpenLobbies";
import { HomeSideDrawers } from "@/components/HomeSideDrawers";
import { HomePotato } from "@/components/HomePotato";
import { HomeFireBed } from "@/components/HomeFireBed";
import { LanguageSwitch } from "@/components/LanguageSwitch";
import { PwaSetup } from "@/components/PwaSetup";
import { useI18n } from "@/lib/i18n";
import { useMediaQuery } from "@/hooks/useMediaQuery";
import { track } from "@/lib/track";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

export default function Home() {
    const { t, tr } = useI18n();
    // Statistik links und Freunde rechts als eingeklappte Laschen am Rand, die sich weich aufklappen (Wunsch Mehdi 2026-10-25) –
    // auf allen Bildschirmen, so bleibt die Karte frei und das Hauptmenü passt immer auf einen Bildschirm.
    const wide = useMediaQuery("(min-width: 900px)");
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
            <AchievementRecap />
            <HomeFireBed />
            <div className="landingWrap landingWrapDecor">
                <div className="potatoBg" aria-hidden="true">
                    <HomePotato />
                </div>

                <section className="card homeCard" aria-label={tr("Kumpir Startseite")}>
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

                    {/* Schmal: offene Lobbys direkt in der Karte, nur wenn es welche gibt (breit stehen sie in der Freunde-Lasche) */}
                    {!wide ? <OpenLobbies variant="inline" /> : null}
                    <PwaSetup showHint />
                </section>

                <HomeSideDrawers />

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
