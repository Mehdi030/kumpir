#!/usr/bin/env node
// Erscheinungsjahre für "Jahr raten" (Migration 108: song_pool.release_year) von iTunes holen.
// Sucht pro Song "Titel Künstler" im deutschen iTunes-Store und nimmt den Treffer mit DERSELBEN Hörprobe
// (preview_url) – sonst den Treffer mit gleichem Titel und Künstler. iTunes erlaubt ~20 Anfragen/Minute.
// Aufruf: node db/scripts/fetch-release-years.mjs [--all]   (ohne --all nur Songs ohne Jahr)
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.trim().startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]),
);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const norm = (s) => String(s ?? "").toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/\(.*?\)|\[.*?\]/g, "").replace(/[^a-z0-9äöüß]+/g, " ").trim();

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
        await sleep(6000 * (a + 1));
    }
    return null;
}

const db = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});
await db.connect();
const all = process.argv.includes("--all");
const { rows } = await db.query(
    `select id, title, artist, preview_url from public.song_pool where archived_from is null ${all ? "" : "and release_year is null"} order by artist, title`,
);
console.log(`${rows.length} Songs ohne Jahr`);
let ok = 0, miss = 0;
for (const [i, s] of rows.entries()) {
    const firstArtist = String(s.artist).split(/,|&| feat\.? | x /i)[0].trim();
    const res = await getJson(`https://itunes.apple.com/search?term=${encodeURIComponent(`${s.title} ${firstArtist}`)}&media=music&entity=song&country=DE&limit=15`);
    await sleep(3300);
    const items = res?.results ?? [];
    const byPreview = items.find((t) => t.previewUrl && s.preview_url && t.previewUrl === s.preview_url);
    const byName = items.find((t) => norm(t.trackName) === norm(s.title) && norm(t.artistName).includes(norm(firstArtist)));
    const hit = byPreview ?? byName;
    const year = hit?.releaseDate ? Number(String(hit.releaseDate).slice(0, 4)) : null;
    if (year && year >= 1950 && year <= new Date().getFullYear() + 1) {
        await db.query("update public.song_pool set release_year = $2 where id = $1", [s.id, year]);
        ok++;
    } else miss++;
    if ((i + 1) % 20 === 0) console.log(`${i + 1}/${rows.length} · ${ok} Jahre · ${miss} ohne Treffer`);
}
console.log(`Fertig: ${ok} Jahre gesetzt, ${miss} ohne Treffer`);
await db.end();
