"use client";

import { useEffect } from "react";
import { installAudioUnlock } from "@/lib/songAudio";

/** Schaltet den Song-Player beim ersten Tipp/Tastendruck irgendwo in der App frei (siehe lib/songAudio.ts). */
export function AudioUnlock() {
    useEffect(() => {
        installAudioUnlock();
    }, []);
    return null;
}
