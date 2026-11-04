#!/usr/bin/env node
/**
 * Fügt die handgepflegten Kernbegriffe (data/word-core.mjs) in data/word-lists.json ein, ohne den langen Wikidata-Lauf:
 *   Länder, Städte (+ alle Hauptstädte), Tiere, Obst & Gemüse, Fußballspieler.
 * Vorhandene Begriffe behalten ihre Schreibweisen und bekommen die neuen dazu; neue Begriffe kommen mit Gewicht 300 (bekannt) dazu.
 * Danach laden: node db/scripts/load-word-lists.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { keysOf, hand, norm } from "./lib/wordkeys.mjs";
import { CORE_LAENDER, CORE_STAEDTE, CORE_TIERE, CORE_OBST, CORE_FUSSBALL } from "./data/word-core.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const file = resolve(__dirname, "data/word-lists.json");
const lists = JSON.parse(readFileSync(file, "utf8"));

function merge(cat, entries, kind) {
    const L = (lists[cat] ??= { kind, terms: [] });
    const byKey = new Map();
    for (const t of L.terms) byKey.set(norm(t.label), t);
    let added = 0, extended = 0;
    for (const e of entries) {
        const k = norm(e.label);
        if (!k) continue;
        const keys = keysOf(e.label, L.kind ?? kind, e.aliases);
        const old = byKey.get(k);
        if (old) {
            const set = new Set(old.keys);
            const before = set.size;
            for (const x of keys) set.add(x);
            old.keys = [...set];
            old.w = Math.max(old.w ?? 0, e.w);
            if (set.size > before) extended++;
        } else {
            const t = { label: e.label, w: e.w, keys };
            L.terms.push(t);
            byKey.set(k, t);
            added++;
        }
    }
    console.log(`${cat}: +${added} neu, ${extended} erweitert, jetzt ${L.terms.length}`);
}

merge("Länder", hand(CORE_LAENDER, 300), "thing");
merge("Städte", [...hand(CORE_STAEDTE, 300), ...(lists["Hauptstädte"]?.terms ?? []).map((t) => ({ label: t.label, w: 300, aliases: [] }))], "thing");
merge("Tiere", hand(CORE_TIERE, 300), "thing");
merge("Obst & Gemüse", hand(CORE_OBST, 300), "thing");
merge("Fußballspieler", hand(CORE_FUSSBALL, 300), "person");
writeFileSync(file, JSON.stringify(lists));
