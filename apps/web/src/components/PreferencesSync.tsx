"use client";

import { useEffect, useRef } from "react";
import { useProfile } from "@/hooks/useProfile";
import { useI18n } from "@/lib/i18n";
import { getMuted, getVolume, onAudioSettingsChanged, setMuted, setVolume } from "@/lib/gameFx";

/**
 * Hält Sprache und Ton zwischen Gerät und Konto synchron:
 *  - nach dem Login werden die im Konto gespeicherten Werte übernommen (jedes Gerät gleich),
 *  - spätere Änderungen (Sprachschalter, Lautsprecher-Knopf, Taste M) landen wieder im Konto.
 * Für Gäste passiert nichts – dort bleibt alles wie bisher nur im Browser.
 */
export function PreferencesSync() {
    const { user, profile, loading, savePreferences } = useProfile();
    const { locale, setLocale } = useI18n();
    const appliedFor = useRef<string | null>(null);
    const prevLocale = useRef<string | null>(null);
    const saveTimer = useRef<number | null>(null);

    const uid = user?.id ?? null;
    const prefs = profile?.preferences;

    // 1) Einmal pro Login: Konto-Werte auf dieses Gerät übernehmen
    useEffect(() => {
        if (!uid || loading || !prefs || appliedFor.current === uid) return;
        appliedFor.current = uid;
        if (prefs.lang && prefs.lang !== locale) setLocale(prefs.lang);
        if (typeof prefs.muted === "boolean" && prefs.muted !== getMuted()) setMuted(prefs.muted);
        if (typeof prefs.volume === "number" && Math.abs(prefs.volume - getVolume()) > 0.001) setVolume(prefs.volume);
    }, [uid, loading, prefs, locale, setLocale]);

    useEffect(() => {
        if (!uid) appliedFor.current = null;
    }, [uid]);

    // 2) Sprache geändert -> im Konto merken
    useEffect(() => {
        const prev = prevLocale.current;
        prevLocale.current = locale;
        if (!uid || appliedFor.current !== uid || prev === null || prev === locale) return;
        if (prefs?.lang !== locale) void savePreferences({ lang: locale });
    }, [locale, uid, prefs?.lang, savePreferences]);

    // 3) Ton geändert -> im Konto merken (entprellt, der Lautstärkeregler feuert oft)
    useEffect(() => {
        if (!uid) return;
        return onAudioSettingsChanged(() => {
            if (appliedFor.current !== uid) return;
            if (saveTimer.current) window.clearTimeout(saveTimer.current);
            saveTimer.current = window.setTimeout(() => {
                const m = getMuted();
                const v = Math.round(getVolume() * 100) / 100;
                if (prefs?.muted === m && prefs?.volume === v) return;
                void savePreferences({ muted: m, volume: v });
            }, 1500);
        });
    }, [uid, prefs?.muted, prefs?.volume, savePreferences]);

    return null;
}
