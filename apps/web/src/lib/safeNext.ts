/**
 * Prüft ein Weiterleitungsziel aus der URL (?next=…). Nur interne Pfade sind erlaubt –
 * sonst könnte ein präparierter Link nach dem Login auf eine fremde Seite schicken
 * (z. B. "//böse.de", "/\böse.de", "https://böse.de", "javascript:…").
 */
export function safeNextPath(v: string | null | undefined, fallback = "/"): string {
    if (!v) return fallback;
    if (v.length > 300) return fallback;
    if (!v.startsWith("/")) return fallback;
    if (v.startsWith("//") || v.startsWith("/\\")) return fallback;
    if (/[\\\u0000-\u001f\u007f]/.test(v)) return fallback;
    try {
        const u = new URL(v, "https://kumpir.invalid");
        if (u.origin !== "https://kumpir.invalid") return fallback;
        return u.pathname + u.search + u.hash;
    } catch {
        return fallback;
    }
}
