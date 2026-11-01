#!/usr/bin/env node
// Prüft get_lobby_badges (Migration 137) mit einer Test-Lobby (wird am Ende gelöscht): höchster Erfolg je angemeldetem Spieler.
// Aufruf: node db/scripts/test-lobby-badges.mjs
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
const db = new pg.Client({
    host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false },
});
await db.connect();
const q = async (sql, a = []) => (await db.query(sql, a)).rows;
let failed = 0;
const check = (name, ok, detail = "") => {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
};
let lobbyId = null;
try {
    const [u] = await q("select pa.user_id, count(*)::int n from public.player_achievements pa group by 1 order by 2 desc limit 1");
    if (!u) throw new Error("kein Konto mit Erfolgen vorhanden");
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Abzeichen', 'private', 12, 60)");
    [{ id: lobbyId }] = await q("select id from public.lobbies where code = $1", [code]);
    await q("update public.players set user_id = $2 where lobby_id = $1 and player_id = $3", [lobbyId, u.user_id, host]);
    const [{ b }] = await q("select public.get_lobby_badges($1) b", [lobbyId]);
    const best = await q("select a.tier from public.player_achievements pa join public.achievements a on a.code = pa.achievement_code where pa.user_id = $1 order by case a.tier when 'gold' then 3 when 'silver' then 2 else 1 end desc limit 1", [u.user_id]);
    check("Spieler mit Konto bekommt sein Abzeichen", b.length === 1 && b[0].player_id === host && b[0].n === u.n, JSON.stringify(b));
    check("Es ist die höchste Stufe", b[0]?.tier === best[0].tier, `${b[0]?.tier} / ${best[0].tier}`);
    await q("select public.rpc_add_bot($1, $2, 'Bot 1', 2::smallint)", [lobbyId, host]);
    const [{ b: b2 }] = await q("select public.get_lobby_badges($1) b", [lobbyId]);
    check("Bots und Gäste bekommen keins", b2.length === 1);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (lobbyId) await q("delete from public.lobbies where id = $1", [lobbyId]).catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
