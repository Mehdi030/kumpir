"use client";

/**
 * Kleines Übersetzungssystem (Deutsch = Quelle, Englisch = zweite Sprache).
 *
 *   const { t, locale, setLocale } = useI18n();
 *   t("home.tagline")                       // → "Die heiße Kartoffel mit Musik …"
 *   t("join.hint", { code: "AB12" })        // {code} wird ersetzt
 *
 * Neuer Text: Schlüssel in BEIDE Wörterbücher (`de` und `en`) eintragen. Fehlt ein englischer
 * Eintrag, fällt es auf Deutsch zurück. Die Sprache gilt sofort überall (kein Neuladen nötig),
 * wird in localStorage gemerkt und beim ersten Besuch aus der Browsersprache abgeleitet.
 *
 * Stand: Startseite, Anmelde-Leiste, Solo, Beitreten, Einladen und Endbildschirm sind übersetzt;
 * das eigentliche Spielfeld ist noch deutsch.
 */

import { useCallback, useSyncExternalStore } from "react";

export type Locale = "de" | "en";

const de = {
    "common.back": "← Zurück",
    "common.loading": "Lädt…",
    "lang.switch": "Sprache",

    // Startseite
    "home.players": "👥 2–12 Spieler",
    "home.leaderboard": "🏆 Bestenliste",
    "home.tagline": "Die heiße Kartoffel mit Musik. Song erkennen, weitergeben, überleben.",
    "home.solo": "🤖 Solo ausprobieren",
    "home.host": "🚀 Mit Freunden spielen",
    "home.join": "Mit Code beitreten",
    "home.free": "Kein Download · Kein Konto nötig · „Solo ausprobieren“ startet in Sekunden",
    "home.step1.title": "Lobby öffnen",
    "home.step1.text": "Einer hostet, alle anderen kommen mit einem 4-stelligen Code dazu.",
    "home.step2.title": "Song erkennen",
    "home.step2.text": "Ein Song läuft. Wer die Kumpir hat, tippt den Titel und gibt sie weiter.",
    "home.step3.title": "Nicht erwischen lassen",
    "home.step3.text": "Die Zündschnur wird kürzer. Wer sie beim Knall hält, fliegt raus.",
    "auth.login": "Anmelden",
    "auth.register": "Registrieren",
    "auth.account": "Mein Konto",
    "stats.title": "📊 Statistik",
    "stats.guest": "Mit Account merkt sich Kumpir Siege, Pässe und Achievements.",
    "stats.login": "🔓 Einloggen",
    "stats.board": "🏆 Bestenliste ansehen",

    // Solo
    "solo.title": "Solo gegen Bots",
    "solo.creating": "Lobby wird erstellt …",
    "solo.bots": "Bots machen sich bereit …",
    "solo.go": "Los geht's – Themenwahl …",
    "solo.info": "Du spielst gegen drei Bots. Ein Song läuft – tippe den Titel, bevor die Zündschnur durch ist.",
    "solo.failed": "Das hat nicht geklappt:",
    "solo.retry": "Nochmal versuchen",
    "solo.home": "Zur Startseite",

    // Beitreten
    "join.title": "Lobby beitreten",
    "join.sub": "Schnell rein – ohne Account.",
    "join.codeLabel": "1) Lobby-Code",
    "join.codeHelp": "4 Zeichen (A–Z, 0–9).",
    "join.nameLabel": "2) Dein Name",
    "join.nameHelp": "Nur Buchstaben, max. 12 Zeichen.",
    "join.modalTitle": "Name eingeben",
    "join.modalSub": "Nur kurz – dann bist du drin.",
    "join.yourName": "Dein Name",
    "join.btn": "🚀 Beitreten",
    "join.joining": "Trete bei…",
    "join.running": "Das Spiel läuft schon – beitreten geht erst in der nächsten Runde. Du kannst aber zuschauen.",
    "join.spectate": "👀 Zuschauen",
    "join.notFound": "Lobby nicht gefunden.",
    "join.badCode": "Bitte einen gültigen 4-stelligen Code eingeben.",

    // Einladen
    "invite.share": "📲 Einladung teilen",
    "invite.copy": "🔗 Link kopieren",
    "invite.qr": "📷 QR-Code",
    "invite.qrHide": "QR ausblenden",
    "invite.copied": "✅ Link kopiert",
    "invite.copyFail": "⚠️ Kopieren nicht möglich",
    "invite.qrHint": "Mit der Handy-Kamera scannen und direkt beitreten",
    "invite.text": "Komm in meine Kumpir-Lobby! Code: {code}",

    // Spiel / Endbildschirm
    "game.spectating": "👀 Du schaust zu",
    "fin.match": "Match beendet · {n} Runden",
    "fin.round": "Runde beendet",
    "fin.winsMatch": "gewinnt das Match",
    "fin.winsRound": "gewinnt die Runde",
    "fin.me": "Dein Ergebnis: Platz {place} · {score} Punkte",
    "fin.final": "Endstand",
    "fin.player": "Spieler",
    "fin.points": "Punkte",
    "fin.share": "📤 Ergebnis teilen",
    "fin.shareBusy": "Erstelle Bild…",
    "fin.saved": "✅ Bild gespeichert",
    "fin.shareFail": "⚠️ Bild konnte nicht erstellt werden",
    "fin.again": "🔁 Nochmal spielen",
    "fin.lobby": "Zur Lobby",
    "fin.saved2": "✓ Deine Punkte und Siege sind auf deinem Konto gespeichert.",
    "fin.keep": "💾 Punkte, Siege und Saison-Rang behalten?",
    "fin.create": "Gratis-Konto erstellen",
    "fin.tip": "Tipp: Taste R startet direkt eine neue Runde",
} as const;

