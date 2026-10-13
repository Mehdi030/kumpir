"use client";

import Link from "next/link";
import { useI18n } from "@/lib/i18n";

/** Inhalt der 404-Seite (Client, damit er der gewählten Sprache folgt). */
export function NotFoundContent() {
    const { tr } = useI18n();
    return (
        <section className="card nfCard" aria-label={tr("Seite nicht gefunden")}>
            <div className="nfPotato" aria-hidden>
                🥔
            </div>
            <div className="nfCode">404</div>
            <h1 className="h1 nfTitle">{tr("Hier ist nichts heiß.")}</h1>
            <p className="p hostSub nfText">{tr("Diese Seite gibt es nicht – vielleicht ein alter Link oder ein Tippfehler. Die Kartoffel wartet woanders auf dich.")}</p>
            <div className="ctaRow nfActions">
                <Link href="/" className="btn btnPrimary">
                    🏠 {tr("Zur Startseite")}
                </Link>
                <Link href="/join" className="btn btnSecondary">
                    {tr("Mit Code beitreten")}
                </Link>
            </div>
        </section>
    );
}
