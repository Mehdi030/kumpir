"use client";

const cache = new Map<string, Promise<string | null>>();

const norm = (s: string) =>
    s
        .toLowerCase()
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .replace(/\(.*?\)|\[.*?\]/g, " ")
        .replace(/[^a-z0-9]+/g, " ")
        .trim();

/**
 * Cover zu einem Song (Hit oder Flop): iTunes-Suche (öffentlich, ohne Schlüssel) nach Titel + erstem Künstler, das erste passende
 * Ergebnis liefert das Albumbild. Kein Treffer oder Netzfehler = null (die Oberfläche zeigt dann eine Schallplatte).
 * Jeder Client fragt selbst, das Ergebnis wird pro Song zwischengespeichert.
 */
export function coverUrlOf(title: string, artist: string | null): Promise<string | null> {
    const first = (artist ?? "").split(/,|&| feat\.?| ft\.?| x /i)[0].trim();
    const key = `${norm(title)}|${norm(first)}`;
    const hit = cache.get(key);
    if (hit) return hit;
    const p = (async () => {
        try {
            const ctrl = new AbortController();
            const timer = window.setTimeout(() => ctrl.abort(), 6000);
            const url = `https://itunes.apple.com/search?term=${encodeURIComponent(`${title} ${first}`.trim())}&media=music&entity=song&limit=6&country=de`;
            const res = await fetch(url, { signal: ctrl.signal });
            window.clearTimeout(timer);
            if (!res.ok) return null;
            const json = (await res.json()) as { results?: { trackName?: string; artistName?: string; artworkUrl100?: string }[] };
            const t = norm(title);
            const a = norm(first);
            const rows = json.results ?? [];
            const best =
                rows.find((r) => norm(r.trackName ?? "") === t && (!a || norm(r.artistName ?? "").includes(a))) ??
                rows.find((r) => norm(r.trackName ?? "").includes(t) && (!a || norm(r.artistName ?? "").includes(a))) ??
                (a ? null : rows.find((r) => norm(r.trackName ?? "").includes(t)));
            const art = best?.artworkUrl100;
            return art ? art.replace(/\/\d+x\d+bb\./, "/400x400bb.") : null;
        } catch {
            return null;
        }
    })();
    cache.set(key, p);
    return p;
}
