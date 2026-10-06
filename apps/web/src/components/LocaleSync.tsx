"use client";

import { useEffect } from "react";
import { useI18n } from "@/lib/i18n";

/** Setzt das lang-Attribut der Seite passend zur gewählten Sprache (Screenreader, Browser-Übersetzer). */
export function LocaleSync() {
    const { locale } = useI18n();
    useEffect(() => {
        document.documentElement.lang = locale;
    }, [locale]);
    return null;
}
