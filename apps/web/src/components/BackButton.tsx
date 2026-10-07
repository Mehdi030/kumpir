"use client";

import Link from "next/link";

/**
 * Einheitlicher, gut sichtbarer Knopf zurück zum Hauptmenü – immer oben rechts in der Karte.
 * corner = als erstes Kind direkt in die Karte setzen (absolut oben rechts; am Handy oben rechts im Fluss).
 * Ohne corner steht er dort, wo er eingesetzt wird (z. B. rechts in einer Kopfzeile).
 */
export function HomeButton({ corner = false, label = "Hauptmenü", className = "" }: { corner?: boolean; label?: string; className?: string }) {
    return (
        <Link href="/" className={`homeBackBtn ${corner ? "cardCorner" : ""} ${className}`}>
            <span aria-hidden>🏠</span> {label}
        </Link>
    );
}

/** Zurück zu einer bestimmten Seite (z. B. zum Login) – gleicher Look, oben rechts in der Karte. */
export function BackButton({ href = "/", label = "Hauptmenü", corner = true }: { href?: string; label?: string; corner?: boolean }) {
    if (href === "/") return <HomeButton corner={corner} label={label} />;
    return (
        <Link href={href} className={`homeBackBtn ${corner ? "cardCorner" : ""}`}>
            <span aria-hidden>←</span> {label}
        </Link>
    );
}
