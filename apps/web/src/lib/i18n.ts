"use client";

/**
 * Minimal i18n scaffold. German is the source-of-truth; English added incrementally.
 *
 * Usage:
 *   const { t, locale, setLocale } = useI18n();
 *   t("landing.hostBtn") // → "Spiel hosten"
 *
 * To add a new key: add it to BOTH `de` and `en` below. Missing keys fall back to the
 * key string itself, so it's obvious in the UI when something needs translating.
 *
 * NOTE: this is a scaffold — most of the app is still hardcoded German. Migrate
 * top-level UI strings progressively over future PRs.
 */

import { useCallback, useState } from "react";

export type Locale = "de" | "en";

const dictionaries: Record<Locale, Record<string, string>> = {
    de: {
        "landing.tagline": "Heiße Kartoffel. Schnell. Laut. Mit Freunden.",
        "landing.hostBtn": "🚀 Spiel hosten",
        "landing.joinBtn": "🎟️ Mit Code beitreten",
        "common.back": "← Zurück",
        "common.loading": "Lädt…",
        "common.cancel": "Abbrechen",
        "common.confirm": "Bestätigen",
        "common.close": "Schließen",
        "lobby.code": "Lobby-Code",
        "lobby.share": "Link teilen",
        "lobby.copy": "Code kopieren",
        "lobby.start": "🚀 Spiel starten",
        "lobby.ready": "✨ Bereit",
        "lobby.unready": "⛔ Nicht bereit",
        "lobby.locked": "🔒 Lobby gesperrt",
        "game.yourTurn": "✅ Du bist dran",
        "game.passHint": "🥔 Weitergeben (Space)",
        "game.eliminated": "💀 Du bist raus",
        "game.spectating": "Du schaust zu.",
        "game.gameOver": "Spiel beendet",
        "game.rematch": "🔁 Rematch (R)",
        "game.backToLobby": "Zurück zur Lobby",
        "audio.muteOn": "Sound einschalten",
        "audio.muteOff": "Sound ausschalten",
    },
    en: {
        "landing.tagline": "Hot potato. Fast. Loud. With friends.",
        "landing.hostBtn": "🚀 Host a game",
        "landing.joinBtn": "🎟️ Join with code",
        "common.back": "← Back",
        "common.loading": "Loading…",
        "common.cancel": "Cancel",
        "common.confirm": "Confirm",
        "common.close": "Close",
        "lobby.code": "Lobby code",
        "lobby.share": "Share link",
        "lobby.copy": "Copy code",
        "lobby.start": "🚀 Start game",
        "lobby.ready": "✨ Ready",
        "lobby.unready": "⛔ Not ready",
        "lobby.locked": "🔒 Lobby locked",
        "game.yourTurn": "✅ Your turn",
        "game.passHint": "🥔 Pass (Space)",
        "game.eliminated": "💀 You're out",
        "game.spectating": "Spectating.",
        "game.gameOver": "Game over",
        "game.rematch": "🔁 Rematch (R)",
        "game.backToLobby": "Back to lobby",
        "audio.muteOn": "Unmute",
        "audio.muteOff": "Mute",
    },
};

export type TranslationKey = keyof (typeof dictionaries)["de"];

const STORAGE_KEY = "kumpir_locale";

function detectLocale(): Locale {
    if (typeof window === "undefined") return "de";
    try {
        const stored = window.localStorage.getItem(STORAGE_KEY);
        if (stored === "de" || stored === "en") return stored;
    } catch {
        // ignore
    }
    const browser = (navigator.language || "de").toLowerCase();
    if (browser.startsWith("en")) return "en";
    return "de";
}

export function translate(locale: Locale, key: TranslationKey): string {
    const dict = dictionaries[locale];
    return dict[key] ?? dictionaries.de[key] ?? key;
}

export function useI18n() {
    // Lazy init: read locale once on mount instead of in an effect.
    const [locale, setLocaleState] = useState<Locale>(() => detectLocale());

    const setLocale = useCallback((next: Locale) => {
        setLocaleState(next);
        try {
            window.localStorage.setItem(STORAGE_KEY, next);
        } catch {
            // ignore
        }
    }, []);

    const t = useCallback((key: TranslationKey) => translate(locale, key), [locale]);

    return { locale, setLocale, t };
}
