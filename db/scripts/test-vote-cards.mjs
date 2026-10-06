#!/usr/bin/env node
/**
 * Testet Migration 084 (Abstimmung je nach Zahl der gewählten Playlists) mit echten Wegwerf-Lobbys
 * (über die normalen Schnittstellen wie der Browser, danach werden die Lobbys gelöscht).
 * Aufruf: node db/scripts/test-vote-cards.mjs
 */
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import pg from "pg";

const env = (f) => Object.fromEntries(readFileSync(f, "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]));
const web = env("apps/web/.env.local"), dbe = env("db/.env.local");
const db = new pg.Client({ host: dbe.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: dbe.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (s, p = []) => (await db.query(s, p)).rows;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
const check = (n, ok, d = "") => { console.log(`${ok ? "✅" : "❌"} ${n}${d ? "  – " + d : ""}`); if (!ok) failed++; };
await q("delete from rate_limits");
const created = [];

async function newLobby(playlists) {
    const session = randomUUID();
    const sb = createClient(web.NEXT_PUBLIC_SUPABASE_URL, web.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false }, global: { headers: { "x-kumpir-session": session } } });
    const r = await sb.rpc("rpc_create_lobby", { p_host_name: "VoteTest", p_privacy: "private", p_max_players: 6, p_round_seconds: 25, p_user_id: null, p_round_speed: "normal" });
    const row = Array.isArray(r.data) ? r.data[0] : r.data;
    await sb.rpc("rpc_join_lobby", { p_code: row.code, p_player_id: row.host_player_id, p_name: "VoteTest", p_user_id: null });
    const [{ id }] = await q("select id from lobbies where code = $1", [row.code]);
    created.push(id);
    await sb.rpc("set_lobby_topic_filter", { p_lobby_id: id, p_me_player_id: row.host_player_id, p_categories: playlists });
    await sb.rpc("rpc_add_bot", { p_lobby_id: id, p_me_player_id: row.host_player_id, p_bot_name: "Bot Anna", p_skill: 2 });
    return { sb, id, me: row.host_player_id, code: row.code };
}

try {
    // ---- 1 Playlist: Abstimmung entfällt
    let L = await newLobby(["80er Hits"]);
    let r = await L.sb.rpc("rpc_begin_topic_vote", { p_lobby_id: L.id, p_player_id: L.me });
    check("1 Playlist: Start ohne Fehler", !r.error, r.error?.message);
    let [row] = await q("select phase, topic_vote_cards, topic_a, topic_b from lobbies where id = $1", [L.id]);
    check("1 Playlist: genau eine Karte", row.topic_vote_cards === 1 && row.topic_a === "80er Hits", JSON.stringify(row));
    await sleep(3500); // Server-Takt (alle 2 s) wertet aus
    [row] = await q("select phase, topic_selected, topic_tie_choices from lobbies where id = $1", [L.id]);
    check("1 Playlist: Abstimmung übersprungen, direkt im Countdown", row.phase === "countdown" && row.topic_selected === "80er Hits" && row.topic_tie_choices === null, JSON.stringify(row));

    // ---- 2 Playlists: nur A und B, nie eine dritte Karte
    const picks = new Set();
    let thirdRejected = true;
    for (let i = 0; i < 4; i++) {
        L = await newLobby(["80er Hits", "Rock-Klassiker"]);
        await L.sb.rpc("rpc_begin_topic_vote", { p_lobby_id: L.id, p_player_id: L.me });
        [row] = await q("select topic_vote_cards, topic_a, topic_b from lobbies where id = $1", [L.id]);
        if (i === 0) check("2 Playlists: zwei Karten, beide Playlists verschieden", row.topic_vote_cards === 2 && row.topic_a !== row.topic_b, JSON.stringify(row));
        const v3 = await L.sb.rpc("rpc_vote_topic", { p_lobby_id: L.id, p_player_id: L.me, p_choice: 3 });
        if (!v3.error) thirdRejected = false;
        if (i === 0) {
            const v2 = await L.sb.rpc("rpc_vote_topic", { p_lobby_id: L.id, p_player_id: L.me, p_choice: 2 });
            check("2 Playlists: Stimme für Karte 2 gültig", !v2.error, v2.error?.message);
        }
        await q("update lobbies set topic_vote_ends_at = now() where id = $1", [L.id]);
        await L.sb.rpc("rpc_finalize_topic_vote", { p_lobby_id: L.id });
        [row] = await q("select phase, topic_selected from lobbies where id = $1", [L.id]);
        picks.add(row.topic_selected);
        if (!["80er Hits", "Rock-Klassiker"].includes(row.topic_selected)) thirdRejected = false;
    }
    check("2 Playlists: Stimme für Zufall-Karte (3) wird abgelehnt", thirdRejected);
    check("2 Playlists: gewählt wird immer eine der beiden", [...picks].every((p) => ["80er Hits", "Rock-Klassiker"].includes(p)), [...picks].join(", "));

    // ---- 3 Playlists: wie bisher (A, B, Zufall)
    L = await newLobby(["80er Hits", "Rock-Klassiker", "Deutsch-Pop"]);
    await L.sb.rpc("rpc_begin_topic_vote", { p_lobby_id: L.id, p_player_id: L.me });
    [row] = await q("select phase, topic_vote_cards from lobbies where id = $1", [L.id]);
    check("3 Playlists: drei Karten, Abstimmung läuft", row.topic_vote_cards === 3 && row.phase === "topic_vote", JSON.stringify(row));
    const v3 = await L.sb.rpc("rpc_vote_topic", { p_lobby_id: L.id, p_player_id: L.me, p_choice: 3 });
    check("3 Playlists: Zufall-Karte wählbar", !v3.error, v3.error?.message);
    await sleep(1500);
    [row] = await q("select phase from lobbies where id = $1", [L.id]);
    check("3 Playlists: Abstimmung wird nicht übersprungen (wartet auf Ablauf/alle Stimmen)", row.phase === "topic_vote");

    // ---- Alle Playlists (Standard = leerer Filter): mehr als 3 Karten nie
    L = await newLobby([]);
    await L.sb.rpc("rpc_begin_topic_vote", { p_lobby_id: L.id, p_player_id: L.me });
    [row] = await q("select topic_vote_cards from lobbies where id = $1", [L.id]);
    check("Alle Playlists: weiter 3 Karten", row.topic_vote_cards === 3, String(row.topic_vote_cards));
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    for (const id of created) await q("delete from lobbies where id = $1", [id]).catch(() => {});
    await q("delete from rate_limits").catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (Test-Lobbys gelöscht).");
process.exit(failed ? 1 : 0);
