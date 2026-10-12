"use client";

import { useEffect, useState } from "react";

/** true, solange die CSS-Media-Query zutrifft (beim ersten Rendern false, dann sofort richtig). */
export function useMediaQuery(query: string): boolean {
    const [matches, setMatches] = useState(false);
    useEffect(() => {
        const mq = window.matchMedia(query);
        const update = () => setMatches(mq.matches);
        update();
        mq.addEventListener("change", update);
        return () => mq.removeEventListener("change", update);
    }, [query]);
    return matches;
}
