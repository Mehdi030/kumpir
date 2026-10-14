#!/usr/bin/env node
/**
 * Baut In-Game-Playlists aus öffentlichen Spotify-Playlists (Wunsch Mehdi 2026-10-14).
 *  1. Spotify-Playlist laden: https://open.spotify.com/embed/playlist/<id> enthält die ersten 100 Titel samt
 *     30-Sekunden-Hörprobe (audioPreview.url, p.scdn.co) – kein Login nötig. (iTunes hat viele neue Deutschrap-Songs
 *     NICHT: Testlauf 15 von 50 bzw. 11 von 70 – deshalb kommen die Hörproben von Spotify selbst.)
 *  2. Erscheinungsjahr für "Jahr raten" von Deezer (öffentliche Suche, früheste Veröffentlichung aller exakten Treffer).
 *  3. Hörprobe per HEAD prüfen (HTTP 200).
 *  4. Bericht: db/scripts/data/spotify-playlists-report.json, SQL: <ausgabe.sql>
 *
 * Aufruf: node db/scripts/build-spotify-playlists.mjs <cache.json|-> <ausgabe.sql> [nur-Playlistname]
 *   <cache.json> = zwischengespeicherte Spotify-Daten (wird beim ersten Lauf angelegt)
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Name im Spiel -> Spotify-Playlist */
const PLAYLISTS = [
    { name: "Top 50 Deutschrap", id: "36BS72kjzt0c8BIkwOvQUB" },
    { name: "Deutschrap Asphalt", id: "37i9dQZF1DXbWS0mKtnghU" },
    { name: "Nostalgie", id: "3EIC2YmoiAYlfyCyV9vtHD" },
    { name: "ICON 5", id: "4dp1B9ShVkftIC65qV8sne" },
];

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
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
function cleanTitle(t) {
    return t
        .replace(/\s*[([](feat\.?|ft\.?|prod\.?|with|mit|featuring)\b[^)\]]*[)\]]/gi, "")
        .replace(/\s+(feat\.?|ft\.?|featuring)\s.+$/i, "")
        .replace(/\s+-\s+(single|ep|remastered.*|radio edit|\d{4} remaster.*)$/i, "")
        .replace(/\s+/g, " ")
        .trim();
}
const BAD = /(remix|rmx|\blive\b|instrumental|a ?cappella|sped ?up|slowed|nightcore|karaoke|\bintro\b|\boutro\b|\bskit\b|interlude)/i;
/** "A, B, C" -> "A, B & C" (so stehen mehrere Künstler auch in den anderen Playlists) */
const joinArtists = (s) => {
    const p = String(s ?? "").split(/\s*,\s*/).filter(Boolean);
    return p.length < 2 ? p[0] ?? "" : p.slice(0, -1).join(", ") + " & " + p[p.length - 1];
};

async function getJson(url, tries = 3) {
    for (let a = 0; a < tries; a++) {
        try {
            const res = await fetch(url, { headers: { "user-agent": "Mozilla/5.0" } });
            if (res.ok) return await res.json();
        } catch {
            /* nochmal */
        }
        await sleep(1500 * (a + 1));
    }
    return null;
}

async function loadSpotify(id) {
    const res = await fetch(`https://open.spotify.com/embed/playlist/${id}`, { headers: { "user-agent": "Mozilla/5.0" } });
    const html = await res.text();
    const m = html.match(/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s);
    if (!m) throw new Error("Spotify-Seite ohne Daten: " + id);
    const ent = JSON.parse(m[1]).props.pageProps.state.data.entity;
    return {
        title: ent.name ?? ent.title,
        tracks: (ent.trackList ?? []).map((t) => ({ title: t.title, artist: t.subtitle, preview: t.audioPreview?.url ?? null })),
    };
}

/** Erscheinungsjahr laut Deezer: früheste Veröffentlichung aller exakten Treffer (Titel + erster Künstler) */
async function deezerYear(title, firstArtist) {
    const res = await getJson(`https://api.deezer.com/search?q=${encodeURIComponent(`${firstArtist} ${title}`)}&limit=10`);
    await sleep(250);
    const hits = (res?.data ?? []).filter((r) => norm(cleanTitle(r.title ?? "")) === norm(title) && norm(r.artist?.name ?? "").includes(norm(firstArtist)));
    let best = null;
    for (const h of hits.slice(0, 3)) {
        const d = await getJson(`https://api.deezer.com/track/${h.id}`);
        await sleep(250);
        const y = d?.release_date ? Number(String(d.release_date).slice(0, 4)) : null;
        if (y && y > 1950 && (best == null || y < best)) best = y;
    }
    return best;
}

