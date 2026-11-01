/** Gemeinsame Maße, Zeiten und Typen des Roulettes (Walze, Wörter-Tafel, Wertungs-Show). Die Zeiten müssen zur Datenbank passen (Migration 128/129). */
export const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
export const REPEATS = 7; // Walze = 7x A–Z, der Zielbuchstabe liegt in der vorletzten Wiederholung
export const SPIN_MS = 5600;

// Wörter-Karte: feste Spalten, y in Zeilen (so bleibt jedes Wort an seinem Platz, auch wenn weitere dazukommen)
export const MAP_COL_W = 235; // so breit darf eine Spalte der Wörter-Karte mindestens sein (px) – daraus folgt die Spaltenzahl
export const BASE_ROWS = 7; // Zeilenhöhe steht im CSS (--rh), damit sie auf dem Handy kleiner sein kann

// Wertungs-Show: Wörter-Karte 7 s (13 s, wenn Menschen rote Wörter haben – Zeit für Einsprüche; steht in quiz_reveal.mapSecs), dann je Platz 2,2 s (Trommelwirbel 0,9 s + Treffer), Sieger +1,5 s – muss zur Datenbank passen (Migration 128)
export const MAP_S_DEFAULT = 7;
export const INTRO_S = 1;
export const PLACE_S = 2.2;
export const ROLL_S = 0.9;
export const showSeconds = (n: number) => INTRO_S + PLACE_S * n + 1.5;

export type CatInfo = { id: string; name: string };
export type ValidItem = { t: string; l: string };
export type ResultRow = { playerId: string; name: string; points: number; valid: ValidItem[]; bad: string[]; dup: string[] };
export type Word = { key: string; text: string; pid: string; kind: "plain" | "ok" | "bad" | "dup"; mine: boolean };
export type Appeal = { o: string; t: string; y: string[]; n: string[]; s: "open" | "accepted" | "rejected" };

