export type RoundSpeed = "fast" | "normal" | "calm";
export type GameMode = "original" | "blitz" | "casual" | "teleport" | "reverse";

export const ROUND_SPEEDS: Record<RoundSpeed, { label: string; seconds: number; hint: string }> = {
    fast:   { label: "Fast",   seconds: 15, hint: "Schnell, hoher Druck." },
    normal: { label: "Normal", seconds: 25, hint: "Ausgewogen." },
    calm:   { label: "Calm",   seconds: 40, hint: "Entspannt, mehr Zeit." },
};

export const MODES: Record<GameMode, { label: string; icon: string; desc: string; featured?: boolean }> = {
    original: { label: "Original", icon: "🥔", desc: "Standard-Regeln. Beste Basis für alle.", featured: true },
    blitz:    { label: "Blitz",    icon: "⚡", desc: "Schneller, direkter, mehr Druck." },
    casual:   { label: "Casual",   icon: "🧊", desc: "Entspannt und locker." },
    teleport: { label: "Teleport", icon: "🌀", desc: "Kartoffel springt unerwartet.", },
    reverse:  { label: "Reverse",  icon: "🔁", desc: "Richtung kann wechseln.", },
};
