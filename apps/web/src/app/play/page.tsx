"use client";

import Link from "next/link";
import { useI18n } from "@/lib/i18n";

/**
 * "Jetzt spielen": hier entscheidet man, ob man allein gegen Bots oder mit Freunden spielt.
 * (Das Hauptmenü bleibt dadurch schlank: Jetzt spielen + Mit Code beitreten.)
 */
export default function PlayPage() {
    const { t } = useI18n();
    return (
        <main className="container">
            <div className="landingWrap homeWrap">
                <section className="card playCard" aria-label={t("play.title")}>
                    <div className="homeTop">
                        <Link href="/" className="homeLink">
                            {t("play.back")}
                        </Link>
                    </div>

                    <header className="homeHero" style={{ marginTop: 8 }}>
                        <h1 className="h1" style={{ fontSize: "clamp(30px, 6vw, 46px)" }}>
                            {t("play.title")}
                        </h1>
                        <p className="homeTagline">{t("play.sub")}</p>
                    </header>

                    <div className="playChoices">
                        <Link href="/solo" className="playChoice playChoicePrimary">
                            <span className="playChoiceIcon" aria-hidden>
                                🤖
                            </span>
                            <span className="playChoiceTitle">{t("play.solo.title")}</span>
                            <span className="playChoiceText">{t("play.solo.text")}</span>
                        </Link>
                        <Link href="/host" className="playChoice">
                            <span className="playChoiceIcon" aria-hidden>
                                🚀
                            </span>
                            <span className="playChoiceTitle">{t("play.host.title")}</span>
                            <span className="playChoiceText">{t("play.host.text")}</span>
                        </Link>
                    </div>
                </section>
            </div>
        </main>
    );
}
