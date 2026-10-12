"use client";

import { useMemo } from "react";
import { createAvatar } from "@dicebear/core";
import * as avataaars from "@dicebear/avataaars";

/**
 * Gezeichneter Mensch (Kopf + Schultern) für den Spieltisch statt eines Kreises mit Initialen.
 * Stil "Avataaars" von Pablo Stanley (frei für private und kommerzielle Nutzung), erzeugt im Browser
 * mit DiceBear – kein externer Dienst. Gleicher Name = immer dieselbe Person.
 *
 * Stimmung:  normal = freundlich · panic = hält gerade die Kumpir · out = ausgeschieden
 */
export type AvatarMood = "normal" | "panic" | "out";

// Nur natürliche Hauttöne/Haarfarben und freundliche Gesichter (kein Würgen, Weinen, Augenklappe …)
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

const cache = new Map<string, string>();

function avatarUri(seed: string, mood: AvatarMood): string {
    const key = `${mood}|${seed}`;
    const hit = cache.get(key);
    if (hit) return hit;
    const uri = createAvatar(avataaars, {
        seed,
        ...BASE,
        ...MOODS[mood],
    } as Parameters<typeof createAvatar<typeof avataaars>>[1]).toDataUri();
    cache.set(key, uri);
    return uri;
}

export function PlayerAvatar({ seed, mood = "normal", size, className = "" }: { seed: string; mood?: AvatarMood; size: number; className?: string }) {
    const src = useMemo(() => avatarUri(seed, mood), [seed, mood]);
    // eslint-disable-next-line @next/next/no-img-element -- Daten-URI, kein Bild vom Server
    return <img src={src} alt="" width={size} height={size} className={className} draggable={false} />;
}
