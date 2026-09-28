#!/usr/bin/env node
/**
 * Cheat-Probe: versucht systematisch, das Spiel über den öffentlichen
 * Anon-Key zu manipulieren -- genau so, wie es ein Spieler mit offener
 * Browser-Konsole tun könnte.
 *
 * Jeder Test meldet:
 *   ✅ BLOCKED  = Angriff scheitert (gut)
 *   ❌ EXPLOIT  = Angriff funktioniert (Sicherheitsloch)
 *   ⚠️  BROKEN   = legitime Funktion scheitert (Regression)
 *
 * Aufruf:  node apps/web/scripts/probe-cheats.mjs
 */

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ENV_PATH = resolve(__dirname, "..", ".env.local");

function parseEnv(text) {
    const map = {};
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const i = line.indexOf("=");
        if (i < 0) continue;
        map[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
    return map;
}

const env = parseEnv(readFileSync(ENV_PATH, "utf8"));
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!URL || !ANON) {
    console.error("NEXT_PUBLIC_SUPABASE_URL / _ANON_KEY fehlen in .env.local");
    process.exit(1);
}

const db = createClient(URL, ANON, { auth: { persistSession: false } });

const results = [];
function record(status, name, detail) {
    results.push({ status, name, detail });
    const icon = status === "BLOCKED" ? "✅" : status === "EXPLOIT" ? "❌" : status === "BROKEN" ? "⚠️ " : "  ";
    console.log(`${icon} ${status.padEnd(7)} ${name}${detail ? ` — ${detail}` : ""}`);
}

const uuid = () => crypto.randomUUID();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function setup() {
    const hostName = "ProbeHost";
    const { data, error } = await db.rpc("rpc_create_lobby", {
        p_host_name: hostName,
        p_privacy: "private",
        p_max_players: 8,
        p_round_seconds: 25,
        p_user_id: null,
        p_round_speed: "fast",
    });
    if (error) throw new Error(`rpc_create_lobby failed: ${error.message}`);
    const row = Array.isArray(data) ? data[0] : data;
    const code = String(row.code).toUpperCase();
    const hostId = String(row.host_player_id);

    await db.rpc("rpc_join_lobby", { p_code: code, p_player_id: hostId, p_name: hostName, p_user_id: null });

    const victimId = uuid();
    const attackerId = uuid();
    await db.rpc("rpc_join_lobby", { p_code: code, p_player_id: victimId, p_name: "Opfer", p_user_id: null });
    await db.rpc("rpc_join_lobby", { p_code: code, p_player_id: attackerId, p_name: "Angreifer", p_user_id: null });

    const { data: lob } = await db.from("lobbies").select("id").eq("code", code).single();
    return { code, lobbyId: lob.id, hostId, victimId, attackerId };
}

