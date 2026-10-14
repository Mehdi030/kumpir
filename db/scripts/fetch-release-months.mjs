#!/usr/bin/env node
// Erscheinungsmonat für den Gleichstand-Entscheid in "Jahr raten" (Migration 126: song_pool.release_month).
// Sucht pro Song bei Deezer (öffentliche Suche) die exakten Treffer (Titel + erster Künstler) und nimmt von den
// Treffern, deren Jahr zum gespeicherten release_year passt, das früheste Veröffentlichungsdatum -> Monat.
// Songs ohne Treffer bleiben ohne Monat (dort gibt es dann einfach keinen Monats-Entscheid).
// Aufruf: node db/scripts/fetch-release-months.mjs [--all]   (ohne --all nur Songs ohne Monat)
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

async function getJson(url, tries = 3) {
    for (let a = 0; a < tries; a++) {
        try {
            const res = await fetch(url);
            if (res.ok) return await res.json();
        } catch {
            /* nochmal */
        }
        await sleep(1500 * (a + 1));
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
    `select id, title, artist, release_year from public.song_pool where archived_from is null and release_year is not null ${all ? "" : "and release_month is null"} order by artist, title`,
);
console.log(`${rows.length} Songs ohne Monat`);
let ok = 0;
let miss = 0;
for (const [i, s] of rows.entries()) {
    const firstArtist = String(s.artist).split(/\s*,\s*|\s*&\s*/)[0].trim();
    const res = await getJson(`https://api.deezer.com/search?q=${encodeURIComponent(`${firstArtist} ${s.title}`)}&limit=10`);
    await sleep(220);
    const hits = (res?.data ?? []).filter((r) => norm(r.title).includes(norm(s.title)) && norm(r.artist?.name ?? "").includes(norm(firstArtist)));
    let best = null;
    for (const h of hits.slice(0, 5)) {
        const d = await getJson(`https://api.deezer.com/track/${h.id}`);
        await sleep(220);
        const date = d?.release_date;
        if (!date || Number(date.slice(0, 4)) !== s.release_year) continue;
        if (best == null || date < best) best = date;
    }
    if (best) {
        await db.query("update public.song_pool set release_month = $2 where id = $1", [s.id, Number(best.slice(5, 7))]);
        ok++;
    } else miss++;
    if ((i + 1) % 25 === 0) console.log(`${i + 1}/${rows.length} · ${ok} Monate · ${miss} ohne Treffer`);
}
console.log(`Fertig: ${ok} Monate gesetzt, ${miss} ohne Treffer`);
await db.end();
