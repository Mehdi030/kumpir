// Sammelt alle Emojis, die in der App vorkommen (Quellcode + Datenbank-Texte) -> db/scripts/data/emoji-used.json
//   node db/scripts/emoji-collect.mjs
import { readFileSync, writeFileSync, readdirSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import pg from "pg";

// Emoji-Folgen: Bildzeichen (+ Variation/Hautton/ZWJ-Kette), Flaggen, Tastenkappen
const RE = /(?:\p{Extended_Pictographic}(?:️|[\u{1F3FB}-\u{1F3FF}])?(?:‍\p{Extended_Pictographic}(?:️|[\u{1F3FB}-\u{1F3FF}])?)*)|[\u{1F1E6}-\u{1F1FF}]{2}|[0-9#*]️?⃣/gu;
const counts = new Map();
const add = (s, where) => {
    for (const m of String(s ?? "").matchAll(RE)) {
        const e = m[0];
        const o = counts.get(e) ?? { n: 0, where: new Set() };
        o.n++;
        o.where.add(where);
        counts.set(e, o);
    }
};

(function walk(d) {
    for (const f of readdirSync(d, { withFileTypes: true })) {
        const p = join(d, f.name);
        if (f.isDirectory()) {
            if (!["node_modules", ".next"].includes(f.name)) walk(p);
        } else if (/\.(tsx?|css|json|md)$/.test(f.name) && !/\.test\./.test(f.name)) add(readFileSync(p, "utf8"), "code");
    }
})("apps/web/src");

const env = Object.fromEntries(readFileSync("db/.env.local", "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]));
const db = new pg.Client({ host: env.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
// alle Text-Spalten im public-Schema (außer riesige Protokolle) nach Emojis durchsuchen
const cols = (await db.query(`select table_name, column_name from information_schema.columns where table_schema='public' and data_type in ('text','character varying') and table_name not in ('game_events','funnel_events','admin_audit','rate_limits','song_pool') and table_name in (select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE')`)).rows;
for (const { table_name: t, column_name: c } of cols) {
    const r = await db.query(`select distinct "${c}" v from public."${t}" where "${c}" ~ '[^\\x01-\\x7F äöüÄÖÜß]' limit 2000`).catch(() => ({ rows: [] }));
    for (const row of r.rows) add(row.v, `db:${t}.${c}`);
}
await db.end();

// Text-Symbole ohne Emoji-Darstellung (★ ♪ ✖ ℹ …) sind keine Emojis im engeren Sinn – trotzdem mitführen, falls die Sammlung sie hat
const list = [...counts.entries()].map(([e, o]) => ({ emoji: e, cps: [...e].map((c) => c.codePointAt(0).toString(16).toUpperCase()), uses: o.n, where: [...o.where] }));
list.sort((a, b) => b.uses - a.uses);
mkdirSync("db/scripts/data", { recursive: true });
writeFileSync("db/scripts/data/emoji-used.json", JSON.stringify(list, null, 1));
console.log(`${list.length} verschiedene Emojis; aus der Datenbank: ${list.filter((x) => x.where.some((w) => w.startsWith("db:"))).map((x) => x.emoji).join(" ") || "–"}`);
