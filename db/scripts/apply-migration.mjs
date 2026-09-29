#!/usr/bin/env node
/**
 * Wendet eine SQL-Datei direkt gegen die Supabase-Postgres-DB an --
 * ersetzt das manuelle Copy-Paste einer Migration in den Supabase SQL
 * Editor. Nutzt db/.env.local (getrennt von apps/web/.env.local, das nur
 * den public anon-Key enthält -- dieses Passwort darf niemals in den
 * Next.js-Build wandern).
 *
 * Aufruf:
 *   node db/scripts/apply-migration.mjs <pfad-zur-sql-datei>
 *   node db/scripts/apply-migration.mjs                        # default: _apply_all.sql
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dbDir = resolve(__dirname, "..");

function parseEnv(text) {
    const map = {};
    for (const raw of text.split(/\r?\n/)) {
        const line = raw;
        if (!line.trim() || line.trim().startsWith("#")) continue;
        const i = line.indexOf("=");
        if (i < 0) continue;
        map[line.slice(0, i).trim()] = line.slice(i + 1);
    }
    return map;
}

const env = parseEnv(readFileSync(resolve(dbDir, ".env.local"), "utf8"));

const sqlPath = resolve(process.cwd(), process.argv[2] || resolve(dbDir, "migrations", "_apply_all.sql"));
const sql = readFileSync(sqlPath, "utf8");

const client = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});

console.log(`Verbinde mit ${env.SUPABASE_DB_HOST} ...`);
await client.connect();

console.log(`Wende an: ${sqlPath}`);
try {
    await client.query(sql);
    console.log("✅ Erfolgreich angewendet.");
} catch (e) {
    console.error("❌ Fehler:", e.message);
    process.exitCode = 1;
} finally {
    await client.end();
}
