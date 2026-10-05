#!/usr/bin/env node
/**
 * Prüft für JEDEN Song, ob die gespeicherte preview_url wirklich zu Titel + Interpret gehört
 * (iTunes-Suche muss einen Treffer liefern, dessen previewUrl identisch ist und dessen
 * Titel zum gespeicherten Titel passt). Gibt verdächtige Songs aus; --delete löscht sie.
 */
import { readFileSync } from "node:fs";
import pg from "pg";
const env = Object.fromEntries(readFileSync(new URL("../.env.local", import.meta.url), "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]));
const c = new pg.Client({ host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: "postgres", user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await c.connect();
const norm = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\(.*?\)|\[.*?\]/g, " ").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const songs = (await c.query("select s.id, s.title, s.artist, s.preview_url, tp.text topic from song_pool s join topic_pool tp on tp.id=s.topic_pool_id order by tp.text, s.title")).rows;
const bad = [];
let i = 0;
for (const s of songs) {
    i++;
    let res = null;
    for (let a = 0; a < 3 && !res; a++) {
        const r = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(s.title + " " + s.artist)}&media=music&entity=song&country=DE&limit=15`);
        if (r.ok) { const t = await r.text(); res = t ? JSON.parse(t).results ?? [] : []; } else await sleep(6000);
    }
    await sleep(1200);
    if (!res) { bad.push({ ...s, why: "iTunes-Fehler" }); continue; }
    const hit = res.find((r) => r.previewUrl === s.preview_url);
    const nt = norm(s.title);
    if (!hit) { bad.push({ ...s, why: "Preview-URL nicht (mehr) bei iTunes auffindbar" }); continue; }
    const hn = norm(hit.trackName);
    if (!(hn === nt || hn.startsWith(nt) || nt.startsWith(hn) || hn.includes(nt) || nt.includes(hn))) bad.push({ ...s, why: `Preview gehört zu "${hit.trackName}" (${hit.artistName})` });
    if (i % 40 === 0) console.error(`${i}/${songs.length}`);
}
console.log(JSON.stringify(bad.map((b) => ({ id: b.id, topic: b.topic, title: b.title, artist: b.artist, why: b.why })), null, 1));
if (process.argv.includes("--delete") && bad.length) {
    await c.query("delete from song_pool where id = any($1)", [bad.map((b) => b.id)]);
    console.error("gelöscht:", bad.length);
}
await c.end();
