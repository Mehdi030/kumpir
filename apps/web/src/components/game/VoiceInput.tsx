"use client";

import { useCallback, useEffect, useRef, useState } from "react";

// Kein offizielles TS-Lib-Target für die Web Speech API -- minimal getypt,
// nur was wir wirklich brauchen.
type SpeechRecognitionResultLike = { transcript: string };
type SpeechRecognitionEventLike = {
    results: ArrayLike<ArrayLike<SpeechRecognitionResultLike>>;
};
type SpeechRecognitionLike = {
    lang: string;
    interimResults: boolean;
    maxAlternatives: number;
    continuous: boolean;
    onresult: ((e: SpeechRecognitionEventLike) => void) | null;
    onerror: ((e: { error: string }) => void) | null;
    onend: (() => void) | null;
    start: () => void;
    stop: () => void;
};

type SpeechWindow = Window & {
    webkitSpeechRecognition?: new () => SpeechRecognitionLike;
    SpeechRecognition?: new () => SpeechRecognitionLike;
};

function getRecognitionCtor(): (new () => SpeechRecognitionLike) | null {
    if (typeof window === "undefined") return null;
    const w = window as SpeechWindow;
    return w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null;
}

/**
 * Mikrofon-Knopf für Spracheingabe (Web Speech API, Chromium/Edge/Safari 17+).
 * Gedacht für den "Deutschrap-Songs"-Kategorie: Songtitel laut aussprechen
 * statt zu tippen. Funktioniert für jede Kategorie, nicht nur Songs.
 *
 * Kein Server-Roundtrip -- die Erkennung läuft komplett im Browser
 * (bzw. bei Chrome über Googles Spracherkennungsdienst, aber ohne dass
 * wir dafür Code schreiben müssen).
 */
export function VoiceInput({
    onResult,
    disabled,
    variant = "icon",
}: {
    onResult: (text: string) => void;
    disabled?: boolean;
    /** "icon" = kleiner Mikro-Knopf neben dem Textfeld (Standard-Antwortmodus).
     *  "primary" = großer, beschrifteter Haupt-Button (Lobby-Antwortmodus "Mündlich"). */
    variant?: "icon" | "primary";
}) {
    // Startet mit `false` (identisch zum SSR-Ergebnis, `window` existiert dort
    // nicht) und korrigiert sich nach dem Mount -- eine Lazy-Init-Funktion wie
    // `useState(() => getRecognitionCtor() !== null)` würde beim Hydrieren
    // einen anderen Wert liefern als beim Server-Render und eine
    // Hydration-Mismatch-Warnung auslösen.
    const [supported, setSupported] = useState(false);
    const [listening, setListening] = useState(false);
    const recognitionRef = useRef<SpeechRecognitionLike | null>(null);

    useEffect(() => {
        // Absichtlicher Ausnahmefall: SSR kennt `window` nicht, der einzige
        // korrekte Zeitpunkt für diese Browser-Feature-Erkennung ist nach dem
        // Mount. Ein Lazy-Init in useState() würde beim Hydrieren einen
        // anderen Wert als beim Server-Render liefern (Mismatch-Warnung).
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setSupported(getRecognitionCtor() !== null);
        return () => {
            recognitionRef.current?.stop();
        };
    }, []);

    const toggle = useCallback(() => {
        if (disabled) return;

        if (listening) {
            recognitionRef.current?.stop();
            setListening(false);
            return;
        }

        const Ctor = getRecognitionCtor();
        if (!Ctor) {
            setSupported(false);
            return;
        }

        const rec = new Ctor();
        rec.lang = "de-DE";
        rec.interimResults = false;
        rec.maxAlternatives = 1;
        rec.continuous = false;

        rec.onresult = (e) => {
            const text = e.results?.[0]?.[0]?.transcript ?? "";
            if (text) onResult(text);
        };
        rec.onerror = () => setListening(false);
        rec.onend = () => setListening(false);

        recognitionRef.current = rec;
        setListening(true);
        rec.start();
    }, [listening, disabled, onResult]);

    if (!supported) {
        // Im "Mündlich"-Modus still zu verschwinden würde den Halter ohne jede
        // Eingabemöglichkeit dastehen lassen -- das Textfeld bleibt in beiden
        // Varianten immer zusätzlich vorhanden, also reicht ein Hinweis.
        if (variant === "primary") {
            return (
                <div className="fieldHelp" style={{ opacity: 0.85 }}>
                    🎤 Spracheingabe wird von diesem Browser nicht unterstützt — bitte tippen.
                </div>
            );
        }
        return null;
    }

    if (variant === "primary") {
        return (
            <button
                type="button"
                onClick={toggle}
                disabled={disabled}
                aria-label={listening ? "Spracheingabe läuft, zum Stoppen klicken" : "Antwort per Sprache eingeben"}
                title={listening ? "Aufnahme läuft… (Klick zum Stoppen)" : "Sprich deine Antwort"}
                className={`btn btnPrimary btnXL voiceInputPrimary${listening ? " voiceInputBtnActive" : ""}`}
            >
                {listening ? "🔴 Höre zu…" : "🎤 Antwort sprechen"}
            </button>
        );
    }

    return (
        <button
            type="button"
            onClick={toggle}
            disabled={disabled}
            aria-label={listening ? "Spracheingabe läuft, zum Stoppen klicken" : "Antwort per Sprache eingeben"}
            title={listening ? "Aufnahme läuft… (Klick zum Stoppen)" : "Sprich deine Antwort"}
            className={`voiceInputBtn${listening ? " voiceInputBtnActive" : ""}`}
        >
            {listening ? "🔴" : "🎤"}
        </button>
    );
}
