#!/usr/bin/env node
/**
 * Baut die Playlist "Deutschrap aktuell" aus data/deutschrap-rapper.json:
 *  1. Beliebtheit: Deezer "Top-Songs" pro Rapper (öffentliche API, Feld rank)
 *  2. Vorschau + Erscheinungsdatum: iTunes-Suche (wie alle anderen Playlists)
 *  3. nur Songs der letzten N Jahre (erste Veröffentlichung), keine Remixe/Live/Intros,
 *     "feat."-Anhängsel aus dem Titel entfernt, keine Dubletten (auch nicht zu bestehenden Playlists)
 *  4. Auswahl: global nach Beliebtheit, höchstens maxPerArtist pro Rapper, bis target erreicht
 *  5. jede Vorschau-Datei wird abgerufen (HTTP 200)
 *
 * Aufruf: node db/scripts/build-deutschrap.mjs <ausgabe.sql>
 * Bericht: db/scripts/data/deutschrap-report.json
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const cfg = JSON.parse(readFileSync(resolve(__dirname, "data/deutschrap-rapper.json"), "utf8"));
const out = process.argv[2];
if (!out) throw new Error("Aufruf: node db/scripts/build-deutschrap.mjs <ausgabe.sql>");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const norm = (s) =>
    (s ?? "")
        .toLowerCase()
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .replace(/ß/g, "ss")
        .replace(/\(.*?\)|\[.*?\]/g, " ")
        .replace(/[^a-z0-9 ]/g, " ")
        .replace(/\s+/g, " ")
        .trim();
const q = (s) => "'" + s.replace(/'/g, "''") + "'";

/** "Wunder (feat. Apache 207)" -> "Wunder", "Song - Single" -> "Song" */
function cleanTitle(t) {
    return t
        .replace(/\s*[([](feat\.?|ft\.?|prod\.?|with|mit|featuring)\b[^)\]]*[)\]]/gi, "")
        .replace(/\s+(feat\.?|ft\.?|featuring)\s.+$/i, "")
        .replace(/\s+-\s+(single|ep)$/i, "")
        .replace(/\s+/g, " ")
        .trim();
}
const BAD = /(remix|rmx|live|instrumental|a ?cappella|sped ?up|slowed|nightcore|\bedit\b|version|\bintro\b|\boutro\b|skit|interlude|reprise|karaoke|acoustic|unplugged|mashup|bonus|freestyle|medley|mix\b)/i;
function titleOk(t) {
    if (!t || t.length < 2 || t.length > 32) return false;
    if (!/[a-zäöüß]/i.test(t)) return false;
    if (BAD.test(t)) return false;
    if (/[()[\]]/.test(t)) return false; // übrig gebliebene Klammern -> schwer zu raten
    return true;
}

async function getJson(url, tries = 4) {
    for (let a = 0; a < tries; a++) {
        try {
            const res = await fetch(url);
            if (res.ok) {
                const txt = await res.text();
                return txt ? JSON.parse(txt) : null;
            }
        } catch {
            /* nochmal */
        }
        await sleep(4000 * (a + 1));
    }
    return null;
}

