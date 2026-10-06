#!/usr/bin/env node
/**
 * Testet Migration 085 (Admin-Schnellmenü: Online-Spieler, Kick) in EINER Transaktion, die zurückgerollt wird.
 * Aufruf: node db/scripts/test-admin-quick.mjs
 */
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
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
        await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(uid ? { sub: uid, role: "authenticated" } : { role: "anon" })]);
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

try {
    await q("begin");
    const admin = await createTestUser(q, "qadmin", "admin");
    const sup = await createTestUser(q, "qsupport", "supporter");
    const user = await createTestUser(q, "quser", "user");
    const nobody = await createTestUser(q, "qnobody", "user");

    // Lobby mit Gast, Konto-Spieler und Admin-Spieler (alle "online")
    const [lob] = await q("select * from public.rpc_create_lobby('QHost', 'private', 6, 25, null, 'normal')");
    const [{ id: lobbyId }] = await q("select id from lobbies where code = $1", [lob.code]);
    const hostPid = lob.host_player_id;
    await q("select public.rpc_join_lobby($1, $2, 'QHost', null)", [lob.code, hostPid]);
    const guestPid = randomUUID(), userPid = randomUUID(), adminPid = randomUUID();
    await q("select public.rpc_join_lobby($1, $2, 'QGast', null)", [lob.code, guestPid]);
    await q("select public.rpc_join_lobby($1, $2, 'QKonto', null)", [lob.code, userPid]);
    await q("select public.rpc_join_lobby($1, $2, 'QAdmin', null)", [lob.code, adminPid]);
    await q("update players set user_id = $3, last_seen_at = now() where lobby_id = $1 and player_id = $2", [lobbyId, userPid, user]);
    await q("update players set user_id = $3, last_seen_at = now() where lobby_id = $1 and player_id = $2", [lobbyId, adminPid, admin]);
    await q("update players set last_seen_at = now() where lobby_id = $1 and player_id in ($2, $3)", [lobbyId, hostPid, guestPid]);
    // Geist: lange nicht gesehen
    const ghostPid = randomUUID();
    await q("select public.rpc_join_lobby($1, $2, 'QGeist', null)", [lob.code, ghostPid]);
    await q("update players set last_seen_at = now() - interval '10 minutes' where lobby_id = $1 and player_id = $2", [lobbyId, ghostPid]);

    let r = await as(sup, "select public.admin_online_players() a");
    const names = (r.rows?.[0]?.a ?? []).map((x) => x.name).sort().join(",");
    check("Supporter sieht Online-Spieler (ohne Bots/Geister)", !r.error && names === "QAdmin,QGast,QHost,QKonto", r.error ?? names);
    const konto = (r.rows?.[0]?.a ?? []).find((x) => x.name === "QKonto");
    check("Online-Liste zeigt Konto, Lobby-Code und Host-Info", konto?.username === "quser" && konto?.lobbyCode === lob.code, JSON.stringify(konto));

    r = await as(nobody, "select public.admin_online_players() a");
    check("Normaler Spieler darf die Liste nicht abrufen", /not_authorized/.test(r.error ?? ""), r.error);
    r = await as(null, "select public.admin_online_players() a");
    check("Gast darf die Liste nicht abrufen", !!r.error, r.error);

    // Kick
    r = await as(nobody, "select public.admin_kick_player($1, $2)", [lobbyId, guestPid]);
    check("Normaler Spieler darf nicht kicken", /not_authorized/.test(r.error ?? ""), r.error);
    r = await as(sup, "select public.admin_kick_player($1, $2)", [lobbyId, guestPid]);
    const [g] = await q("select status from players where lobby_id = $1 and player_id = $2", [lobbyId, guestPid]);
    check("Supporter kickt Gast", !r.error && g.status === "kicked", r.error ?? g.status);
    r = await as(sup, "select public.admin_kick_player($1, $2)", [lobbyId, adminPid]);
    check("Supporter darf keinen Admin kicken", /not_authorized/.test(r.error ?? ""), r.error);
    r = await as(admin, "select public.admin_kick_player($1, $2)", [lobbyId, userPid]);
    const [u] = await q("select status from players where lobby_id = $1 and player_id = $2", [lobbyId, userPid]);
    check("Admin kickt Konto-Spieler", !r.error && u.status === "kicked", r.error ?? u.status);
    r = await as(admin, "select public.admin_kick_player($1, $2)", [lobbyId, guestPid]);
    check("Bereits gekickter Spieler: sauberer Fehler", /player_not_found/.test(r.error ?? ""), r.error);

    // Protokoll
    const log = await q("select action, actor_name, target_label, details from admin_audit where action = 'player_kicked' and details->>'lobby' = $1 order by id", [lob.code]);
    check("Kicks stehen im Protokoll (mit Lobby-Code und Urheber)", log.length === 2 && log[0].actor_name === "qsupport" && log[0].details.lobby === lob.code, JSON.stringify(log));

    // Gekickte tauchen nicht mehr als online auf
    r = await as(admin, "select public.admin_online_players() a");
    const after = (r.rows?.[0]?.a ?? []).map((x) => x.name).sort().join(",");
    check("Gekickte sind nicht mehr online", after === "QAdmin,QHost", after);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await c.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
