"use client";

import { useMemo } from "react";
import { createAvatar } from "@dicebear/core";
import * as avataaars from "@dicebear/avataaars";

/**
 * Gezeichneter Mensch (Kopf + Schultern) für Tisch, Lobby, Ergebnisse und Freunde.
 * Stil "Avataaars" von Pablo Stanley (frei für private und kommerzielle Nutzung), erzeugt im Browser
 * mit DiceBear – kein externer Dienst.
 *
 * Aussehen: eigene Wahl aus dem Profil (avatar_config, Migration 102/103) oder – ohne Wahl – aus dem Namen
 * abgeleitet (gleicher Name = immer dieselbe Person). Augenfarbe, Brust-Logo und Ziegenbart (nur Achi)
 * zeichnen wir selbst dazu (decorate), weil DiceBear sie nicht kennt.
 * Stimmung:  normal = freundlich · panic = hält gerade die Kumpir · out = ausgeschieden
 */
export type AvatarMood = "normal" | "panic" | "out";

export type AvatarConfig = Partial<{
    gender: string;
    top: string;
    hairColor: string;
    hatColor: string;
    skinColor: string;
    eyeColor: string;
    clothing: string;
    clothesColor: string;
    logo: string;
    accessories: string;
    accessoriesColor: string;
    facialHair: string;
    facialHairColor: string;
}>;

type Opt = { v: string; label: string; color?: string };

const COLOR_LABEL: Record<string, string> = {
    "262e33": "Schwarz",
    "3c4f5c": "Anthrazit",
    "929598": "Grau",
    e6e6e6: "Hellgrau",
    ffffff: "Weiß",
    "25557c": "Dunkelblau",
    "5199e4": "Blau",
    "65c9ff": "Hellblau",
    b1e2ff: "Eisblau",
    a7ffc4: "Mint",
    ffffb1: "Gelb",
    ffdeb5: "Beige",
    ffafb9: "Rosa",
    ff5c5c: "Rot",
    ff488e: "Pink",
};
const colorValues = (list: string[]): Opt[] => list.map((v) => ({ v, label: COLOR_LABEL[v] ?? v, color: `#${v}` }));

const HAIR_COLORS: Opt[] = [
    { v: "2c1b18", label: "Schwarz", color: "#2c1b18" },
    { v: "4a312c", label: "Dunkelbraun", color: "#4a312c" },
    { v: "724133", label: "Braun", color: "#724133" },
    { v: "a55728", label: "Kastanie", color: "#a55728" },
    { v: "b58143", label: "Hellbraun", color: "#b58143" },
    { v: "d6b370", label: "Blond", color: "#d6b370" },
    { v: "c93305", label: "Rot", color: "#c93305" },
    { v: "e8e1e1", label: "Grau", color: "#e8e1e1" },
];

/** Frisuren je Typ (Kopfbedeckungen für alle) – Werte müssen zu public._avatar_allowed() passen. */
export const TOPS_MALE = ["shortFlat", "shortRound", "shortWaved", "shortCurly", "theCaesar", "theCaesarAndSidePart", "sides", "shavedSides", "fro", "froBand", "dreads01", "dreads02", "frizzle", "shaggy", "shaggyMullet", "none"];
export const TOPS_FEMALE = ["straight01", "straight02", "straightAndStrand", "longButNotTooLong", "curly", "curvy", "bob", "bun", "bigHair", "miaWallace", "frida", "fro", "froBand", "dreads02", "hijab"];
export const TOPS_HEADWEAR = ["hat", "winterHat1", "winterHat02", "winterHat03", "winterHat04", "turban"];

const TOP_LABEL: Record<string, string> = {
    shortFlat: "Kurz glatt",
    shortRound: "Kurz rund",
    shortWaved: "Kurz wellig",
    shortCurly: "Kurz lockig",
    theCaesar: "Caesar",
    theCaesarAndSidePart: "Seitenscheitel",
    sides: "Seiten",
    shavedSides: "Undercut",
    fro: "Afro",
    froBand: "Afro mit Band",
    dreads01: "Dreads kurz",
    dreads02: "Dreads",
    frizzle: "Kraus",
    shaggy: "Zottelig",
    shaggyMullet: "Vokuhila",
    none: "Glatze",
    straight01: "Glatt lang",
    straight02: "Glatt lang 2",
    straightAndStrand: "Glatt mit Strähne",
    longButNotTooLong: "Mittellang",
    curly: "Lockig lang",
    curvy: "Wellig lang",
    bob: "Bob",
    bun: "Dutt",
    bigHair: "Volumen",
    miaWallace: "Pony",
    frida: "Blumenkranz",
    hijab: "Hidschab",
    hat: "🎩 Hut",
    winterHat1: "🧢 Mütze",
    winterHat02: "🧢 Bommelmütze",
    winterHat03: "🧢 Mütze mit Ohrenklappen",
    winterHat04: "🧢 Strickmütze",
    turban: "Turban",
};

