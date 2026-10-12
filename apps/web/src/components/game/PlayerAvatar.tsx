"use client";

import { useMemo } from "react";
import { createAvatar } from "@dicebear/core";
import * as avataaars from "@dicebear/avataaars";

/**
 * Gezeichneter Mensch (Kopf + Schultern) für Tisch, Lobby, Ergebnisse und Freunde.
 * Stil "Avataaars" von Pablo Stanley (frei für private und kommerzielle Nutzung), erzeugt im Browser
 * mit DiceBear – kein externer Dienst.
 *
 * Aussehen: eigene Wahl aus dem Profil (avatar_config, Migration 102) oder – ohne Wahl – aus dem Namen
 * abgeleitet (gleicher Name = immer dieselbe Person).
 * Stimmung:  normal = freundlich · panic = hält gerade die Kumpir · out = ausgeschieden
 */
export type AvatarMood = "normal" | "panic" | "out";

export type AvatarConfig = Partial<{
    top: string;
    hairColor: string;
    skinColor: string;
    clothing: string;
    clothesColor: string;
    accessories: string;
    facialHair: string;
}>;

/** Auswahl im Profil (Werte müssen zu public._avatar_allowed() in Migration 102 passen). */
export const AVATAR_OPTIONS: { key: keyof AvatarConfig; label: string; values: { v: string; label: string; color?: string }[] }[] = [
    {
        key: "skinColor",
        label: "Hautfarbe",
        values: [
            { v: "ffdbb4", label: "Hell", color: "#ffdbb4" },
            { v: "edb98a", label: "Hell-mittel", color: "#edb98a" },
            { v: "d08b5b", label: "Mittel", color: "#d08b5b" },
            { v: "ae5d29", label: "Dunkel-mittel", color: "#ae5d29" },
            { v: "614335", label: "Dunkel", color: "#614335" },
        ],
    },
    {
        key: "top",
        label: "Frisur",
        values: [
            { v: "shortFlat", label: "Kurz glatt" },
            { v: "shortRound", label: "Kurz rund" },
            { v: "shortWaved", label: "Kurz wellig" },
            { v: "shortCurly", label: "Kurz lockig" },
            { v: "theCaesar", label: "Caesar" },
            { v: "theCaesarAndSidePart", label: "Seitenscheitel" },
            { v: "sides", label: "Seiten" },
            { v: "shavedSides", label: "Undercut" },
            { v: "fro", label: "Afro" },
            { v: "froBand", label: "Afro mit Band" },
            { v: "dreads01", label: "Dreads kurz" },
            { v: "dreads02", label: "Dreads" },
            { v: "frizzle", label: "Kraus" },
            { v: "shaggy", label: "Zottelig" },
            { v: "shaggyMullet", label: "Vokuhila" },
            { v: "curly", label: "Lockig lang" },
            { v: "curvy", label: "Wellig lang" },
            { v: "straight01", label: "Glatt lang" },
            { v: "straight02", label: "Glatt lang 2" },
            { v: "straightAndStrand", label: "Glatt mit Strähne" },
            { v: "longButNotTooLong", label: "Mittellang" },
            { v: "bob", label: "Bob" },
            { v: "bun", label: "Dutt" },
            { v: "bigHair", label: "Volumen" },
            { v: "miaWallace", label: "Pony" },
            { v: "frida", label: "Blumenkranz" },
            { v: "hat", label: "Hut" },
            { v: "winterHat1", label: "Mütze" },
            { v: "winterHat02", label: "Bommelmütze" },
            { v: "hijab", label: "Hidschab" },
            { v: "turban", label: "Turban" },
            { v: "none", label: "Glatze" },
        ],
    },
    {
        key: "hairColor",
        label: "Haarfarbe",
        values: [
            { v: "2c1b18", label: "Schwarz", color: "#2c1b18" },
            { v: "4a312c", label: "Dunkelbraun", color: "#4a312c" },
            { v: "724133", label: "Braun", color: "#724133" },
            { v: "a55728", label: "Kastanie", color: "#a55728" },
            { v: "b58143", label: "Hellbraun", color: "#b58143" },
            { v: "d6b370", label: "Blond", color: "#d6b370" },
            { v: "c93305", label: "Rot", color: "#c93305" },
            { v: "e8e1e1", label: "Grau", color: "#e8e1e1" },
        ],
    },
    {
        key: "facialHair",
        label: "Bart",
        values: [
            { v: "none", label: "Kein Bart" },
            { v: "beardLight", label: "Leicht" },
            { v: "beardMedium", label: "Mittel" },
            { v: "beardMajestic", label: "Voll" },
            { v: "moustacheFancy", label: "Schnurrbart" },
            { v: "moustacheMagnum", label: "Magnum" },
        ],
    },
    {
        key: "accessories",
        label: "Brille",
        values: [
            { v: "none", label: "Keine" },
            { v: "prescription01", label: "Brille" },
            { v: "prescription02", label: "Brille 2" },
            { v: "round", label: "Rund" },
            { v: "wayfarers", label: "Wayfarer" },
            { v: "sunglasses", label: "Sonnenbrille" },
        ],
    },
    {
        key: "clothing",
        label: "Kleidung",
        values: [
            { v: "hoodie", label: "Hoodie" },
            { v: "shirtCrewNeck", label: "T-Shirt" },
            { v: "shirtVNeck", label: "V-Ausschnitt" },
            { v: "shirtScoopNeck", label: "U-Ausschnitt" },
            { v: "graphicShirt", label: "Print-Shirt" },
            { v: "collarAndSweater", label: "Pulli mit Kragen" },
            { v: "blazerAndShirt", label: "Sakko + Hemd" },
            { v: "blazerAndSweater", label: "Sakko + Pulli" },
            { v: "overall", label: "Latzhose" },
        ],
    },
    {
        key: "clothesColor",
        label: "Farbe der Kleidung",
        values: [
            { v: "262e33", label: "Schwarz", color: "#262e33" },
            { v: "3c4f5c", label: "Anthrazit", color: "#3c4f5c" },
            { v: "929598", label: "Grau", color: "#929598" },
            { v: "25557c", label: "Dunkelblau", color: "#25557c" },
            { v: "5199e4", label: "Blau", color: "#5199e4" },
            { v: "65c9ff", label: "Hellblau", color: "#65c9ff" },
            { v: "a7ffc4", label: "Mint", color: "#a7ffc4" },
            { v: "ffffb1", label: "Gelb", color: "#ffffb1" },
            { v: "ffafb9", label: "Rosa", color: "#ffafb9" },
            { v: "ff5c5c", label: "Rot", color: "#ff5c5c" },
            { v: "ff488e", label: "Pink", color: "#ff488e" },
        ],
    },
];

