#!/usr/bin/env node
/**
 * Prüft Kandidaten aus data/new-playlists.json gegen die iTunes-Suche
 * (Titel + Interpret müssen passen, previewUrl muss existieren) und
 * schreibt die verifizierten Songs als Migration-SQL.
 * Aufruf: node db/scripts/build-playlists.mjs <out.sql>
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(readFileSync(resolve(__dirname, "data/new-playlists.json"), "utf8"));
const out = process.argv[2];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const norm = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\(.*?\)|\[.*?\]/g, " ").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
const q = (s) => "'" + s.replace(/'/g, "''") + "'";

function parseEnv(t) { const m = {}; for (const l of t.split(/\r?\n/)) { if (!l.trim() || l.startsWith("#")) continue; const i = l.indexOf("="); if (i > 0) m[l.slice(0, i).trim()] = l.slice(i + 1); } return m; }
const env = parseEnv(readFileSync(resolve(__dirname, "../.env.local"), "utf8"));
const client = new pg.Client({ host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres", user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await client.connect();
const existing = new Set((await client.query("select lower_title t from song_pool")).rows.map((r) => norm(r.t ?? "")));
const existingRaw = (await client.query("select title from song_pool")).rows.map((r) => norm(r.title));
await client.end();
const seen = new Set([...existing, ...existingRaw]);

async function lookup(title, artist) {
    for (let a = 0; a < 3; a++) {
        const res = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(title + " " + artist)}&media=music&entity=song&country=DE&limit=8`);
        if (res.ok) { const t = await res.text(); return t ? JSON.parse(t).results ?? [] : []; }
        await sleep(6000);
    }
    return null;
}

const rows = [];
const report = [];
for (const [topic, songs] of Object.entries(data)) {
    let ok = 0;
    for (const [title, artist] of songs) {
        const nt = norm(title);
        if (seen.has(nt)) { report.push(`DUP    ${topic}: ${title}`); continue; }
        const res = await lookup(title, artist);
        await sleep(1500);
        if (!res) { report.push(`ERR    ${topic}: ${title}`); continue; }
        const artTokens = norm(artist).split(" ").filter((t) => t.length > 2);
        const hit = res.find((r) => r.previewUrl && (norm(r.trackName) === nt || norm(r.trackName).startsWith(nt) || nt.startsWith(norm(r.trackName))) && artTokens.some((t) => norm(r.artistName).includes(t)));
        if (!hit) { report.push(`MISS   ${topic}: ${title} — ${artist}`); continue; }
        seen.add(nt);
        ok++;
        rows.push({ topic, title, artist, url: hit.previewUrl });
    }
    report.push(`== ${topic}: ${ok} verifiziert`);
}
console.log(report.join("\n"));
const byTopic = {};
for (const r of rows) (byTopic[r.topic] ??= []).push(r);
let sql = `-- Generiert von db/scripts/build-playlists.mjs (iTunes-verifiziert: Titel+Interpret+Preview)\nBEGIN;\n`;
for (const t of Object.keys(byTopic)) {
    sql += `\nINSERT INTO public.topic_pool (text, active, is_song_category)\nSELECT ${q(t)}, true, true\nWHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = ${q(t)});\n`;
    sql += `\nINSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)\nSELECT tp.id, v.title, v.artist, v.url, now()\nFROM (VALUES\n` + byTopic[t].map((r) => `    (${q(r.topic)}, ${q(r.title)}, ${q(r.artist)}, ${q(r.url)})`).join(",\n") + `\n) AS v(topic, title, artist, url)\nJOIN public.topic_pool tp ON tp.text = v.topic;\n`;
}
sql += `\nCOMMIT;\n`;
writeFileSync(out, sql);