/** Frisuren passend zum Typ + alle Kopfbedeckungen */
export function topValues(gender?: string): Opt[] {
    const hair = gender === "f" ? TOPS_FEMALE : TOPS_MALE;
    return [...hair, ...TOPS_HEADWEAR].map((v) => ({ v, label: TOP_LABEL[v] ?? v }));
}

/** Auswahl im Profil. `when` blendet Felder aus, die gerade nicht passen (z. B. Bart bei "weiblich"). */
export const AVATAR_OPTIONS: { key: keyof AvatarConfig; label: string; values: Opt[]; when?: (c: AvatarConfig) => boolean }[] = [
    {
        key: "gender",
        label: "Typ",
        values: [
            { v: "m", label: "Männlich" },
            { v: "f", label: "Weiblich" },
        ],
    },
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
        key: "eyeColor",
        label: "Augenfarbe",
        values: [
            { v: "4a2c17", label: "Dunkelbraun", color: "#4a2c17" },
            { v: "7a4a22", label: "Braun", color: "#7a4a22" },
            { v: "3f8a4a", label: "Grün", color: "#3f8a4a" },
            { v: "2f6fb5", label: "Blau", color: "#2f6fb5" },
            { v: "5aa0d8", label: "Hellblau", color: "#5aa0d8" },
            { v: "6b7a88", label: "Grau", color: "#6b7a88" },
            { v: "1a1a1a", label: "Schwarz", color: "#1a1a1a" },
        ],
    },
    { key: "top", label: "Frisur / Kopfbedeckung", values: [] }, // Liste je nach Typ: topValues()
    { key: "hairColor", label: "Haarfarbe", values: HAIR_COLORS, when: (c) => c.top !== "none" },
    {
        key: "hatColor",
        label: "Farbe der Kopfbedeckung",
        values: colorValues(["262e33", "3c4f5c", "929598", "e6e6e6", "ffffff", "25557c", "5199e4", "65c9ff", "b1e2ff", "a7ffc4", "ffffb1", "ffdeb5", "ffafb9", "ff5c5c", "ff488e"]),
        when: (c) => !!c.top && (TOPS_HEADWEAR.includes(c.top) || c.top === "hijab"),
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
        when: (c) => c.gender !== "f",
    },
    { key: "facialHairColor", label: "Bartfarbe", values: HAIR_COLORS, when: (c) => c.gender !== "f" && !!c.facialHair && c.facialHair !== "none" },
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
        key: "accessoriesColor",
        label: "Brillenfarbe",
        values: colorValues(["262e33", "3c4f5c", "929598", "e6e6e6", "25557c", "5199e4", "65c9ff", "a7ffc4", "ffffb1", "ffafb9", "ff5c5c", "ff488e"]),
        when: (c) => !!c.accessories && c.accessories !== "none",
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
        values: colorValues(["262e33", "3c4f5c", "929598", "e6e6e6", "ffffff", "25557c", "5199e4", "65c9ff", "b1e2ff", "a7ffc4", "ffffb1", "ffafb9", "ff5c5c", "ff488e"]),
    },
    {
        key: "logo",
        label: "Logo auf der Brust",
        values: [
            { v: "none", label: "Kein Logo" },
            { v: "swoosh", label: "✔ Sport-Haken" },
            { v: "stripes", label: "▰ Drei Streifen" },
            { v: "crown", label: "👑 Krone" },
            { v: "bolt", label: "⚡ Blitz" },
        ],
        when: (c) => c.clothing !== "overall",
    },
];