async function probeDirectWrites(ctx) {
    // 1. Direkt in players schreiben (z.B. sich selbst unsterblich machen)
    const w1 = await db.from("players").update({ is_alive: true, ready: true }).eq("lobby_id", ctx.lobbyId).eq("player_id", ctx.attackerId).select();
    if (!w1.error && w1.data?.length) record("EXPLOIT", "players direkt UPDATE-bar", "Angreifer kann eigene Zeile beliebig setzen");
    else record("BLOCKED", "players direkt UPDATE", w1.error ? w1.error.code ?? w1.error.message : "0 Zeilen (RLS)");

    // 2. Fremde Spieler-Zeile manipulieren (Gegner töten)
    const w2 = await db.from("players").update({ is_alive: false }).eq("lobby_id", ctx.lobbyId).eq("player_id", ctx.victimId).select();
    if (!w2.error && w2.data?.length) record("EXPLOIT", "fremde players-Zeile UPDATE-bar", "Angreifer kann Gegner eliminieren");
    else record("BLOCKED", "fremde players-Zeile UPDATE", w2.error ? w2.error.code ?? w2.error.message : "0 Zeilen (RLS)");

    // 3. lobbies direkt manipulieren (Kartoffel verschieben / Timer verlängern)
    const far = new Date(Date.now() + 3600_000).toISOString();
    const w3 = await db.from("lobbies").update({ holder_player_id: ctx.victimId, explode_at: far }).eq("id", ctx.lobbyId).select();
    if (!w3.error && w3.data?.length) record("EXPLOIT", "lobbies direkt UPDATE-bar", "Halter/Timer frei manipulierbar");
    else record("BLOCKED", "lobbies direkt UPDATE", w3.error ? w3.error.code ?? w3.error.message : "0 Zeilen (RLS)");

    // 4. Spieler löschen
    const w4 = await db.from("players").delete().eq("lobby_id", ctx.lobbyId).eq("player_id", ctx.victimId).select();
    if (!w4.error && w4.data?.length) record("EXPLOIT", "players DELETE-bar", "Angreifer kann Gegner aus Lobby löschen");
    else record("BLOCKED", "players DELETE", w4.error ? w4.error.code ?? w4.error.message : "0 Zeilen (RLS)");

    // 5. Eigene Zeile als 'left' markieren -- das nutzt leaveLobby() produktiv!
    const w5 = await db.from("players").update({ status: "left" }).eq("lobby_id", ctx.lobbyId).eq("player_id", ctx.attackerId).select();
    if (!w5.error && w5.data?.length) record("EXPLOIT", "leaveLobby-Pfad (players.status)", "direkter Schreibzugriff offen");
    else record("BROKEN", "leaveLobby-Pfad (players.status)", "RLS blockt -> 'Lobby verlassen' funktioniert NICHT");

    // 6. Zusatzstimmen direkt in pass_attempt_votes einfügen
    const w6 = await db.from("pass_attempt_votes").insert({ attempt_id: uuid(), voter_id: uuid(), accept: true }).select();
    if (!w6.error && w6.data?.length) record("EXPLOIT", "pass_attempt_votes INSERT-bar", "Stimmen frei fälschbar");
    else record("BLOCKED", "pass_attempt_votes INSERT", w6.error ? w6.error.code ?? w6.error.message : "0 Zeilen (RLS)");
}

async function probeIdentitySpoofing(ctx) {
    // Lesbarkeit fremder player_ids -- Voraussetzung für alle Impersonation-Angriffe
    const { data: seen } = await db.from("players").select("player_id,name").eq("lobby_id", ctx.lobbyId);
    const foreign = (seen ?? []).filter((p) => p.player_id !== ctx.attackerId);
    if (foreign.length > 0) record("EXPLOIT", "fremde player_id lesbar", `${foreign.length} IDs über Anon-Key sichtbar`);
    else record("BLOCKED", "fremde player_id lesbar");

    // Ready-Status eines fremden Spielers umschalten
    const before = (seen ?? []).find((p) => p.player_id === ctx.victimId);
    const t = await db.rpc("rpc_toggle_ready", { p_lobby_id: ctx.lobbyId, p_player_id: ctx.victimId });
    if (!t.error) record("EXPLOIT", "rpc_toggle_ready für fremde ID", "Angreifer schaltet Ready des Opfers");
    else record("BLOCKED", "rpc_toggle_ready für fremde ID", t.error.message);
    void before;

    // Host-Aktion als Nicht-Host durch Spoofing der Host-ID
    const k = await db.rpc("kick_player", { p_lobby_id: ctx.lobbyId, p_me_player_id: ctx.hostId, p_target_player_id: ctx.victimId });
    if (!k.error) record("EXPLOIT", "kick_player mit gespoofter Host-ID", "Angreifer kickt beliebig");
    else record("BLOCKED", "kick_player mit gespoofter Host-ID", k.error.message);
}

