#!/usr/bin/env node
/**
 * Lädt db/scripts/data/word-lists.json (gebaut mit build-word-lists.mjs) in die Tabellen word_categories / word_terms
 * (Migration 127). Bestehende Begriffe der geladenen Kategorien werden ersetzt; Kategorien, die nicht in der Datei
 * stehen, bleiben unberührt. Normalisiert wird in der Datenbank (public._ans_norm), damit Suche und Liste dasselbe nutzen.
 * Aufruf: node db/scripts/load-word-lists.mjs
 */
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
const lists = JSON.parse(readFileSync(resolve(__dirname, "data/word-lists.json"), "utf8"));
const db = new pg.Client({
    host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false },
});
await db.connect();
await db.query("begin");
try {
    for (const [name, v] of Object.entries(lists)) {
        const { rows } = await db.query(
            "insert into public.word_categories (name, kind) values ($1, $2) on conflict (name) do update set kind = excluded.kind, active = true returning id",
            [name, v.kind],
        );
        const id = rows[0].id;
        await db.query("delete from public.word_terms where category_id = $1", [id]);
        const labels = [];
        const keys = [];
        for (const t of v.terms) for (const k of t.keys) { labels.push(t.label); keys.push(k); }
        for (let i = 0; i < labels.length; i += 2000) {
            await db.query(
                `insert into public.word_terms (category_id, label, key_norm, initial)
                 select $1, x.label, x.n, left(x.n, 1) from (select t.label, public._ans_norm(t.k) as n from unnest($2::text[], $3::text[]) as t(label, k)) x
                 where x.n ~ '^[a-z]' and length(x.n) >= 2
                 on conflict do nothing`,
                [id, labels.slice(i, i + 2000), keys.slice(i, i + 2000)],
            );
        }
        const [{ n, l }] = (await db.query("select count(*)::int n, count(distinct label)::int l from public.word_terms where category_id = $1", [id])).rows;
        console.log(`${name}: ${l} Begriffe (${n} Schreibweisen)`);
    }
    await db.query("commit");
} catch (e) {
    await db.query("rollback");
    console.error("FEHLER:", e.message);
    process.exitCode = 1;
}
await db.end();
