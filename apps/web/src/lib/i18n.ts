"use client";

/**
 * Kleines Übersetzungssystem (Deutsch = Quelle, Englisch = zweite Sprache).
 *
 *   const { t, locale, setLocale } = useI18n();
 *   t("home.tagline")                       // → "Die heiße Kartoffel mit Musik …"
 *   t("join.hint", { code: "AB12" })        // {code} wird ersetzt
 *
 * Zweiter, einfacherer Weg (seit 2026-10-12, für alle neuen Texte):
 *   const { tr } = useI18n();  tr(deutscherText, { n: 3 })  (z. B. Text „Noch {n} Sekunden“)
 * Der deutsche Text IST der Schlüssel; Englisch/Französisch stehen in i18nPhrasesEn.ts / i18nPhrasesFr.ts.
 * Außerhalb von Komponenten: trNow(text). Der Test i18nPhrases.test.ts meldet jeden tr()-Text ohne Übersetzung.
 *
 * Schlüssel-Weg (alt): Schlüssel in ALLE Wörterbücher (`de`, `en`, `fr`) eintragen. Fehlt ein englischer
 * Eintrag, fällt es auf Deutsch zurück. Die Sprache gilt sofort überall (kein Neuladen nötig) und
 * wird in localStorage gemerkt. Standard ist Deutsch – Englisch nur, wenn jemand es im Schalter wählt
 * (die App ist noch nicht vollständig übersetzt, und viele Deutsche nutzen einen englischen Browser).
 *
 * Stand: Startseite, Anmelde-Leiste, Solo, Beitreten, Einladen und Endbildschirm sind übersetzt;
 * das eigentliche Spielfeld ist noch deutsch.
 */

import { useCallback, useSyncExternalStore } from "react";
import { PHRASES_EN } from "./i18nPhrasesEn";
import { PHRASES_FR } from "./i18nPhrasesFr";

export type Locale = "de" | "en" | "fr";
export const LOCALES: Locale[] = ["de", "en", "fr"];

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