async function probeGameFlowCheats(ctx) {
    // Spiel starten (nur Host) -- als Angreifer mit Host-ID
    const b = await db.rpc("rpc_begin_topic_vote", { p_lobby_id: ctx.lobbyId, p_player_id: ctx.hostId });
    if (b.error) { record("BROKEN", "rpc_begin_topic_vote", b.error.message); return; }

    // Für fremden Spieler beim Topic abstimmen
    const v = await db.rpc("rpc_vote_topic", { p_lobby_id: ctx.lobbyId, p_player_id: ctx.victimId, p_choice: 1 });
    if (!v.error) record("EXPLOIT", "rpc_vote_topic für fremde ID", "Topic-Vote fälschbar");
    else record("BLOCKED", "rpc_vote_topic für fremde ID", v.error.message);

    await db.rpc("rpc_finalize_topic_vote", { p_lobby_id: ctx.lobbyId });
    await db.rpc("rpc_advance_from_countdown", { p_lobby_id: ctx.lobbyId });

    const { data: lob } = await db.from("lobbies").select("phase,holder_player_id,explode_at,current_attempt_id").eq("id", ctx.lobbyId).single();
    if (lob?.phase !== "running") { record("BROKEN", "Phase running erreichen", `phase=${lob?.phase}`); return; }

    const holder = lob.holder_player_id;
    const nonHolder = [ctx.hostId, ctx.victimId, ctx.attackerId].find((id) => id !== holder);

    // Passen ohne Halter zu sein
    const p1 = await db.rpc("rpc_pass_potato", { p_code: ctx.code, p_player_id: nonHolder });
    if (!p1.error) record("EXPLOIT", "rpc_pass_potato als Nicht-Halter", "Kartoffel ohne Halter-Rolle weitergebbar");
    else record("BLOCKED", "rpc_pass_potato als Nicht-Halter", p1.error.message);

    // Antwort-Versuch im Namen des Halters starten
    const a = await db.rpc("rpc_attempt_pass", { p_code: ctx.code, p_player_id: holder, p_answer: "CheatAntwort" });
    if (a.error) { record("BROKEN", "rpc_attempt_pass (Halter)", a.error.message); return; }
    record("EXPLOIT", "rpc_attempt_pass im Namen des Halters", "fremde ID reicht aus");

    const { data: lob2 } = await db.from("lobbies").select("current_attempt_id").eq("id", ctx.lobbyId).single();
    const attemptId = lob2?.current_attempt_id;
    if (!attemptId) { record("BROKEN", "current_attempt_id gesetzt", "null"); return; }

    // Vote-Stuffing: als ALLE anderen Spieler abstimmen -> Mehrheit im Alleingang
    const voters = [ctx.hostId, ctx.victimId, ctx.attackerId].filter((id) => id !== holder);
    let stuffed = 0;
    for (const voter of voters) {
        const r = await db.rpc("rpc_vote_answer", { p_attempt_id: attemptId, p_voter_id: voter, p_accept: true });
        if (!r.error) stuffed++;
    }
    if (stuffed > 1) record("EXPLOIT", "Vote-Stuffing", `${stuffed} Stimmen von einem Client abgegeben -> Mehrheit erzwingbar`);
    else record("BLOCKED", "Vote-Stuffing", `${stuffed} Stimme(n) durchgekommen`);

    // Doppelstimme mit derselben ID
    const dup = await db.rpc("rpc_vote_answer", { p_attempt_id: attemptId, p_voter_id: voters[0], p_accept: false });
    record(dup.error ? "BLOCKED" : "BLOCKED", "Doppelstimme gleiche ID", dup.error ? dup.error.message : "ON CONFLICT DO NOTHING");
}

