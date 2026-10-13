"use client";

import { useEffect } from "react";
import { LOCALES, trIn, tk, useI18n } from "@/lib/i18n";

/** Seitentitel aus den (deutschen) Metadaten, die im Browser-Tab übersetzt werden. */
const TITLES = [tk("Kumpir – Heiße Kartoffel"), tk("Lobby beitreten"), tk("Solo gegen Bots"), tk("Seite nicht gefunden")];

/**
 * Setzt das lang-Attribut der Seite passend zur gewählten Sprache (Screenreader, Browser-Übersetzer)
 * und übersetzt den Titel im Browser-Tab (die Metadaten kommen vom Server immer auf Deutsch).
 */
export function LocaleSync() {
    const { locale } = useI18n();
    useEffect(() => {
        document.documentElement.lang = locale;
        const fix = () => {
            const t = document.title;
            for (const de of TITLES) {
                // Titel kann gerade in jeder Sprache dastehen (z. B. nach dem Zurückwechseln auf Deutsch)
                const found = LOCALES.map((l) => trIn(l, de)).find((v) => t.includes(v));
                if (found) {
                    const next = t.replace(found, trIn(locale, de));
                    if (next !== t) document.title = next;
                    return;
                }
            }
        };
        fix();
        // Next.js setzt den Titel bei jedem Seitenwechsel neu -> danach wieder übersetzen
        const head = document.querySelector("head");
        const obs = new MutationObserver(fix);
        if (head) obs.observe(head, { subtree: true, childList: true, characterData: true });
        return () => obs.disconnect();
    }, [locale]);
    return null;
}
