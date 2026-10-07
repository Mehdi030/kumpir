#!/usr/bin/env node
/**
 * Testet Migration 078 (Admin-Panel, Rollen, Löschanträge, Playlist-Auswahl) in EINER
 * Transaktion, die am Ende zurückgerollt wird – es bleibt nichts in der Datenbank.
 *
 * Aufruf: node db/scripts/test-admin-panel.mjs
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
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
async function as(uid, sql, params) {
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
const denied = (r) => /not_authorized/.test(r.error ?? "");

try {
    await q("begin");
    const admin = await createTestUser(q, "tadmin", "admin");
    const sup = await createTestUser(q, "tsupport", "supporter");
    const user = await createTestUser(q, "tuser", "user");

    // --- normale Nutzer kommen nicht rein
    check("Normaler Nutzer: Admin-Panel gesperrt", denied(await as(user, "select public.admin_whoami()")));
    check("Normaler Nutzer: Nutzerliste gesperrt", denied(await as(user, "select public.admin_list_users()")));

    // --- Supporter
    await q("update public.profiles set role = 'supporter' where id = $1", [sup]);
    let r = await as(sup, "select public.admin_whoami() as w");
    check("Supporter: Panel offen, Rolle supporter", r.rows?.[0]?.w?.role === "supporter", JSON.stringify(r.rows?.[0]?.w?.counts ?? r.error));
    r = await as(sup, "select public.admin_list_users('tuser') as u");
    check("Supporter: Suche findet Nutzer inkl. E-Mail", r.rows?.[0]?.u?.some((x) => x.username === "tuser" && x.email), r.error);
    r = await as(sup, "select public.admin_set_user_status($1, 'suspended', 'Test') ", [user]);
    const [b] = await q("select u.banned_until, p.status, (select count(*) from auth.sessions s where s.user_id = u.id)::int sessions from auth.users u join public.profiles p on p.id = u.id where u.id = $1", [user]);
    check("Supporter sperrt Nutzer: Status + Login-Sperre + Sitzungen weg", !r.error && b.status === "suspended" && b.banned_until && b.sessions === 0, r.error);
    check("Supporter darf Admin nicht sperren", denied(await as(sup, "select public.admin_set_user_status($1, 'suspended')", [admin])));
    check("Supporter darf nicht endgültig löschen", denied(await as(sup, "select public.admin_delete_user($1)", [user])));
    check("Supporter darf keine Rollen vergeben", denied(await as(sup, "select public.admin_set_role($1, 'admin')", [user])));
    check("Supporter darf keine Songs archivieren", denied(await as(sup, "select public.admin_list_songs()")));
    check("Supporter sieht keine Admin-Statistik", denied(await as(sup, "select public.admin_song_stats()")));
    r = await as(sup, "select public.admin_update_user_profile($1, null, true, true)", [user]);
    check("Supporter: Spielername/Avatar zurücksetzen", !r.error, r.error);

    // --- Admin
    r = await as(admin, "select public.admin_set_user_status($1, 'active')", [user]);
    const [b2] = await q("select u.banned_until, p.status from auth.users u join public.profiles p on p.id = u.id where u.id = $1", [user]);
    check("Admin entsperrt: Login wieder frei", !r.error && b2.status === "active" && b2.banned_until === null, r.error);
    check("Admin kann eigene Rolle nicht ändern", /not_on_self/.test((await as(admin, "select public.admin_set_role($1, 'user')", [admin])).error ?? ""));
    check("Admin kann sich nicht selbst löschen", /not_on_self/.test((await as(admin, "select public.admin_delete_user($1)", [admin])).error ?? ""));
    check("Team-Konto kann nicht gelöscht werden", /staff_cannot_be_deleted/.test((await as(admin, "select public.admin_delete_user($1)", [sup])).error ?? ""));
    r = await as(admin, "select public.admin_set_role($1, 'user')", [sup]);
    check("Admin vergibt Rollen", !r.error && (await q("select role from public.profiles where id = $1", [sup]))[0].role === "user", r.error);

    // --- Löschantrag durch den Spieler
    r = await as(user, "select public.request_account_deletion('Teste nur')");
    const [d] = await q("select p.status, p.deletion_requested_at, u.banned_until from auth.users u join public.profiles p on p.id = u.id where u.id = $1", [user]);
    check("Spieler beantragt Löschung: Zugang gesperrt, Konto noch da", !r.error && d.status === "deletion_requested" && d.deletion_requested_at && d.banned_until, r.error);
    check("Selbst-Löschen direkt ist gesperrt", /permission denied/.test((await as(user, "select public.delete_my_account()")).error ?? ""));
    r = await as(user, "select public.get_my_settings() as s");
    check("Client erfährt den Status (für Abmeldung)", r.rows?.[0]?.s?.status === "deletion_requested", r.error);
    r = await as(admin, "select public.admin_list_users(null, 'deletion') as u");
    check("Löschanträge-Filter zeigt den Antrag", r.rows?.[0]?.u?.length === 1, r.error);
    r = await as(admin, "select public.admin_delete_user($1)", [user]);
    const [gone] = await q("select (select count(*) from auth.users where id = $1)::int n", [user]);
    check("Admin löscht endgültig", !r.error && gone.n === 0, r.error);

    // --- Protokoll
    r = await as(admin, "select public.admin_list_audit(50) as a");
    const actions = (r.rows?.[0]?.a?.rows ?? []).map((x) => x.action);
    check("Protokoll enthält alle Aktionen", ["suspended", "unsuspended", "profile_moderated", "role_changed", "deletion_requested", "deleted"].every((a) => actions.includes(a)), actions.join(","));

    // --- Playlists (eigene Test-Playlists, werden mit der Transaktion verworfen)
    for (const name of ["Testliste Rock", "Testliste 80er"]) {
        const [tp] = await q("insert into public.topic_pool (text, active, is_song_category) values ($1, true, true) returning id", [name]);
        await q("insert into public.song_pool (topic_pool_id, title, artist, preview_url) values ($1, $2, 'Testband', 'https://example.invalid/x.m4a')", [tp.id, name + " Song"]);
    }
    const [pool] = await q("select public._vote_topic_pool(null) p");
    const [nonSong] = await q("select count(*)::int n from public.topic_pool where text = any($1) and not coalesce(is_song_category, false)", [pool.p]);
    check("Abstimmung ohne Filter: nur Musik-Playlists", nonSong.n === 0 && pool.p.length >= 3, pool.p.join(", "));
    const [pl] = await q("select public.get_song_playlists() as p");
    check("Playlist-Liste mit Songanzahl", pl.p.length >= 3 && pl.p.every((x) => x.songs > 0), pl.p.map((x) => `${x.name}:${x.songs}`).join(", "));
    r = await as(sup, `select public.set_my_preferences('{"host":{"excludedPlaylists":["Testliste Rock","Testliste 80er","gibtsnicht"]}}'::jsonb) as p`);
    const ex = r.rows?.[0]?.p?.host?.excludedPlaylists ?? [];
    check("Rausgenommene Playlists gespeichert (nur echte)", ex.length === 2 && ex.includes("Testliste Rock") && !ex.includes("gibtsnicht"), JSON.stringify(ex));

    const host = randomUUID();
    const [lob] = await q("insert into public.lobbies (code, host_player_id, phase) values ('ZZA1', $1, 'waiting') returning id", [host]);
    await q("insert into public.players (lobby_id, player_id, name, status) values ($1, $2, 'Host', 'active')", [lob.id, host]);
    await q("select public.set_lobby_topic_filter($1, $2, $3)", [lob.id, host, ["Testliste Rock", "Gibts nicht", "Bauberufe"]]);
    let [f] = await q("select topic_filter from public.lobbies where id = $1", [lob.id]);
    check("Lobby-Filter: nur echte Musik-Playlists", JSON.stringify(f.topic_filter) === JSON.stringify(["Testliste Rock"]), JSON.stringify(f.topic_filter));
    await q("select public.set_lobby_topic_filter($1, $2, $3)", [lob.id, host, []]);
    [f] = await q("select topic_filter from public.lobbies where id = $1", [lob.id]);
    check("Lobby-Filter leer = alle (NULL)", f.topic_filter === null);

    // --- Lobby schließen (Supporter)
    await q("update public.profiles set role = 'supporter' where id = $1", [sup]);
    r = await as(sup, "select public.admin_list_lobbies() as l");
    check("Lobby-Liste", r.rows?.[0]?.l?.some((x) => x.code === "ZZA1"), r.error);
    r = await as(sup, "select public.admin_close_lobby($1)", [lob.id]);
    const [lg] = await q("select count(*)::int n from public.lobbies where id = $1", [lob.id]);
    check("Supporter schließt Lobby", !r.error && lg.n === 0, r.error);

    // --- Songs archivieren / zurückholen
    const [song] = await q("select sp.id, tp.text from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id where tp.text = 'Testliste Rock' limit 1");
    r = await as(admin, "select public.admin_set_song_archived($1, true)", [song.id]);
    let [s1] = await q("select tp.text, sp.archived_from from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id where sp.id = $1", [song.id]);
    check("Song archiviert (wird nicht mehr gezogen)", !r.error && s1.text.startsWith("Archiv") && s1.archived_from === "Testliste Rock", r.error);
    r = await as(admin, "select public.admin_set_song_archived($1, false)", [song.id]);
    [s1] = await q("select tp.text, sp.archived_from from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id where sp.id = $1", [song.id]);
    check("Song zurückgeholt", !r.error && s1.text === "Testliste Rock" && s1.archived_from === null, r.error);

    // --- Freier Ersatz-Benutzername (Registrierung scheitert nie an vergebenem Namen)
    const [un] = await q("select public._unique_username('tadmin') a, public._unique_username('A!') b, public._unique_username('neuername') c");
    check("Ersatz-Benutzername bei vergebenem/ungültigem Namen", /^tadmin\d{4}$/.test(un.a) && /^spieler/.test(un.b) && un.c === "neuername", JSON.stringify(un));

    // --- Fehlendes Profil wird angelegt (get_my_settings ist jetzt VOLATILE)
    await q("delete from public.profiles where id = $1", [sup]);
    r = await as(sup, "select public.get_my_settings() as s");
    const [pr] = await q("select count(*)::int n from public.profiles where id = $1", [sup]);
    check("Fehlendes Profil wird beim Laden angelegt", !r.error && pr.n === 1, r.error);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await client.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
