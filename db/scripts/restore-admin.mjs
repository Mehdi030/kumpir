#!/usr/bin/env node
/**
 * NOTFALL-ZUGANG für den Besitzer: funktioniert immer vom eigenen Laptop, unabhängig von der
 * Website, weil es direkt mit der Datenbank spricht (Zugangsdaten in db/.env.local – nur auf
 * deinem Rechner, nie in Git).
 *
 * Macht ein Konto wieder zum aktiven Admin: Rolle admin, Status aktiv, Login-Sperre aufheben,
 * Rate-Limits zurücksetzen. Optional: Link zum Passwort-Setzen per Mail (--reset-mail).
 *
 *   node db/scripts/restore-admin.mjs mehdi
 *   node db/scripts/restore-admin.mjs meine@mail.de --reset-mail
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const parse = (p) =>
    Object.fromEntries(
        readFileSync(p, "utf8")
            .split(/\r?\n/)
            .filter((l) => l.includes("=") && !l.trim().startsWith("#"))
            .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
    );
const env = parse(resolve(__dirname, "../.env.local"));
const who = process.argv[2];
if (!who) {
    console.log("Aufruf: node db/scripts/restore-admin.mjs <benutzername oder e-mail> [--reset-mail]");
    process.exit(1);
}

const db = new pg.Client({ host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres", user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
try {
    const { rows } = await db.query(
        "select u.id, u.email, p.username from auth.users u left join public.profiles p on p.id = u.id where lower(p.username) = lower($1) or lower(u.email) = lower($1) limit 1",
        [who]
    );
    if (!rows[0]) throw new Error("Kein Konto gefunden für: " + who);
    const u = rows[0];
    await db.query("begin");
    await db.query("update auth.users set banned_until = null where id = $1", [u.id]);
    await db.query("update public.profiles set role = 'admin', is_platform_admin = true, status = 'active', status_reason = null, deletion_requested_at = null, status_changed_at = now() where id = $1", [u.id]);
    await db.query("delete from public.rate_limits");
    // Das Protokoll schreibt der Datenbank-Trigger selbst (Migration 083: Rolle/Status per Skript → "Datenbank/Skript")
    await db.query("commit");
    console.log(`✅ ${u.username ?? u.email} ist wieder aktiver Admin, Login-Sperre aufgehoben, Rate-Limits zurückgesetzt.`);

    if (process.argv.includes("--reset-mail")) {
        const web = parse(resolve(__dirname, "../../apps/web/.env.local"));
        const r = await fetch(`${web.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/recover`, {
            method: "POST",
            headers: { apikey: web.NEXT_PUBLIC_SUPABASE_ANON_KEY, "Content-Type": "application/json" },
            body: JSON.stringify({ email: u.email }),
        });
        console.log(r.ok ? `📨 Passwort-Link an ${u.email} gesendet.` : `⚠️ Mail fehlgeschlagen (HTTP ${r.status}).`);
    }
} catch (e) {
    await db.query("rollback").catch(() => {});
    console.error("FEHLER:", e.message);
    process.exitCode = 1;
} finally {
    await db.end();
}
