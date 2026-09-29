#!/usr/bin/env node
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
const [table, grantee] = process.argv.slice(2);

const client = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});
await client.connect();
const res = await client.query(
    `select grantee, column_name, privilege_type
     from information_schema.column_privileges
     where table_schema='public' and table_name=$1 and grantee=$2
     order by column_name`,
    [table, grantee]
);
for (const r of res.rows) console.log(`${r.column_name}: ${r.privilege_type}`);
await client.end();