const [src, out, only] = process.argv.slice(2);
if (!src || !out) throw new Error("Aufruf: node db/scripts/build-spotify-playlists.mjs <cache.json|-> <ausgabe.sql> [Playlistname]");

let spotify = {};
if (src !== "-" && existsSync(src)) spotify = JSON.parse(readFileSync(src, "utf8"));
for (const p of PLAYLISTS) {
    if (!spotify[p.id] || !spotify[p.id].tracks.some((t) => t.preview !== undefined)) spotify[p.id] = await loadSpotify(p.id);
}
if (src !== "-") writeFileSync(src, JSON.stringify(spotify, null, 1));

const report = {};
const result = [];
for (const p of PLAYLISTS.filter((x) => !only || x.name === only)) {
    const list = spotify[p.id];
    const rep = (report[p.name] = { spotifyTitle: list.title, spotifyTracks: list.tracks.length, usable: 0, withYear: 0, badTitle: [], noPreview: [], brokenPreview: [], dupes: 0, noYear: [], byArtist: {} });
    const seen = new Set();
    const final = [];
    for (const [i, t] of list.tracks.entries()) {
        const title = cleanTitle(t.title ?? "");
        const firstArtist = String(t.artist ?? "").split(/\s*,\s*/)[0].trim();
        if (!title || BAD.test(title) || title.length > 44) {
            rep.badTitle.push(`${t.title} – ${t.artist}`);
            continue;
        }
        if (!t.preview) {
            rep.noPreview.push(`${t.title} – ${t.artist}`);
            continue;
        }
        const key = title.toLowerCase(); // pro Playlist ist der Titel eindeutig (Datenbank-Regel)
        if (seen.has(key)) {
            rep.dupes++;
            continue;
        }
        seen.add(key);
        let ok = false;
        for (let a = 0; a < 3 && !ok; a++) {
            try {
                ok = (await fetch(t.preview, { method: "HEAD" })).ok;
            } catch {
                /* nochmal */
            }
            if (!ok) await sleep(600);
        }
        if (!ok) {
            rep.brokenPreview.push(`${t.title} – ${t.artist}`);
            continue;
        }
        const year = await deezerYear(title, firstArtist);
        if (year) rep.withYear++;
        else rep.noYear.push(`${t.title} – ${t.artist}`);
        final.push({ title, artist: joinArtists(t.artist), preview: t.preview, year });
        const a0 = firstArtist;
        rep.byArtist[a0] = (rep.byArtist[a0] ?? 0) + 1;
        if ((i + 1) % 20 === 0) process.stdout.write(`${p.name}: ${i + 1}/${list.tracks.length}\n`);
    }
    rep.usable = final.length;
    result.push({ name: p.name, songs: final });
    console.log(`${p.name}: ${final.length} von ${list.tracks.length} nutzbar, ${rep.withYear} mit Jahr`);
}
writeFileSync(resolve(__dirname, "data/spotify-playlists-report.json"), JSON.stringify(report, null, 2));

let sql = `-- Generiert von db/scripts/build-spotify-playlists.mjs (${new Date().toISOString().slice(0, 10)})\n-- Playlists aus Spotify-Vorlagen (Hörproben von Spotify, Erscheinungsjahr von Deezer)\nBEGIN;\n\n`;
for (const p of result) {
    sql += `INSERT INTO public.topic_pool (text, active, is_song_category)\nSELECT ${q(p.name)}, true, true\nWHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = ${q(p.name)});\n\n`;
    if (!p.songs.length) continue;
    sql += `INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at, release_year)\nSELECT tp.id, v.title, v.artist, v.url, now(), v.year\nFROM (VALUES\n`;
    sql += p.songs.map((s) => `    (${q(s.title)}, ${q(s.artist)}, ${q(s.preview)}, ${s.year ?? "NULL::int"})`).join(",\n");
    sql += `\n) AS v(title, artist, url, year)\nJOIN public.topic_pool tp ON tp.text = ${q(p.name)}\nWHERE NOT EXISTS (\n  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)\n);\n\n`;
}
sql += "COMMIT;\n";
writeFileSync(out, sql);
console.log("SQL:", out);
