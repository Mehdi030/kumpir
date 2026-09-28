#!/usr/bin/env node
/**
 * Gezielte Verifikation: funktionieren Teleport und Reverse tatsächlich
 * anders als Original? Erstellt für jeden Modus eine kleine Lobby, setzt
 * den Modus per set_lobby_mode, treibt ein paar Pässe durch und prüft das
 * TATSÄCHLICHE Verhalten (nicht nur "kein Fehler geworfen"):
 *   - original: Kartoffel geht IMMER an den nächsten seat_index
 *   - teleport: Kartoffel geht an eine ZUFÄLLIGE andere Person (nicht
 *     immer die nächste Sitznummer)
 *   - reverse:  pass_direction dreht sich bei jedem Pass um
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);

const uuid = () => crypto.randomUUID();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function clientFor(token) {
    return createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_ANON_KEY, {
        auth: { persistSession: false },
        global: { headers: { "x-kumpir-session": token } },
    });
}

let pass = 0, fail = 0;
function check(ok, label, detail) {
    ok ? pass++ : fail++;
    console.log(`  ${ok ? "✅" : "❌"} ${label}${detail ? ` — ${detail}` : ""}`);
}

async function makeLobby(n) {
    const host = { token: uuid() };
    host.client = clientFor(host.token);
    const { data } = await host.client.rpc("rpc_create_lobby", {
        p_host_name: "Host", p_privacy: "private", p_max_players: 12,
        p_round_seconds: 25, p_user_id: null, p_round_speed: "calm", // calm = mehr Zeit zum Beobachten
    });
    const row = Array.isArray(data) ? data[0] : data;
    const code = String(row.code).toUpperCase();
    host.id = String(row.host_player_id);
    await host.client.rpc("rpc_join_lobby", { p_code: code, p_player_id: host.id, p_name: "Host", p_user_id: null });

    const players = [host];
    for (let i = 1; i < n; i++) {
        const token = uuid();
        const client = clientFor(token);
        const id = uuid();
        await client.rpc("rpc_join_lobby", { p_code: code, p_player_id: id, p_name: `P${i}`, p_user_id: null });
        players.push({ token, client, id });
    }
    const { data: lob } = await host.client.from("lobbies").select("id").eq("code", code).single();
    return { code, lobbyId: lob.id, players, host };
}

async function testMode(mode) {
    console.log(`\n${"=".repeat(50)}\n🎯 Modus: ${mode}\n${"=".repeat(50)}`);
    const { code, lobbyId, players, host } = await makeLobby(5);

    const setMode = await host.client.rpc("set_lobby_mode", { p_lobby_id: lobbyId, p_me_player_id: host.id, p_mode: mode });
    check(!setMode.error, `set_lobby_mode('${mode}') funktioniert`, setMode.error?.message);

    const { data: check1 } = await host.client.from("lobbies").select("game_mode").eq("id", lobbyId).single();
    check(check1?.game_mode === mode, `game_mode ist tatsächlich '${mode}'`, `ist '${check1?.game_mode}'`);

    for (const p of players) await p.client.rpc("rpc_toggle_ready", { p_lobby_id: lobbyId, p_player_id: p.id });
    await host.client.rpc("rpc_begin_topic_vote", { p_lobby_id: lobbyId, p_player_id: host.id });
    for (const p of players) await p.client.rpc("rpc_vote_topic", { p_lobby_id: lobbyId, p_player_id: p.id, p_choice: 1 });
    await host.client.rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
    await host.client.rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });

    const seatOrder = [];
    const directionLog = [];
    let successfulPasses = 0;

    for (let i = 0; i < 12 && successfulPasses < 6; i++) {
        const { data: lob } = await host.client.from("lobbies").select("*").eq("id", lobbyId).single();
        if (lob.phase !== "running") { await sleep(200); continue; }
        if (lob.explode_at && Date.now() >= Date.parse(lob.explode_at) - 100) {
            await host.client.rpc("rpc_tick_game", { p_code: code });
            await sleep(200);
            continue;
        }
        if (lob.current_attempt_id) { await sleep(150); continue; }

        const holder = players.find((p) => p.id === lob.holder_player_id);
        if (!holder) { await sleep(150); continue; }

        const { data: seatRow } = await host.client.from("players").select("seat_index").eq("lobby_id", lobbyId).eq("player_id", holder.id).single();
        seatOrder.push(seatRow?.seat_index);
        directionLog.push(lob.pass_direction);

        const a = await holder.client.rpc("rpc_attempt_pass", { p_code: code, p_player_id: holder.id, p_answer: `A${i}` });
        if (a.error) { await sleep(150); continue; }

        const { data: lob2 } = await host.client.from("lobbies").select("current_attempt_id").eq("id", lobbyId).single();
        if (lob2?.current_attempt_id) {
            for (const voter of players) {
                if (voter.id === holder.id) continue;
                await voter.client.rpc("rpc_vote_answer", { p_attempt_id: lob2.current_attempt_id, p_voter_id: voter.id, p_accept: true });
            }
            successfulPasses++;
        }
        await sleep(250);
    }

    console.log(`   Sitzplatz-Reihenfolge der Halter: [${seatOrder.join(", ")}]`);
    console.log(`   pass_direction-Verlauf: [${directionLog.join(", ")}]`);

    if (mode === "original") {
        let sequential = true;
        for (let i = 1; i < seatOrder.length; i++) {
            const prev = seatOrder[i - 1], cur = seatOrder[i];
            if (cur !== (prev + 1) % 5) sequential = false;
        }
        check(sequential && seatOrder.length >= 3, "Original: Halter-Reihenfolge strikt aufsteigend (seat+1)", `Reihenfolge war [${seatOrder.join(",")}]`);
    } else if (mode === "teleport") {
        let hasJump = false;
        for (let i = 1; i < seatOrder.length; i++) {
            const prev = seatOrder[i - 1], cur = seatOrder[i];
            if (cur !== (prev + 1) % 5) hasJump = true;
        }
        check(hasJump && seatOrder.length >= 3, "Teleport: mindestens ein Sprung, der NICHT die nächste Sitznummer ist", `Reihenfolge war [${seatOrder.join(",")}] (rein sequentiell wäre verdächtig)`);
    } else if (mode === "reverse") {
        let flips = 0;
        for (let i = 1; i < directionLog.length; i++) {
            if (directionLog[i] !== directionLog[i - 1]) flips++;
        }
        check(flips >= 1, "Reverse: pass_direction dreht sich um", `${flips} Wechsel in [${directionLog.join(",")}]`);
    }
}

async function main() {
    for (const mode of ["original", "teleport", "reverse"]) {
        try {
            await testMode(mode);
        } catch (e) {
            fail++;
            console.log(`  💥 Modus ${mode} abgebrochen: ${e.message}`);
        }
    }
    console.log(`\n${"=".repeat(50)}\n   ${pass} bestanden · ${fail} fehlgeschlagen`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(2); });
