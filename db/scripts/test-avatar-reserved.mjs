#!/usr/bin/env node
/**
 * Testet Migration 119 (Kippa/Schläfenlocken nur für Valentino, Ziegenbart nur Achi) in EINER Transaktion mit ROLLBACK.
 *
 * Aufruf: node db/scripts/test-avatar-reserved.mjs
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { createTestUser } from "./_test-users.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.trim() && !l.trim().startsWith("#") && l.includes("="))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)])
);
const client = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});

let failed = 0;
const check = (name, ok, detail = "") => {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
};

await client.connect();
const q = async (sql, params) => (await client.query(sql, params)).rows;
let sp = 0;
/** Führt sql als eingeloggter Nutzer aus; liefert {rows} oder {error}. */
async function asUser(uid, sql, params) {
    const name = `s${++sp}`;
    await q(`savepoint ${name}`);
    try {
        await q("set local role authenticated");
        await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: uid, role: "authenticated" })]);
        const rows = await q(sql, params);
        await q("reset role");
        await q(`release savepoint ${name}`);
        return { rows };
    } catch (e) {
        await q(`rollback to savepoint ${name}`);
        await q("reset role");
        return { error: e.message };
    }
}

try {
    await q("begin");
    const other = await createTestUser(q, "tandere", "user");
    const val = await createTestUser(q, "tvalent", "user");
    // der echte Valentino wird in der Test-Transaktion umbenannt, damit der Testnutzer "valentino" heißen darf
    await q("update public.profiles set username = 'valentino-orig' where lower(username) = 'valentino'");
    await q("update public.profiles set username = 'valentino' where id = $1", [val]);

    for (const top of ["kippa", "kippaPayot"]) {
        let r = await asUser(other, "select public.update_my_avatar($1::jsonb)", [JSON.stringify({ top })]);
        check("Fremdes Konto darf " + top + " NICHT setzen", /avatar_reserved/.test(r.error ?? ""), r.error);
        r = await asUser(val, "select public.update_my_avatar($1::jsonb)", [JSON.stringify({ top, hatColor: "ffffff", hairColor: "2c1b18" })]);
        check("Valentino darf " + top + " setzen", !r.error, r.error);
        const [p] = await q("select avatar_config ->> 'top' t from public.profiles where id = $1", [val]);
        check("  gespeichert: " + top, p.t === top, p.t);
    }
    let r = await asUser(other, "select public.update_my_avatar($1::jsonb)", [JSON.stringify({ top: "sides", facialHair: "goatee" })]);
    check("Ziegenbart bleibt für Achi reserviert", /avatar_reserved/.test(r.error ?? ""), r.error);
    r = await asUser(other, "select public.update_my_avatar($1::jsonb)", [JSON.stringify({ top: "turban", hatColor: "ffffff" })]);
    check("Normale Wahl (Turban) geht für alle", !r.error, r.error);
    r = await asUser(other, "select public.update_my_avatar($1::jsonb)", [JSON.stringify({ top: "kippaX" })]);
    check("Unbekannter Wert abgelehnt", /avatar_invalid/.test(r.error ?? ""), r.error);
    // Direktes Schreiben am Profil umgeht die Prüfung nicht
    r = await asUser(other, "update public.profiles set avatar_config = '{\"top\":\"kippa\"}'::jsonb where id = $1", [other]);
    const [chk] = await q("select avatar_config ->> 'top' t from public.profiles where id = $1", [other]);
    check("Direkt am Profil schreiben bringt keine Kippa", chk.t !== "kippa", r.error ?? chk.t);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await client.end();
}

console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
