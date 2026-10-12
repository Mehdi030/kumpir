// Holt für jeden Song mit Hörprobe die Feature-Partner von iTunes ("Titel (feat. X & Y)"), die beim
// Playlist-Bau aus dem Titel entfernt wurden. Der Treffer wird über die gespeicherte Hörproben-Adresse
// eindeutig zugeordnet. Fortschreibend: fertige Songs werden beim nächsten Lauf übersprungen.
//
//   node db/scripts/fetch-features.mjs <songs.json> <features.json>
//   songs.json = Ausgabe von query.mjs: [{id, title, artist, preview_url}]
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const [src, out] = process.argv.slice(2);
const songs = JSON.parse(readFileSync(src, "utf8"));
const res = existsSync(out) ? JSON.parse(readFileSync(out, "utf8")) : {};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const norm = (s) => (s ?? "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ß/g, "ss").replace(/\(.*?\)|\[.*?\]/g, " ").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();

function featuresOf(trackName) {
    const m = /[([]\s*(?:feat\.?|ft\.?|featuring|with|mit)\s+([^)\]]+)[)\]]/i.exec(trackName ?? "") || /\s(?:feat\.?|ft\.?|featuring)\s+(.+)$/i.exec(trackName ?? "");
    if (!m) return [];
    return m[1].split(/\s*,\s*|\s*&\s*|\s+und\s+|\s+x\s+/i).map((s) => s.trim()).filter(Boolean);
}

let n = 0;
for (const s of songs) {
    if (res[s.id]) continue;
    const main = s.artist.split(/\s*,\s*|\s*&\s*/)[0];
    let hit = null;
    for (let a = 0; a < 4 && !hit; a++) {
        try {
            const r = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(`${s.title} ${main}`)}&media=music&entity=song&country=DE&limit=15`);
            if (r.ok) {
                const j = await r.json();
                const list = j.results ?? [];
                hit = list.find((x) => x.previewUrl === s.preview_url) ?? list.find((x) => norm(x.trackName).startsWith(norm(s.title)) && norm(x.artistName).includes(norm(main))) ?? null;
                if (!hit) break;
            } else await sleep(5000 * (a + 1));
        } catch {
            await sleep(3000);
        }
    }
    res[s.id] = { feat: hit ? featuresOf(hit.trackName) : [], itunesArtist: hit?.artistName ?? null, trackName: hit?.trackName ?? null };
    n++;
    if (res[s.id].feat.length) console.log(`${s.title} – ${s.artist}  +feat: ${res[s.id].feat.join(", ")}`);
    if (n % 10 === 0) writeFileSync(out, JSON.stringify(res, null, 1));
    await sleep(3200); // iTunes erlaubt ~20 Anfragen pro Minute
}
writeFileSync(out, JSON.stringify(res, null, 1));
console.log(`fertig: ${Object.keys(res).length} Songs, mit Features: ${Object.values(res).filter((x) => x.feat.length).length}`);
