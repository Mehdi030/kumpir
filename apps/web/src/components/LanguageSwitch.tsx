"use client";

import { useI18n, type Locale } from "@/lib/i18n";

/** Kleiner DE | EN-Schalter (das lang-Attribut setzt LocaleSync im Layout). */
export function LanguageSwitch() {
    const { locale, setLocale, t } = useI18n();

    const opt = (l: Locale, label: string) => (
        <button type="button" className={`langOpt${locale === l ? " langOptOn" : ""}`} onClick={() => setLocale(l)} aria-pressed={locale === l} lang={l}>
            {label}
        </button>
    );

    return (
        <div className="langSwitch" role="group" aria-label={t("lang.switch")}>
            {opt("de", "DE")}
            {opt("en", "EN")}
            <style>{`
        .langSwitch{ display:inline-flex; border-radius:999px; border:1px solid rgba(255,255,255,.28); overflow:hidden; background:rgba(255,255,255,.08); }
        .langOpt{ border:0; background:transparent; color:#fff; font-weight:800; font-size:12px; padding:6px 10px; cursor:pointer; opacity:.75; }
        .langOpt:hover{ opacity:1; }
        .langOptOn{ background:rgba(255,255,255,.9); color:#2b0f04; opacity:1; }
      `}</style>
        </div>
    );
}