/** Ziegenbart – nur für Achi (Migration 103 prüft das auch auf dem Server). */
export const GOATEE_OPTION: Opt = { v: "goatee", label: "Ziegenbart (nur Achi)" };

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
    if (c.hatColor) o.hatColor = [c.hatColor];
    if (c.facialHairColor) o.facialHairColor = [c.facialHairColor];
    if (c.accessoriesColor) o.accessoriesColor = [c.accessoriesColor];
    if (c.clothesColor) o.clothesColor = [c.clothesColor];
    if (c.clothing) o.clothing = [c.clothing];
    if (c.top) {
        if (c.top === "none") o.topProbability = 0;
        else {
            o.top = [c.top];
            o.topProbability = 100;
        }
    } else if (c.gender === "f") o.top = TOPS_FEMALE.filter((t) => t !== "hijab");
    else if (c.gender === "m") o.top = TOPS_MALE.filter((t) => t !== "none");
    if (c.accessories) {
        if (c.accessories === "none") o.accessoriesProbability = 0;
        else {
            o.accessories = [c.accessories];
            o.accessoriesProbability = 100;
        }
    }
    if (c.gender === "f") o.facialHairProbability = 0;
    else if (c.facialHair) {
        // Ziegenbart zeichnen wir selbst (decorate) -> DiceBear-Bart aus
        if (c.facialHair === "none" || c.facialHair === "goatee") o.facialHairProbability = 0;
        else {
            o.facialHair = [c.facialHair];
            o.facialHairProbability = 100;
        }
    }
    return o;
}

const DARK_CLOTHES = ["262e33", "3c4f5c", "25557c", "5199e4", "ff5c5c", "ff488e", "929598"];

/** Was DiceBear nicht kann: Augenfarbe, Logo auf der Brust, Ziegenbart. Koordinaten im 280er-Raster von Avataaars. */
function decorate(svg: string, c: AvatarConfig | null, mood: AvatarMood): string {
    if (!c) return svg;
    let out = svg;
    if (c.eyeColor && mood !== "out") {
        const a = out.indexOf('translate(76 90)">');
        const b = a >= 0 ? out.indexOf('<g transform="translate(76 82)">', a) : -1;
        if (a >= 0 && b > a) {
            const eyes = out
                .slice(a, b)
                .split('fill="#000"')
                .join(`fill="#${c.eyeColor}"`)
                .split('fill-opacity=".6"')
                .join('fill-opacity=".95"')
                .split('fill-opacity=".7"')
                .join('fill-opacity=".95"');
            out = out.slice(0, a) + eyes + out.slice(b);
        }
    }
    const extra: string[] = [];
    if (c.logo && c.logo !== "none" && c.clothing !== "overall") {
        const col = DARK_CLOTHES.includes(c.clothesColor ?? "") ? "#ffffff" : "#1b1f24";
        const at = 'transform="translate(176 236)"';
        if (c.logo === "swoosh") extra.push(`<path ${at} d="M0 9c3 5 8 6 14 3 6-3 13-8 19-13-6 7-13 13-20 16-7 3-12 1-13-6Z" fill="${col}" opacity=".92"/>`);
        if (c.logo === "stripes") extra.push(`<g ${at} fill="${col}" opacity=".92"><path d="M2 14 6 4h4L6 14Z"/><path d="M9 14l5-14h4l-5 14Z"/><path d="M16 14 22-2h4l-6 16Z"/></g>`);
        if (c.logo === "crown") extra.push(`<path ${at} d="M1 12 0 1l7 5 5-7 5 7 7-5-1 11Z" fill="${col}" opacity=".92"/>`);
        if (c.logo === "bolt") extra.push(`<path ${at} d="M10-2 1 9h6l-3 9 11-12H9l4-8Z" fill="${col}" opacity=".92"/>`);
    }
    if (c.facialHair === "goatee" && c.gender !== "f") {
        const hc = `#${c.facialHairColor ?? c.hairColor ?? "2c1b18"}`;
        extra.push(`<g fill="${hc}"><path d="M125 167c5 5 25 5 30 0 2 10-3 21-15 25-12-4-17-15-15-25Z"/><path d="M135 159h10c0 3-2 4-5 4s-5-1-5-4Z" opacity=".9"/></g>`);
    }
    if (extra.length) {
        const end = out.lastIndexOf("</svg>");
        if (end > 0) out = out.slice(0, end) + extra.join("") + out.slice(end);
    }
    return out;
}

const cache = new Map<string, string>();

function avatarUri(seed: string, mood: AvatarMood, config?: AvatarConfig | null): string {
    const cfg = config && Object.keys(config).length ? config : null;
    const key = `${mood}|${seed}|${cfg ? JSON.stringify(cfg) : ""}`;
    const hit = cache.get(key);
    if (hit) return hit;
    const svg = createAvatar(avataaars, {
        seed,
        ...BASE,
        ...(cfg ? configOptions(cfg) : {}),
        ...MOODS[mood],
    } as Parameters<typeof createAvatar<typeof avataaars>>[1]).toString();
    const uri = `data:image/svg+xml;utf8,${encodeURIComponent(decorate(svg, cfg, mood))}`;
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
