"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";

/**
 * Einheitlicher Zurück-Knopf oben links über der Karte.
 * Kam man von einer Kumpir-Seite, geht es genau dorthin zurück; sonst (direkt geöffnet, Link von außen) zu `href`.
 */
export function BackButton({ href = "/", label = "Zurück" }: { href?: string; label?: string }) {
    const router = useRouter();
    return (
        <Link
            href={href}
            className="backBtn"
            onClick={(e) => {
                if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
                let sameSite = false;
                try {
                    sameSite = !!document.referrer && new URL(document.referrer).origin === window.location.origin;
                } catch {}
                if (sameSite && window.history.length > 1) {
                    e.preventDefault();
                    router.back();
                }
            }}
        >
            <span aria-hidden className="backBtnArrow">
                ←
            </span>
            {label}
        </Link>
    );
}