export type TranslationKey = keyof typeof de;

const en: Partial<Record<TranslationKey, string>> = {
    "common.back": "← Back",
    "common.loading": "Loading…",
    "lang.switch": "Language",

    "home.players": "👥 2–12 players",
    "home.leaderboard": "🏆 Leaderboard",
    "home.tagline": "Hot potato with music. Guess the song, pass it on, survive.",
    "home.solo": "🤖 Try it solo",
    "home.host": "🚀 Play with friends",
    "home.join": "Join with code",
    "home.free": "No download · No account needed · “Try it solo” starts in seconds",
    "home.step1.title": "Open a lobby",
    "home.step1.text": "One person hosts, everyone else joins with a 4-character code.",
    "home.step2.title": "Name that song",
    "home.step2.text": "A song plays. Whoever holds the potato types the title and passes it on.",
    "home.step3.title": "Don't get caught",
    "home.step3.text": "The fuse keeps getting shorter. Hold the potato when it blows and you're out.",
    "auth.login": "Log in",
    "auth.register": "Sign up",
    "auth.account": "My account",
    "stats.title": "📊 Stats",
    "stats.guest": "With an account, Kumpir remembers your wins, passes and achievements.",
    "stats.login": "🔓 Log in",
    "stats.board": "🏆 View leaderboard",

    "solo.title": "Solo vs. bots",
    "solo.creating": "Creating lobby …",
    "solo.bots": "Bots are getting ready …",
    "solo.go": "Here we go – picking a topic …",
    "solo.info": "You play against three bots. A song plays – type the title before the fuse burns out.",
    "solo.failed": "That didn't work:",
    "solo.retry": "Try again",
    "solo.home": "Back to home",

    "join.title": "Join a lobby",
    "join.sub": "Jump right in – no account needed.",
    "join.codeLabel": "1) Lobby code",
    "join.codeHelp": "4 characters (A–Z, 0–9).",
    "join.nameLabel": "2) Your name",
    "join.nameHelp": "Letters only, max. 12 characters.",
    "join.modalTitle": "Enter your name",
    "join.modalSub": "Just a moment – then you're in.",
    "join.yourName": "Your name",
    "join.btn": "🚀 Join",
    "join.joining": "Joining…",
    "join.running": "The game is already running – you can join in the next round. You can watch in the meantime.",
    "join.spectate": "👀 Watch",
    "join.notFound": "Lobby not found.",
    "join.badCode": "Please enter a valid 4-character code.",

    "invite.share": "📲 Share invite",
    "invite.copy": "🔗 Copy link",
    "invite.qr": "📷 QR code",
    "invite.qrHide": "Hide QR",
    "invite.copied": "✅ Link copied",
    "invite.copyFail": "⚠️ Couldn't copy",
    "invite.qrHint": "Scan with your phone camera to join right away",
    "invite.text": "Join my Kumpir lobby! Code: {code}",

    "game.spectating": "👀 You're watching",
    "fin.match": "Match over · {n} rounds",
    "fin.round": "Round over",
    "fin.winsMatch": "wins the match",
    "fin.winsRound": "wins the round",
    "fin.me": "Your result: place {place} · {score} points",
    "fin.final": "Final standings",
    "fin.player": "Player",
    "fin.points": "Points",
    "fin.share": "📤 Share result",
    "fin.shareBusy": "Creating image…",
    "fin.saved": "✅ Image saved",
    "fin.shareFail": "⚠️ Couldn't create the image",
    "fin.again": "🔁 Play again",
    "fin.lobby": "Back to lobby",
    "fin.saved2": "✓ Your points and wins are saved to your account.",
    "fin.keep": "💾 Keep your points, wins and season rank?",
    "fin.create": "Create free account",
    "fin.tip": "Tip: press R to start a new round right away",
};

const dictionaries: Record<Locale, Partial<Record<TranslationKey, string>>> = { de, en };

const STORAGE_KEY = "kumpir_locale";
const EVENT = "kumpir:locale";

function detectLocale(): Locale {
    try {
        const stored = window.localStorage.getItem(STORAGE_KEY);
        if (stored === "de" || stored === "en") return stored;
    } catch {
        // ignore
    }
    return (navigator.language || "de").toLowerCase().startsWith("en") ? "en" : "de";
}

function subscribe(cb: () => void) {
    window.addEventListener(EVENT, cb);
    window.addEventListener("storage", cb);
    return () => {
        window.removeEventListener(EVENT, cb);
        window.removeEventListener("storage", cb);
    };
}

export function translate(locale: Locale, key: TranslationKey, vars?: Record<string, string | number>): string {
    let s = dictionaries[locale][key] ?? de[key] ?? key;
    if (vars) for (const [k, v] of Object.entries(vars)) s = s.split(`{${k}}`).join(String(v));
    return s;
}

export function useI18n() {
    // Server + erstes Hydration-Rendern: Deutsch (kein Mismatch); danach springt es auf die gespeicherte Sprache.
    const locale = useSyncExternalStore<Locale>(subscribe, detectLocale, () => "de");

    const setLocale = useCallback((next: Locale) => {
        try {
            window.localStorage.setItem(STORAGE_KEY, next);
        } catch {
            // ignore
        }
        document.documentElement.lang = next;
        window.dispatchEvent(new Event(EVENT));
    }, []);

    const t = useCallback((key: TranslationKey, vars?: Record<string, string | number>) => translate(locale, key, vars), [locale]);

    return { locale, setLocale, t };
}
