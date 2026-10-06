#!/usr/bin/env node
/**
 * Testet Migration 083 (Protokoll ohne Ausnahmen) in EINER Transaktion, die zurückgerollt wird.
 * Aufruf: node db/scripts/test-audit-log.mjs
 */
import { readFileSync } from "node:fs";
import pg from "pg";
import { createTestUser } from "./_test-users.mjs";

const env = Object.fromEntries(readFileSync("db/.env.local", "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]));
const c = new pg.Client({ host: env.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (s, p) => (await c.query(s, p)).rows;
let failed = 0;
const check = (n, ok, d = "") => {
    console.log(`${ok ? "✅" : "❌"} ${n}${d ? "  – " + d : ""}`);
    if (!ok) failed++;
};
let sp = 0;
async function as(uid, sql, params) {
    const name = `s${++sp}`;
    await q(`savepoint ${name}`);
    try {
        await q("set local role authenticated");
        await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: uid, role: "authenticated" })]);
        const rows = await q(sql, params);
        await q("reset role");
        await q("select set_config('request.jwt.claims', '', true)");
        await q(`release savepoint ${name}`);
        return { rows };
    } catch (e) {
        await q(`rollback to savepoint ${name}`);
        await q("reset role");
        return { error: e.message };
    }
}
const log = async (where, p = []) => q(`select action, actor_name, target_label, details from admin_audit where ${where} order by id`, p);
const blockedBy = async (name, sql) => {
    await q(`savepoint ${name}`);
    let blocked = false;
    try {
        await q(sql);
    } catch (e) {
        blocked = /audit_immutable/.test(e.message);
    }
    await q(`rollback to savepoint ${name}`);
    return blocked;
};

