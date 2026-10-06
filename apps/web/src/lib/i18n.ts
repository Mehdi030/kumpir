"use client";

/**
 * Kleines Übersetzungssystem (Deutsch = Quelle, Englisch = zweite Sprache).
 *
 *   const { t, locale, setLocale } = useI18n();
 *   t("home.tagline")                       // → "Die heiße Kartoffel mit Musik …"
 *   t("join.hint", { code: "AB12" })        // {code} wird ersetzt
 *
 * Neuer Text: Schlüssel in BEIDE Wörterbücher (`de` und `en`) eintragen. Fehlt ein englischer
 * Eintrag, fällt es auf Deutsch zurück. Die Sprache gilt sofort überall (kein Neuladen nötig) und
 * wird in localStorage gemerkt. Standard ist Deutsch – Englisch nur, wenn jemand es im Schalter wählt
 * (die App ist noch nicht vollständig übersetzt, und viele Deutsche nutzen einen englischen Browser).
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
    "home.play": "🎮 Jetzt spielen",
    "home.free": "Kein Download · Kein Konto nötig",
    "play.title": "Wie willst du spielen?",
    "play.sub": "Allein gegen Bots oder mit deinen Freunden.",
    "play.solo.title": "Solo gegen Bots",
    "play.solo.text": "Sofort loslegen – drei Bots als Gegner, startet in Sekunden.",
    "play.host.title": "Mit Freunden spielen",
    "play.host.text": "Lobby erstellen, Code teilen, gemeinsam spielen.",
    "play.back": "← Zurück",
    "home.step1.title": "Lobby öffnen",
    "home.step1.text": "Einer hostet, alle anderen kommen mit einem 4-stelligen Code dazu.",
    "home.step2.title": "Song erkennen",
    "home.step2.text": "Ein Song läuft. Wer die Kumpir hat, tippt den Titel und gibt sie weiter.",
    "home.step3.title": "Nicht erwischen lassen",
    "home.step3.text": "Die Zündschnur wird kürzer. Wer sie beim Knall hält, fliegt raus.",
    "auth.login": "Anmelden",
    "auth.register": "Registrieren",
    "auth.account": "Mein Konto",

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
    "join.running": "Hier läuft gerade ein Match. Du kannst zuschauen und nach dem Match mitspielen.",
    "join.spectate": "👀 Zuschauen",
    "join.notFound": "Lobby nicht gefunden.",
    "join.badCode": "Bitte einen gültigen 4-stelligen Code eingeben.",

    // Einladen
    "invite.share": "📲 Einladung teilen",
    "invite.qr": "📷 QR-Code",
    "invite.qrHide": "QR ausblenden",
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

    "pwa.install": "📲 Kumpir als App aufs Handy – startet schneller, ohne Browserleiste.",
    "pwa.ios": "📲 Als App speichern: unten auf Teilen tippen, dann „Zum Home-Bildschirm“.",
    "pwa.btn": "Installieren",
    "pwa.dismiss": "Hinweis schließen",

    "fin.unranked": "🤖 Übungsspiel (nur ein Mensch): zählt nicht für die Bestenliste.",
    "fin.unrankedAccount": "🤖 Übungsspiel (nur ein Mensch): zählt nicht für Bestenliste, Siege und Achievements – steht aber in deinem Verlauf.",
    "fin.spectator": "👀 Du hast zugeschaut. Sobald der Host zurück zur Lobby geht, kannst du mitspielen.",
    "spec.kicker": "ZUSCHAUEN",
    "spec.openTitle": "Jetzt kannst du mitspielen",
    "spec.openSub": "Das Match ist vorbei – tritt der Lobby für das nächste Match bei.",
    "spec.lockedTitle": "Lobby gesperrt 🔒",
    "spec.lockedSub": "Der Host hat die Lobby gesperrt. Warte, bis sie wieder offen ist.",
    "spec.joinBtn": "🚀 Mitspielen",
    "join.locked": "Der Host hat diese Lobby gerade gesperrt (🔒). Versuch es gleich nochmal.",

    // Ergebnis-Bild
    "card.tagline": "Kumpir · Die heiße Kartoffel mit Musik",
    "card.me": "Ich: Platz {place} · {score} Punkte",
    "card.pts": "Pkt",
    "card.cta": "Spiel mit – kostenlos im Browser",
    "card.shareText": "{winner} gewinnt bei Kumpir. Spiel mit: {url}",
    "card.shareTextMe": "{winner} gewinnt bei Kumpir – ich: Platz {place}, {score} Punkte. Spiel mit: {url}",
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
    "home.play": "🎮 Play now",
    "home.free": "No download · No account needed",
    "play.title": "How do you want to play?",
    "play.sub": "Alone against bots or with your friends.",
    "play.solo.title": "Solo vs. bots",
    "play.solo.text": "Jump right in – three bots as opponents, starts in seconds.",
    "play.host.title": "Play with friends",
    "play.host.text": "Create a lobby, share the code, play together.",
    "play.back": "← Back",
    "home.step1.title": "Open a lobby",
    "home.step1.text": "One person hosts, everyone else joins with a 4-character code.",
    "home.step2.title": "Name that song",
    "home.step2.text": "A song plays. Whoever holds the potato types the title and passes it on.",
    "home.step3.title": "Don't get caught",
    "home.step3.text": "The fuse keeps getting shorter. Hold the potato when it blows and you're out.",
    "auth.login": "Log in",
    "auth.register": "Sign up",
    "auth.account": "My account",

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
    "join.running": "A match is in progress. You can watch and join once it's over.",
    "join.spectate": "👀 Watch",
    "join.notFound": "Lobby not found.",
    "join.badCode": "Please enter a valid 4-character code.",

    "invite.share": "📲 Share invite",
    "invite.qr": "📷 QR code",
    "invite.qrHide": "Hide QR",
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

    "pwa.install": "📲 Add Kumpir to your phone as an app – starts faster, no browser bar.",
    "pwa.ios": "📲 Save as app: tap Share at the bottom, then “Add to Home Screen”.",
    "pwa.btn": "Install",
    "pwa.dismiss": "Dismiss",

    "fin.unranked": "🤖 Practice game (only one human): doesn't count towards the leaderboard.",
    "fin.unrankedAccount": "🤖 Practice game (only one human): doesn't count towards leaderboard, wins or achievements – but it's in your history.",
    "fin.spectator": "👀 You were watching. Once the host returns to the lobby, you can join.",
    "spec.kicker": "WATCHING",
    "spec.openTitle": "You can join now",
    "spec.openSub": "The match is over – join the lobby for the next match.",
    "spec.lockedTitle": "Lobby locked 🔒",
    "spec.lockedSub": "The host has locked the lobby. Wait until it opens again.",
    "spec.joinBtn": "🚀 Join",
    "join.locked": "The host has locked this lobby (🔒). Try again in a moment.",

    "card.tagline": "Kumpir · Hot potato with music",
    "card.me": "Me: place {place} · {score} points",
    "card.pts": "pts",
    "card.cta": "Play along – free in your browser",
    "card.shareText": "{winner} wins at Kumpir. Play along: {url}",
    "card.shareTextMe": "{winner} wins at Kumpir – me: place {place}, {score} points. Play along: {url}",
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
    return "de";
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
