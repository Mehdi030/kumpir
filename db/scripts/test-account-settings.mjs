#!/usr/bin/env node
/**
 * Testet Migration 077 (Konto-Einstellungen + Sicherheitsfix) in EINER Transaktion,
 * die am Ende zurückgerollt wird – es bleibt nichts in der Datenbank.
 *
 * Aufruf: node db/scripts/test-account-settings.mjs
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

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
    const [user] = await q("select id from public.profiles where username = 'claudetest'");
    const [admin] = await q("select id, username from public.profiles where coalesce(is_platform_admin, false) limit 1");
    if (!user || !admin) throw new Error("Testkonten fehlen");

    // Sicherheit: direkte Änderung am Profil ist gesperrt
    let r = await asUser(user.id, "update public.profiles set is_platform_admin = true where id = $1", [user.id]);
    check("Selbst zum Admin machen ist gesperrt", !!r.error && /permission denied/i.test(r.error), r.error);
    r = await asUser(user.id, "update public.profiles set username = 'hacker' where id = $1", [user.id]);
    check("Username direkt ändern ist gesperrt", !!r.error);

    // Username
    r = await asUser(user.id, "select public.set_my_username('A!')");
    check("Ungültiger Username abgelehnt", /username_invalid/.test(r.error ?? ""), r.error);
    r = await asUser(user.id, "select public.set_my_username($1)", [admin.username.toUpperCase()]);
    check("Vergebener Username (andere Schreibweise) abgelehnt", /username_taken/.test(r.error ?? ""), r.error);
    r = await asUser(user.id, "select public.set_my_username('  Claude.Test_2 ') as u");
    check("Username geändert + normalisiert", r.rows?.[0]?.u === "claude.test_2", JSON.stringify(r.rows ?? r.error));
    r = await asUser(user.id, "select public.is_username_available('claude.test_2') as mine, public.is_username_available($1) as other", [admin.username]);
    check("Verfügbarkeit: eigener Name frei, fremder belegt", r.rows?.[0]?.mine === true && r.rows?.[0]?.other === false);

    // Profil
    r = await asUser(user.id, "select public.update_my_profile('Claudia', '🦊', '#FF8800')");
    check("Spielername + Avatar gespeichert", !r.error, r.error);
    r = await asUser(user.id, "select public.update_my_profile('x1', null, null)");
    check("Spielername mit Ziffer abgelehnt", /display_name_invalid/.test(r.error ?? ""), r.error);
    r = await asUser(user.id, "select public.update_my_profile('Claudia', 'abc', null)");
    check("Avatar aus Buchstaben abgelehnt", /avatar_invalid/.test(r.error ?? ""), r.error);

    // Vorlieben: nur gültige Werte bleiben
    r = await asUser(
        user.id,
        `select public.set_my_preferences('{"lang":"en","muted":true,"volume":0.5,"evil":"x","host":{"maxPlayers":20,"speed":"fast","rounds":3,"answerMode":"voice"},"solo":{"bots":4,"skill":"2"}}'::jsonb) as p`
    );
    const prefs = r.rows?.[0]?.p;
    check(
        "Vorlieben gefiltert",
        prefs && prefs.lang === "en" && prefs.muted === true && !("evil" in prefs) && prefs.host.speed === "fast" && !("maxPlayers" in prefs.host) && prefs.host.rounds === 3 && prefs.solo.bots === 4,
        JSON.stringify(prefs ?? r.error)
    );

    r = await asUser(user.id, "select public.get_my_settings() as s");
    const s = r.rows?.[0]?.s;
    check("get_my_settings liefert alles", s && s.username === "claude.test_2" && s.displayName === "Claudia" && s.avatarEmoji === "🦊" && s.avatarColor === "#ff8800" && s.preferences.lang === "en", JSON.stringify(s ?? r.error));

    // Öffentlich lesbar: Avatar ja, Vorlieben/E-Mail nein
    r = await asUser(user.id, "select avatar_emoji from public.profiles where id = $1", [user.id]);
    check("Avatar öffentlich lesbar", r.rows?.[0]?.avatar_emoji === "🦊");
    r = await asUser(user.id, "select preferences from public.profiles where id = $1", [user.id]);
    check("Vorlieben NICHT direkt lesbar", !!r.error, r.error);

    // Login per Username funktioniert mit neuem Namen (Server-Lookup)
    const [mail] = await q("select public.get_email_for_username('Claude.Test_2') as e");
    check("Login-Lookup findet neuen Username", !!mail.e);

    // Anonyme Nutzer dürfen keine Einstellungen aufrufen
    await q("savepoint anon1");
    let anonBlocked = false;
    try {
        await q("set local role anon");
        await q("select public.get_my_settings()");
    } catch (e) {
        anonBlocked = /permission denied/i.test(e.message);
    }
    await q("rollback to savepoint anon1");
    await q("reset role");
    check("Gäste können Einstellungen nicht aufrufen", anonBlocked);

    // Konto löschen
    r = await asUser(admin.id, "select public.delete_my_account()");
    check("Admin-Konto kann sich nicht versehentlich löschen", /admin_cannot_delete/.test(r.error ?? ""), r.error);
    r = await asUser(user.id, "select public.delete_my_account()");
    const [gone] = await q("select (select count(*) from auth.users where id = $1)::int u, (select count(*) from public.profiles where id = $1)::int p", [user.id]);
    check("Konto löschen entfernt Auth-Nutzer + Profil", !r.error && gone.u === 0 && gone.p === 0, r.error ?? JSON.stringify(gone));

    // Profil-Trigger-Regeln
    const [v] = await q("select public._valid_username('ab') a, public._valid_username('medo_99') b, public._valid_display_name('Sinan') c, public._valid_display_name('Sinan2') d, public._is_profane('xwichserx') e");
    check("Prüfregeln (Username/Spielername/Schimpfwort)", !v.a && v.b && v.c && !v.d && v.e);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await client.end();
}

console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
