#!/usr/bin/env node
/**
 * Schnell-Aktualisierung der HANDGEPFLEGTEN Roulette-Kategorien in data/word-lists.json (ohne den langen Wikidata-Lauf):
 * entfernt Kategorien, die nicht zum Allgemeinwissen gehören (Flüsse, Rapper), und fügt die Allgemeinwissen-Listen
 * aus data/word-general.mjs hinzu. Danach laden: node db/scripts/load-word-lists.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { keysOf, hand, norm } from "./lib/wordkeys.mjs";
import { GENERAL } from "./data/word-general.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const file = resolve(__dirname, "data/word-lists.json");
const lists = JSON.parse(readFileSync(file, "utf8"));
for (const drop of ["Flüsse", "Rapper"]) delete lists[drop];
for (const [name, list] of Object.entries(GENERAL)) {
    const seen = new Map();
    for (const it of hand(list, 80)) {
        const k = norm(it.label);
        if (k && !seen.has(k)) seen.set(k, it);
    }
    lists[name] = { kind: name === "Vornamen" ? "thing" : "thing", terms: [...seen.values()].map((t) => ({ label: t.label, w: t.w, keys: keysOf(t.label, "thing", t.aliases) })).filter((t) => t.keys.length) };
    console.log(`${name}: ${lists[name].terms.length} Begriffe`);
}
writeFileSync(file, JSON.stringify(lists));
console.log("Kategorien:", Object.keys(lists).join(", "));