const fr: Partial<Record<TranslationKey, string>> = {
    "common.back": "← Retour",
    "common.loading": "Chargement…",
    "lang.switch": "Langue",

    "home.players": "👥 2–12 joueurs",
    "home.leaderboard": "🏆 Classement",
    "home.tagline": "La patate chaude en musique. Reconnais le son, passe-la, survis.",
    "home.solo": "🤖 Essayer en solo",
    "home.host": "🚀 Jouer entre amis",
    "home.join": "Rejoindre avec un code",
    "home.play": "🎮 Jouer",
    "home.free": "Sans téléchargement · Sans compte",
    "play.title": "Comment veux-tu jouer ?",
    "play.sub": "Seul contre des bots ou avec tes amis.",
    "play.solo.title": "Solo contre des bots",
    "play.solo.text": "C'est parti tout de suite – trois bots comme adversaires, ça démarre en quelques secondes.",
    "play.host.title": "Jouer entre amis",
    "play.host.text": "Crée un salon, partage le code, jouez ensemble.",
    "play.back": "← Retour",
    "home.step1.title": "Ouvrir un salon",
    "home.step1.text": "Une personne héberge, les autres rejoignent avec un code à 4 caractères.",
    "home.step2.title": "Reconnaître le son",
    "home.step2.text": "Un son passe. Celui qui a le Kumpir tape le titre et le passe.",
    "home.step3.title": "Ne pas se faire prendre",
    "home.step3.text": "La mèche raccourcit. Celui qui le tient quand ça explose est éliminé.",
    "auth.login": "Connexion",
    "auth.register": "Inscription",
    "auth.account": "Mon compte",

    "solo.title": "Solo contre des bots",
    "solo.creating": "Création du salon …",
    "solo.bots": "Les bots se préparent …",
    "solo.go": "C'est parti – choix du thème …",
    "solo.info": "Tu joues contre trois bots. Un son passe – tape le titre avant que la mèche soit consumée.",
    "solo.failed": "Ça n'a pas marché :",
    "solo.retry": "Réessayer",
    "solo.home": "Retour à l'accueil",

    "join.title": "Rejoindre un salon",
    "join.sub": "Entre vite – sans compte.",
    "join.codeLabel": "1) Code du salon",
    "join.codeHelp": "4 caractères (A–Z, 0–9).",
    "join.nameLabel": "2) Ton nom",
    "join.nameHelp": "Lettres uniquement, 12 caractères max.",
    "join.modalTitle": "Entre ton nom",
    "join.modalSub": "Juste un instant – et tu es dedans.",
    "join.yourName": "Ton nom",
    "join.btn": "🚀 Rejoindre",
    "join.joining": "Connexion…",
    "join.running": "Une partie est en cours. Tu peux regarder et jouer après la partie.",
    "join.spectate": "👀 Regarder",
    "join.notFound": "Salon introuvable.",
    "join.badCode": "Entre un code valide à 4 caractères.",

    "invite.share": "📲 Partager l'invitation",
    "invite.qr": "📷 QR code",
    "invite.qrHide": "Masquer le QR",
    "invite.qrHint": "Scanne avec l'appareil photo du téléphone pour rejoindre directement",
    "invite.text": "Viens dans mon salon Kumpir ! Code : {code}",

    "game.spectating": "👀 Tu regardes",
    "fin.match": "Partie terminée · {n} manches",
    "fin.round": "Manche terminée",
    "fin.winsMatch": "remporte la partie",
    "fin.winsRound": "remporte la manche",
    "fin.me": "Ton résultat : place {place} · {score} points",
    "fin.final": "Classement final",
    "fin.player": "Joueur",
    "fin.points": "Points",
    "fin.share": "📤 Partager le résultat",
    "fin.shareBusy": "Création de l'image…",
    "fin.saved": "✅ Image enregistrée",
    "fin.shareFail": "⚠️ Impossible de créer l'image",
    "fin.again": "🔁 Rejouer",
    "fin.lobby": "Retour au salon",
    "fin.saved2": "✓ Tes points et victoires sont enregistrés sur ton compte.",
    "fin.keep": "💾 Garder tes points, victoires et ton rang de saison ?",
    "fin.create": "Créer un compte gratuit",
    "fin.tip": "Astuce : la touche R relance directement une manche",

    "pwa.install": "📲 Installe Kumpir comme appli – démarre plus vite, sans barre de navigateur.",
    "pwa.ios": "📲 Enregistrer comme appli : touche Partager en bas, puis « Sur l'écran d'accueil ».",
    "pwa.btn": "Installer",
    "pwa.dismiss": "Fermer",

    "fin.unranked": "🤖 Partie d'entraînement (un seul humain) : ne compte pas pour le classement.",
    "fin.unrankedAccount": "🤖 Partie d'entraînement (un seul humain) : ne compte pas pour le classement, les victoires ni les succès – mais apparaît dans ton historique.",
    "fin.spectator": "👀 Tu as regardé. Dès que l'hôte revient au salon, tu peux jouer.",
    "spec.kicker": "SPECTATEUR",
    "spec.openTitle": "Tu peux jouer maintenant",
    "spec.openSub": "La partie est finie – rejoins le salon pour la prochaine.",
    "spec.lockedTitle": "Salon verrouillé 🔒",
    "spec.lockedSub": "L'hôte a verrouillé le salon. Attends qu'il soit rouvert.",
    "spec.joinBtn": "🚀 Jouer",
    "join.locked": "L'hôte a verrouillé ce salon (🔒). Réessaie dans un instant.",

    "card.tagline": "Kumpir · La patate chaude en musique",
    "card.me": "Moi : place {place} · {score} points",
    "card.pts": "pts",
    "card.cta": "Joue aussi – gratuit dans le navigateur",
    "card.shareText": "{winner} gagne à Kumpir. Joue aussi : {url}",
    "card.shareTextMe": "{winner} gagne à Kumpir – moi : place {place}, {score} points. Joue aussi : {url}",
};

const dictionaries: Record<Locale, Partial<Record<TranslationKey, string>>> = { de, en, fr };

const STORAGE_KEY = "kumpir_locale";
const EVENT = "kumpir:locale";

function detectLocale(): Locale {
    try {
        const stored = window.localStorage.getItem(STORAGE_KEY);
        if (stored === "de" || stored === "en" || stored === "fr") return stored;
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
    const tr = useCallback((text: string, vars?: Record<string, string | number>) => trIn(locale, text, vars), [locale]);

    return { locale, setLocale, t, tr };
}

type Vars = Record<string, string | number>;
const PHRASES: Record<Exclude<Locale, "de">, Record<string, string>> = { en: PHRASES_EN, fr: PHRASES_FR };

function fill(s: string, vars?: Vars): string {
    if (vars) for (const [k, v] of Object.entries(vars)) s = s.split(`{${k}}`).join(String(v));
    return s;
}

/** Deutscher Text -> Text in der Sprache `locale` (fehlt die Übersetzung, bleibt es Deutsch). */
export function trIn(locale: Locale, text: string, vars?: Vars): string {
    return fill(locale === "de" ? text : (PHRASES[locale][text] ?? text), vars);
}

export { tk } from "./i18nMark";

/** Wie tr(), aber ohne Hook (für Hilfsfunktionen, Toasts außerhalb von Komponenten). */
export function trNow(text: string, vars?: Vars): string {
    return trIn(typeof window === "undefined" ? "de" : detectLocale(), text, vars);
}

/** Locale-Code für Datums-/Zahlenformate (toLocaleDateString usw.) passend zur gewählten Sprache. */
export function dateLocale(locale?: Locale): string {
    const l = locale ?? (typeof window === "undefined" ? "de" : detectLocale());
    return l === "en" ? "en-GB" : l === "fr" ? "fr-FR" : "de-DE";
}