try {
    await q("begin");
    const user = await createTestUser(q, "auduser", "user");
    const admin = await createTestUser(q, "audadmin", "admin");

    let rows = await log("target_id = $1", [user]);
    check("Konto angelegt wird protokolliert", rows.some((r) => r.action === "account_created" && r.target_label === "auduser"), rows.map((r) => r.action).join(","));

    // Spieler ändert sich selbst
    let r = await as(user, "select public.update_my_profile('Sinan', '🎧', '#ff0000')");
    check("Spieler ändert Anzeigename/Avatar", !r.error, r.error);
    r = await as(user, "select public.set_my_username('audneu')");
    check("Spieler ändert Benutzernamen", !r.error, r.error);
    r = await as(user, `select public.set_my_preferences('{"muted":true,"lang":"en"}'::jsonb)`);
    check("Spieler ändert Einstellungen", !r.error, r.error);
    rows = await log("target_id = $1", [user]);
    const acts = rows.map((x) => x.action);
    check("Anzeigename, Avatar, Benutzername, Einstellungen im Protokoll", ["display_name_changed", "avatar_changed", "username_changed", "preferences_changed"].every((a) => acts.includes(a)), acts.join(","));
    const un = rows.find((x) => x.action === "username_changed");
    check("Eintrag zeigt alt → neu und wer es war", un?.details?.from === "auduser" && un?.details?.to === "audneu" && un?.actor_name === "audneu", JSON.stringify(un));

    // Passwort
    await q("update auth.users set encrypted_password = 'x' || md5(random()::text) where id = $1", [user]);
    rows = await log("target_id = $1 and action = 'password_changed'", [user]);
    check("Passwortänderung wird protokolliert (ohne Passwort)", rows.length === 1 && rows[0].details === null);

    // Rolle per Skript/SQL
    await q("update public.profiles set role = 'supporter' where id = $1", [user]);
    rows = await log("target_id = $1 and action = 'role_changed'", [user]);
    check("Rolle per Datenbank/Skript wird protokolliert", rows.length === 1 && rows[0].details?.to === "supporter");

    // Admin über Funktion: genau EIN Eintrag (kein Doppel durch Trigger)
    r = await as(admin, "select public.admin_set_role($1, 'user')", [user]);
    rows = await log("target_id = $1 and action = 'role_changed'", [user]);
    check("Rolle über Admin-Funktion: genau ein zusätzlicher Eintrag mit Namen", !r.error && rows.length === 2 && rows[1].actor_name === "audadmin", r.error ?? String(rows.length));
    r = await as(admin, "select public.admin_update_user_profile($1, 'audmod', false, false)", [user]);
    rows = await log("target_id = $1 and action in ('profile_moderated','username_changed')", [user]);
    check(
        "Admin ändert Namen: ein Eintrag 'profile_moderated', kein Doppel",
        !r.error && rows.filter((x) => x.action === "profile_moderated").length === 1 && rows.filter((x) => x.action === "username_changed").length === 1,
        r.error ?? rows.map((x) => x.action).join(",")
    );

    // Songs: viele in einer Transaktion = ein Sammel-Eintrag
    const [pl] = await q("select id from topic_pool where text = '80er Hits'");
    for (let i = 0; i < 7; i++) {
        await q("insert into song_pool (topic_pool_id, title, artist, preview_url) values ($1, $2, 'AudTest', 'https://example.invalid/x.m4a')", [pl.id, `Audit Song ${i}`]);
    }
    rows = await log("action = 'songs_added'");
    check("7 neue Songs = ein Sammel-Eintrag mit Anzahl", rows.length === 1 && rows[0].details?.count === 7 && rows[0].details?.playlists?.["80er Hits"] === 7, JSON.stringify(rows[0]?.details));
    await q("update song_pool set plays = plays + 1 where artist = 'AudTest'");
    rows = await log("action = 'songs_changed'");
    check("Spielzähler (plays/hits) erzeugen KEINE Einträge", rows.length === 0);
    await q("update song_pool set title = title || '!' where artist = 'AudTest'");
    rows = await log("action = 'songs_changed'");
    check("Titeländerung per Skript wird gesammelt protokolliert", rows.length === 1 && rows[0].details?.count === 7);
    await q("delete from song_pool where artist = 'AudTest'");
    rows = await log("action = 'songs_removed'");
    check("Songs gelöscht wird protokolliert", rows.length === 1 && rows[0].details?.count === 7);

    // Playlist
    await q("insert into topic_pool (text, active, is_song_category) values ('Audit-Playlist', true, true)");
    await q("update topic_pool set active = false where text = 'Audit-Playlist'");
    await q("delete from topic_pool where text = 'Audit-Playlist'");
    rows = await log("action = 'playlist_changed' and target_label = 'Audit-Playlist'");
    check("Playlist angelegt/geändert/gelöscht", rows.map((x) => x.details?.aktion).join(",") === "angelegt,geändert,gelöscht", rows.map((x) => x.details?.aktion).join(","));

    // Aufräumen abgelaufener Lobbys
    await q("insert into lobbies (code, host_player_id, privacy, max_players, round_seconds, last_activity_at) values ('ZZ99', gen_random_uuid(), 'private', 6, 25, now() - interval '2 hours')");
    await q("select public.cleanup_expired_lobbies()");
    rows = await log("action = 'lobbies_expired'");
    check("Abgelaufene Lobbys werden protokolliert", rows.length === 1 && rows[0].details?.count >= 1);

    // Löschen per Skript
    await q("delete from auth.users where id = $1", [user]);
    rows = await log("action = 'account_deleted'");
    check("Konto per Skript gelöscht wird protokolliert", rows.some((x) => x.target_label === "audmod"), rows.map((x) => x.target_label).join(","));

    // Manipulationsschutz
    r = await as(admin, "delete from public.admin_audit");
    check("Protokoll lässt sich als Admin nicht löschen", !!r.error);
    check("Protokoll lässt sich auch per SQL nicht löschen", await blockedBy("a1", "delete from public.admin_audit"));
    check("Protokoll lässt sich nicht ändern", await blockedBy("a2", "update public.admin_audit set action = 'x'"));
    check("Protokoll lässt sich nicht leeren (TRUNCATE)", await blockedBy("a3", "truncate public.admin_audit"));

    // Lesen
    r = await as(admin, "select public.admin_list_audit(5) a");
    check("Admin kann Protokoll lesen (Gesamtzahl + Einträge)", !r.error && r.rows[0].a.total >= 10 && r.rows[0].a.rows.length === 5, r.error);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await c.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