// Bestehende Titel (alle Playlists) -> keine Dubletten
function parseEnv(t) {
    const m = {};
    for (const l of t.split(/\r?\n/)) {
        if (!l.trim() || l.startsWith("#")) continue;
        const i = l.indexOf("=");
        if (i > 0) m[l.slice(0, i).trim()] = l.slice(i + 1);
    }
    return m;
}
const env = parseEnv(readFileSync(resolve(__dirname, "../.env.local"), "utf8"));
const client = new pg.Client({ host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres", user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await client.connect();
const existing = new Set(
    (await client.query("select sp.title from song_pool sp join topic_pool tp on tp.id = sp.topic_pool_id where tp.text <> $1", [cfg.playlist])).rows.map((r) => norm(r.title))
);
await client.end();

const since = new Date();
since.setFullYear(since.getFullYear() - cfg.sinceYears);
const sinceIso = since.toISOString().slice(0, 10);

const candidates = [];
const albumDates = new Map();
const perArtistReport = {};

for (const rapper of cfg.rapper) {
    const rep = (perArtistReport[rapper] = { deezerTop: 0, matched: 0, recent: 0, note: "" });

    // 1) Deezer: Künstler finden (exakter Name, meiste Fans) + Top-Songs
    const found = await getJson(`https://api.deezer.com/search/artist?q=${encodeURIComponent(rapper)}&limit=10`);
    const artist = (found?.data ?? []).filter((a) => norm(a.name) === norm(rapper)).sort((a, b) => b.nb_fan - a.nb_fan)[0];
    if (!artist) {
        rep.note = "bei Deezer nicht gefunden";
        continue;
    }
    const top = await getJson(`https://api.deezer.com/artist/${artist.id}/top?limit=50`);
    const tracks = top?.data ?? [];
    rep.deezerTop = tracks.length;

    // Erscheinungsdatum laut Deezer (Album/Single), mit Cache
    for (const t of tracks) {
        const albumId = t.album?.id;
        if (!albumId) continue;
        if (!albumDates.has(albumId)) {
            const alb = await getJson(`https://api.deezer.com/album/${albumId}`);
            albumDates.set(albumId, alb?.release_date ?? null);
            await sleep(150);
        }
        t._date = albumDates.get(albumId);
    }
    const recentTracks = tracks.filter((t) => t._date && t._date >= sinceIso).sort((a, b) => b.rank - a.rank);

    // Reichen die Top-Songs nicht (viele Rapper haben vor allem alte Hits), zusätzlich alle
    // Alben/Singles der letzten Jahre durchsuchen – deren Titel tragen ebenfalls Deezers Beliebtheit (rank).
    if (recentTracks.length < cfg.maxPerArtist + 4) {
        const seen = new Set(recentTracks.map((t) => norm(cleanTitle(t.title))));
        const albums = (await getJson(`https://api.deezer.com/artist/${artist.id}/albums?limit=100`))?.data ?? [];
        for (const alb of albums.filter((a) => a.release_date && a.release_date >= sinceIso)) {
            const tr = (await getJson(`https://api.deezer.com/album/${alb.id}/tracks?limit=100`))?.data ?? [];
            await sleep(150);
            for (const t of tr) {
                const k = norm(cleanTitle(t.title));
                if (seen.has(k)) continue;
                seen.add(k);
                t._date = alb.release_date;
                recentTracks.push(t);
            }
        }
        recentTracks.sort((a, b) => b.rank - a.rank);
    }
    rep.recent = recentTracks.length;

    // 2) iTunes: alle Songs des Rappers (eine Anfrage), fehlende danach gezielt einzeln
    const it = await getJson(`https://itunes.apple.com/search?term=${encodeURIComponent(rapper)}&entity=song&attribute=artistTerm&country=DE&limit=200`);
    await sleep(3500); // iTunes erlaubt nur ~20 Anfragen/Minute
    const byTitle = new Map();
    const addResult = (r) => {
        if (!r.previewUrl || !r.trackName || !r.artistName) return;
        const key = norm(cleanTitle(r.trackName));
        const prev = byTitle.get(key);
        // früheste Veröffentlichung zählt (Wiederveröffentlichungen alter Songs fallen so raus)
        if (!prev || (r.releaseDate && (!prev.releaseDate || r.releaseDate < prev.releaseDate))) byTitle.set(key, r);
    };
    for (const r of it?.results ?? []) if (norm(r.artistName ?? "").includes(norm(rapper))) addResult(r);

    let picked = 0;
    for (const t of recentTracks) {
        if (picked >= cfg.maxPerArtist + 4) break; // genug Kandidaten für diesen Rapper
        if (rep.tries > 40) break; // nicht endlos einzeln nachsuchen
        rep.tries = (rep.tries ?? 0) + 1;
        const title0 = cleanTitle(t.title);
        const key = norm(title0);
        if (!titleOk(title0) || existing.has(key)) continue;
        let hit = byTitle.get(key);
        if (!hit) {
            const res = await getJson(`https://itunes.apple.com/search?term=${encodeURIComponent(title0 + " " + rapper)}&media=music&entity=song&country=DE&limit=10`);
            await sleep(3500);
            for (const r of res?.results ?? []) {
                if (norm(cleanTitle(r.trackName ?? "")) === key && norm(r.artistName ?? "").includes(norm(rapper))) addResult(r);
            }
            hit = byTitle.get(key);
        }
        if (!hit) continue;
        rep.matched++;
        const itDate = hit.releaseDate ? hit.releaseDate.slice(0, 10) : null;
        if (itDate && itDate < sinceIso) continue; // alter Song, nur neu veröffentlicht
        const title = cleanTitle(hit.trackName);
        if (!titleOk(title)) continue;
        picked++;
        candidates.push({ rapper, title, artist: hit.artistName, rank: t.rank, released: itDate ?? t._date, preview: hit.previewUrl, key: norm(title) });
    }
    process.stdout.write(`${rapper}: ${rep.recent} aktuelle Treffer\n`);
}

// 3) Auswahl: global nach Beliebtheit, Deckel pro Rapper, keine Dubletten
candidates.sort((a, b) => b.rank - a.rank);
const chosen = [];
const used = new Set(existing);
const count = {};
for (const c of candidates) {
    if (chosen.length >= cfg.target) break;
    if (used.has(c.key)) continue;
    if ((count[c.rapper] ?? 0) >= cfg.maxPerArtist) continue;
    used.add(c.key);
    count[c.rapper] = (count[c.rapper] ?? 0) + 1;
    chosen.push(c);
}

// 4) Vorschau-Dateien prüfen
const final = [];
for (const c of chosen) {
    let ok = false;
    for (let a = 0; a < 3 && !ok; a++) {
        try {
            const res = await fetch(c.preview, { method: "HEAD" });
            ok = res.ok;
        } catch {
            /* nochmal */
        }
        if (!ok) await sleep(1000);
    }
    if (ok) final.push(c);
    else process.stdout.write(`Vorschau defekt, raus: ${c.title} – ${c.artist}\n`);
}

for (const r of Object.keys(perArtistReport)) perArtistReport[r].chosen = count[r] ?? 0;
writeFileSync(
    resolve(__dirname, "data/deutschrap-report.json"),
    JSON.stringify({ since: sinceIso, total: final.length, perRapper: perArtistReport, songs: final.map(({ key, preview, ...rest }) => rest) }, null, 2)
);

let sql = `-- Generiert von db/scripts/build-deutschrap.mjs (${new Date().toISOString().slice(0, 10)})\n`;
sql += `-- Playlist "${cfg.playlist}": ${final.length} Songs seit ${sinceIso}, Beliebtheit laut Deezer, Vorschau/Datum laut iTunes\n`;
sql += `BEGIN;\n\nINSERT INTO public.topic_pool (text, active, is_song_category)\nSELECT ${q(cfg.playlist)}, true, true\nWHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = ${q(cfg.playlist)});\n\n`;
// Songs, die nicht mehr in der Auswahl sind, ins Archiv (nicht löschen: Spielprotokoll/Statistik bleiben gültig)
sql += `INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Archiv (deaktivierte Songs)', false, false
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)');

`;
sql += `UPDATE public.song_pool s
SET archived_from = ${q(cfg.playlist)}, topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = 'Archiv (deaktivierte Songs)')
WHERE s.topic_pool_id = (SELECT id FROM public.topic_pool WHERE text = ${q(cfg.playlist)})
  AND lower(s.title) NOT IN (${final.map((c) => q(c.title.toLowerCase())).join(", ")});

`;
sql += `INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)\nSELECT tp.id, v.title, v.artist, v.url, now()\nFROM (VALUES\n`;
sql += final.map((c) => `    (${q(c.title)}, ${q(c.artist)}, ${q(c.preview)})`).join(",\n");
sql += `\n) AS v(title, artist, url)\nJOIN public.topic_pool tp ON tp.text = ${q(cfg.playlist)}\nWHERE NOT EXISTS (\n  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)\n);\n\nCOMMIT;\n`;
writeFileSync(out, sql);
console.log(`\nFertig: ${final.length} Songs (Ziel ${cfg.target}) -> ${out}`);