// Ohne eigene Wahl: nur natürliche Hauttöne/Haarfarben und freundliche Gesichter
const BASE = {
    skinColor: ["614335", "d08b5b", "ae5d29", "edb98a", "ffdbb4"],
    hairColor: ["a55728", "2c1b18", "b58143", "d6b370", "724133", "4a312c", "c93305", "e8e1e1"],
    accessories: ["prescription01", "prescription02", "round", "sunglasses", "wayfarers"],
    accessoriesProbability: 14,
    facialHairProbability: 22,
    topProbability: 96,
    clothesColor: ["262e33", "3c4f5c", "5199e4", "25557c", "929598", "a7ffc4", "ff488e", "ff5c5c", "ffafb9", "ffffb1", "b1e2ff", "65c9ff"],
} as const;

const MOODS = {
    normal: {
        mouth: ["smile", "default", "twinkle", "serious"],
        eyes: ["default", "happy", "wink", "side", "squint"],
        eyebrows: ["default", "defaultNatural", "raisedExcited", "raisedExcitedNatural", "flatNatural", "upDownNatural"],
    },
    panic: { mouth: ["screamOpen"], eyes: ["surprised"], eyebrows: ["raisedExcited"] },
    out: { mouth: ["concerned"], eyes: ["xDizzy"], eyebrows: ["sadConcerned"] },
} as const;

/** Eigene Wahl -> DiceBear-Optionen (jeweils genau ein Wert; "none" = weglassen). */
function configOptions(c: AvatarConfig): Record<string, unknown> {
    const o: Record<string, unknown> = {};
    if (c.skinColor) o.skinColor = [c.skinColor];
    if (c.hairColor) o.hairColor = [c.hairColor];
    if (c.clothesColor) o.clothesColor = [c.clothesColor];
    if (c.clothing) o.clothing = [c.clothing];
    if (c.top) {
        if (c.top === "none") o.topProbability = 0;
        else {
            o.top = [c.top];
            o.topProbability = 100;
        }
    }
    if (c.accessories) {
        if (c.accessories === "none") o.accessoriesProbability = 0;
        else {
            o.accessories = [c.accessories];
            o.accessoriesProbability = 100;
        }
    }
    if (c.facialHair) {
        if (c.facialHair === "none") o.facialHairProbability = 0;
        else {
            o.facialHair = [c.facialHair];
            o.facialHairProbability = 100;
        }
    }
    return o;
}

const cache = new Map<string, string>();

function avatarUri(seed: string, mood: AvatarMood, config?: AvatarConfig | null): string {
    const cfg = config && Object.keys(config).length ? config : null;
    const key = `${mood}|${seed}|${cfg ? JSON.stringify(cfg) : ""}`;
    const hit = cache.get(key);
    if (hit) return hit;
    const uri = createAvatar(avataaars, {
        seed,
        ...BASE,
        ...(cfg ? configOptions(cfg) : {}),
        ...MOODS[mood],
    } as Parameters<typeof createAvatar<typeof avataaars>>[1]).toDataUri();
    cache.set(key, uri);
    return uri;
}

export function PlayerAvatar({
    seed,
    mood = "normal",
    size,
    className = "",
    config = null,
}: {
    seed: string;
    mood?: AvatarMood;
    size: number;
    className?: string;
    config?: AvatarConfig | null;
}) {
    const src = useMemo(() => avatarUri(seed, mood, config), [seed, mood, config]);
    // eslint-disable-next-line @next/next/no-img-element -- Daten-URI, kein Bild vom Server
    return <img src={src} alt="" width={size} height={size} className={className} draggable={false} />;
}
