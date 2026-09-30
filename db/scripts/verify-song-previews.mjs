#!/usr/bin/env node
/**
 * Prüft JEDE aktuell gespeicherte song_pool.preview_url live per HTTP
 * darauf, ob sie gerade wirklich abspielbar ist (200 + audio-Content-Type).
 * iTunes-Preview-URLs laufen erfahrungsgemäß irgendwann ab/brechen --
 * anders als beim Erstbefüllen (backfill-song-previews.mjs, das nur prüft
 * ob es EINEN Treffer gibt) geht es hier darum, tote Links zu finden, die
 * initial funktioniert haben, aber inzwischen nicht mehr laden.
 *
 * Songs mit einer toten URL werden -- genau wie schon Songs ganz ohne
 * preview_url (Migration 050) -- komplett aus song_pool entfernt, damit
 * _pick_next_song sie nie mehr ziehen kann.
 *
 * Aufruf:
 *   node db/scripts/verify-song-previews.mjs            # nur prüfen (dry-run)
 *   node db/scripts/verify-song-previews.mjs --delete   # tote Songs wirklich löschen
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dbDir = resolve(__dirname, "..");
const doDelete = process.argv.includes("--delete");

function parseEnv(text) {
    const map = {};
    for (const line of text.split(/\r?\n/)) {
        if (!line.trim() || line.trim().startsWith("#")) continue;
        const i = line.indexOf("=");
        if (i < 0) continue;
        map[line.slice(0, i).trim()] = line.slice(i + 1);
    }
    return map;
}

const env = parseEnv(readFileSync(resolve(dbDir, ".env.local"), "utf8"));
const client = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function isPlayable(url) {
    try {
        const controller = new AbortController();
        const t = setTimeout(() => controller.abort(), 8000);
        const res = await fetch(url, { method: "GET", headers: { Range: "bytes=0-2047" }, signal: controller.signal });
        clearTimeout(t);
        if (!res.ok && res.status !== 206) return false;
        const ct = res.headers.get("content-type") || "";
        if (!ct.startsWith("audio/") && !ct.includes("mp4") && !ct.includes("aac")) return false;
        // Body tatsächlich antasten, damit ein Server, der nur Header
        // vortäuscht, trotzdem auffliegt.
        const buf = await res.arrayBuffer();
        return buf.byteLength > 0;
    } catch {
        return false;
    }
}

await client.connect();
const { rows } = await client.query(
    "select id, title, artist, preview_url from song_pool where preview_url is not null order by title"
);

console.log(`Prüfe ${rows.length} Songs ...`);
const dead = [];
let i = 0;
for (const row of rows) {
    i++;
    const ok = await isPlayable(row.preview_url);
    if (!ok) {
        dead.push(row);
        console.log(`[${i}/${rows.length}] ❌ TOT: ${row.title} — ${row.artist}`);
    } else {
        console.log(`[${i}/${rows.length}] ✅ ${row.title}`);
    }
    await sleep(120);
}

console.log(`\n${dead.length} von ${rows.length} Songs tot.`);
if (dead.length > 0) {
    console.log(dead.map((d) => `  - ${d.title} (${d.artist})`).join("\n"));
}

if (doDelete && dead.length > 0) {
    const ids = dead.map((d) => d.id);
    await client.query("update public.lobbies set current_song_id = null where current_song_id = any($1::uuid[])", [ids]);
    await client.query("delete from public.song_pool where id = any($1::uuid[])", [ids]);
    console.log(`\n✅ ${dead.length} tote Songs gelöscht.`);
} else if (dead.length > 0) {
    console.log("\n(Dry-run -- mit --delete erneut aufrufen, um die toten Songs wirklich zu löschen.)");
}

await client.end();
