#!/usr/bin/env node
/**
 * Zählt pro Rapper, wie viele Songs bei iTunes (Land DE) mit 30-Sekunden-Hörprobe zu haben sind
 * (= im Spiel nutzbar). Eine Suche pro Rapper (iTunes liefert höchstens 200 Treffer -> "200+" heißt: gedeckelt).
 * Gezählt werden eindeutige Titel ohne Remix/Live/Instrumental/Intro/Skit; "lead" = Rapper steht an erster Stelle.
 *
 * Aufruf: node db/scripts/count-rapper-songs.mjs "KC Rebell" "Summer Cem" ...   (ohne Namen: Standardliste unten)
 * Bericht: db/scripts/data/rapper-counts.json
 */
import { writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
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
const cleanTitle = (t) =>
    t
        .replace(/\s*[([](feat\.?|ft\.?|prod\.?|with|mit|featuring)\b[^)\]]*[)\]]/gi, "")
        .replace(/\s+(feat\.?|ft\.?|featuring)\s.+$/i, "")
        .replace(/\s+-\s+(single|ep)$/i, "")
        .trim();
const BAD = /(remix|rmx|\blive\b|instrumental|a ?cappella|sped ?up|slowed|nightcore|karaoke|\bintro\b|\boutro\b|\bskit\b|interlude|\bedit\b)/i;
const credits = (a) => (a ?? "").split(/\s*,\s*|\s*&\s*|\s+feat\.?\s+|\s+x\s+|\s+und\s+/i).map(norm);

const DEFAULT = [
    "KC Rebell", "Summer Cem", "Kollegah", "Farid Bang", "Bushido", "Sido", "Fler", "Massiv", "Eko Fresh", "Kool Savas",
    "Azad", "Haftbefehl", "Capital Bra", "Samra", "Mero", "Animus", "Majoe", "Hanybal", "Celo & Abdi", "Ali Bumaye",
    "Shindy", "Casper", "Marteria", "Cro", "Prinz Pi", "Samy Deluxe", "Olexesh", "Nimo", "Ufo361", "Gzuz",
    "Bonez MC", "RAF Camora", "Azet", "Zuna", "Mois", "Dardan", "Eno", "Luciano", "Apache 207", "Kontra K",
    "Jamule", "Veysel", "LX", "Maxwell", "Ssio", "Fard", "Genetikk", "Sonny Black", "Frank White", "Toni der Assi",
    "Bass Sultan Hengzt", "Jalil", "Gringo", "Hamad 45", "Reezy", "Miami Yacine", "Trettmann", "Nura", "Sero El Mero", "Ardian Bujupi",
    "Disarstar", "Content", "Pa Sports", "18 Karat", "Lil Lano", "Loredana", "Shirin David", "SSIO", "Alpa Gun", "Bozza",
];
const names = process.argv.slice(2).length ? process.argv.slice(2) : DEFAULT;

const rows = [];
for (const rapper of names) {
    let res = null;
    for (let a = 0; a < 4 && !res; a++) {
        try {
            const r = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(rapper)}&entity=song&attribute=artistTerm&country=DE&limit=200`);
            if (r.ok) res = await r.json();
        } catch {
            /* nochmal */
        }
        if (!res) await sleep(6000 * (a + 1));
    }
    await sleep(3500);
    const items = (res?.results ?? []).filter((r) => r.previewUrl && credits(r.artistName).includes(norm(rapper)) && !BAD.test(r.trackName ?? ""));
    const seen = new Map();
    for (const r of items) {
        const k = norm(cleanTitle(r.trackName ?? ""));
        if (k && !seen.has(k)) seen.set(k, r);
    }
    const lead = [...seen.values()].filter((r) => credits(r.artistName)[0] === norm(rapper)).length;
    const capped = (res?.resultCount ?? 0) >= 200;
    rows.push({ rapper, usable: seen.size, lead, capped, found: res ? res.resultCount : -1 });
    process.stdout.write(`${rapper}: ${seen.size} nutzbar (${lead} als Hauptkünstler)${capped ? " [Limit 200]" : ""}\n`);
}
rows.sort((a, b) => b.usable - a.usable);
writeFileSync(resolve(__dirname, "data/rapper-counts.json"), JSON.stringify(rows, null, 2));
console.log("\n>50 Songs:", rows.filter((r) => r.usable > 50).map((r) => `${r.rapper} ${r.usable}${r.capped ? "+" : ""}`).join(", "));