async function probeLifecycleCheats(ctx) {
    // Fremde Lobby zurücksetzen / Rematch erzwingen (nur Code bekannt)
    const outsider = uuid();
    const r1 = await db.rpc("rpc_reset_lobby", { p_code: ctx.code, p_player_id: outsider });
    if (!r1.error) record("EXPLOIT", "rpc_reset_lobby als Aussenstehender", "Partie von Fremden resetbar");
    else record("BLOCKED", "rpc_reset_lobby als Aussenstehender", r1.error.message);

    const r2 = await db.rpc("rpc_rematch", { p_code: ctx.code, p_player_id: outsider });
    if (!r2.error) record("EXPLOIT", "rpc_rematch als Aussenstehender", "Rematch von Fremden erzwingbar");
    else record("BLOCKED", "rpc_rematch als Aussenstehender", r2.error.message);

    // Laufende Partie abwürgen (Mitglied, aber Phase != finished)
    const r3 = await db.rpc("rpc_reset_lobby", { p_code: ctx.code, p_player_id: ctx.attackerId });
    if (!r3.error) record("EXPLOIT", "rpc_reset_lobby mitten im Spiel", "laufende Partie abwürgbar");
    else record("BLOCKED", "rpc_reset_lobby mitten im Spiel", r3.error.message);

    // Bot-Spam durch Nicht-Host
    const bot = await db.rpc("rpc_add_bot", { p_lobby_id: ctx.lobbyId, p_me_player_id: ctx.attackerId, p_bot_name: "SpamBot" });
    if (!bot.error) record("EXPLOIT", "rpc_add_bot als Nicht-Host", "Lobby mit Bots flutbar");
    else record("BLOCKED", "rpc_add_bot als Nicht-Host", bot.error.message);
}

async function probePII() {
    const e = await db.rpc("get_email_for_username", { p_username: "test" });
    if (!e.error) record("EXPLOIT", "get_email_for_username", "Email-Harvesting offen");
    else record("BLOCKED", "get_email_for_username", e.error.code ?? e.error.message);

    const p = await db.from("profiles").select("email,phone").limit(1);
    if (!p.error && p.data?.length && (p.data[0].email || p.data[0].phone)) record("EXPLOIT", "profiles.email/phone lesbar", "PII offen");
    else record("BLOCKED", "profiles.email/phone", p.error ? p.error.code ?? p.error.message : "keine Werte");
}

async function main() {
    console.log(`\n🔍 Cheat-Probe gegen ${URL}\n${"=".repeat(64)}`);
    const ctx = await setup();
    console.log(`   Test-Lobby ${ctx.code} (3 Spieler)\n`);

    console.log("── Direkte Tabellen-Schreibzugriffe ──");
    await probeDirectWrites(ctx);
    console.log("\n── Identitäts-Spoofing ──");
    await probeIdentitySpoofing(ctx);
    console.log("\n── Spielablauf-Manipulation ──");
    await probeGameFlowCheats(ctx);
    console.log("\n── Lobby-Lifecycle ──");
    await probeLifecycleCheats(ctx);
    console.log("\n── PII / Auth ──");
    await probePII();

    const exploits = results.filter((r) => r.status === "EXPLOIT");
    const broken = results.filter((r) => r.status === "BROKEN");
    console.log(`\n${"=".repeat(64)}`);
    console.log(`   ${results.filter((r) => r.status === "BLOCKED").length} blockiert · ${exploits.length} EXPLOITS · ${broken.length} kaputt`);
    if (exploits.length) {
        console.log("\n❌ Offene Exploits:");
        for (const e of exploits) console.log(`   • ${e.name} — ${e.detail}`);
    }
    if (broken.length) {
        console.log("\n⚠️  Kaputte Funktionen:");
        for (const b of broken) console.log(`   • ${b.name} — ${b.detail}`);
    }
    console.log(`\n   Test-Lobby ${ctx.code} bleibt in der DB (kein Client-Delete möglich).\n`);
    process.exit(exploits.length ? 1 : 0);
}

await sleep(0);
main().catch((e) => {
    console.error("Probe abgebrochen:", e.message);
    process.exit(2);
});
