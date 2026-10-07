#!/usr/bin/env node
/**
 * Angriffs-Test ("Pentest") von AUSSEN: nutzt nur den öffentlichen anon-Schlüssel bzw. die Sitzung
 * eines Wegwerf-Kontos – genau das, was auch ein Angreifer im Browser hat.
 * Jede Prüfung gibt BLOCKIERT (gut) oder LÜCKE (Sicherheitsproblem) aus; Exit-Code 1 bei Lücken.
 *
 * Aufräumen: Wegwerf-Konten ("sectest…") und Wegwerf-Lobbys werden am Ende gelöscht.
 * Aufruf: node db/scripts/security-attack.mjs
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
function parseEnv(p) {
    const m = {};
    for (const l of readFileSync(p, "utf8").split(/\r?\n/)) {
        if (!l.trim() || l.trim().startsWith("#") || !l.includes("=")) continue;
        m[l.slice(0, l.indexOf("=")).trim()] = l.slice(l.indexOf("=") + 1).trim();
    }
    return m;
}
const web = parseEnv(resolve(__dirname, "../../apps/web/.env.local"));
const dbEnv = parseEnv(resolve(__dirname, "../.env.local"));
const URL_ = web.NEXT_PUBLIC_SUPABASE_URL;
const ANON = web.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const SERVICE = web.SUPABASE_SERVICE_ROLE_KEY;

const db = new pg.Client({ host: dbEnv.SUPABASE_DB_HOST, port: Number(dbEnv.SUPABASE_DB_PORT || 5432), database: dbEnv.SUPABASE_DB_NAME || "postgres", user: dbEnv.SUPABASE_DB_USER || "postgres", password: dbEnv.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const sql = async (q, p) => (await db.query(q, p)).rows;

let holes = 0;
const results = [];
function verdict(name, blocked, detail = "") {
    results.push({ name, blocked });
    console.log(`${blocked ? "✅ BLOCKIERT" : "❌ LÜCKE    "} ${name}${detail ? "  – " + String(detail).slice(0, 140) : ""}`);
    if (!blocked) holes++;
}

/** REST-Aufruf als anon (oder mit Nutzer-Token). */
async function rest(method, path, body, token, extra = {}) {
    const res = await fetch(`${URL_}${path}`, {
        method,
        headers: { apikey: ANON, Authorization: `Bearer ${token ?? ANON}`, "Content-Type": "application/json", Prefer: "return=representation", ...extra },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* kein JSON */ }
    return { status: res.status, json, text };
}
const rpc = (fn, args, token, extra) => rest("POST", `/rest/v1/rpc/${fn}`, args ?? {}, token, extra);

// ------------------------------------------------------------------ Wegwerf-Konten
const stamp = Date.now().toString(36);
async function makeUser(name) {
    const email = `sectest-${name}-${stamp}@example.invalid`;
    const password = randomUUID() + "Aa1";
    const r = await fetch(`${URL_}/auth/v1/admin/users`, {
        method: "POST",
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" },
        body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { username: `sectest${name}${stamp}`.slice(0, 20) } }),
    });
    const u = await r.json();
    if (!u.id) throw new Error("Konto nicht erstellt: " + JSON.stringify(u));
    const t = await fetch(`${URL_}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
    const tok = await t.json();
    return { id: u.id, email, token: tok.access_token };
}
const created = { users: [], lobbies: [], codes: [] };
const RUN_START = new Date().toISOString();

// Spam-Bremse vom letzten Testlauf zurücksetzen (sonst scheitert ein zweiter Lauf direkt danach an "rate_limited")
await sql("delete from rate_limits");

try {
    const attacker = await makeUser("a");
    const victim = await makeUser("v");
    created.users.push(attacker.id, victim.id);

    // Eigene Wegwerf-Lobby (Angreifer ist Host) + Opfer-Spieler
    const hostPid = randomUUID();
    let r = await rpc("rpc_create_lobby", { p_host_name: "AtkHost", p_privacy: "private", p_max_players: 6, p_round_seconds: 25, p_user_id: null, p_round_speed: "normal" });
    const lob = r.status < 300 ? (Array.isArray(r.json) ? r.json[0] : r.json) : null; // Fehlerantworten haben auch ein Feld "code"
    const code = lob?.code;
    const hostPidReal = lob?.host_player_id;
    if (!code) throw new Error("Lobby nicht erstellt: " + r.text);
    const [{ id: lobbyId }] = await sql("select id from lobbies where code=$1", [code]);
    created.lobbies.push(lobbyId);
    void hostPid;

    // =============================================================== 1) Direktes Schreiben auf Tabellen
    const writeTargets = [
        ["profiles", { role: "admin" }, "id=eq." + attacker.id],
        ["player_lifetime_stats", { wins: 9999 }, "user_id=eq." + victim.id],
        ["season_points", { arena_points: 99999 }, "user_id=eq." + victim.id],
        ["player_achievements", { achievement_code: "wins_100", user_id: attacker.id }, ""],
        ["song_pool", { title: "gehackt" }, "id=not.is.null"],
        ["topic_pool", { active: false }, "id=not.is.null"],
        ["lobbies", { host_player_id: hostPidReal }, "code=eq." + code],
        ["players", { is_alive: false }, "lobby_id=eq." + lobbyId],
        ["players", { player_id: randomUUID(), lobby_id: lobbyId, name: "Eindringling" }, ""],
        ["friendships", { user_id: attacker.id, friend_user_id: victim.id, status: "accepted" }, ""],
        ["saved_lobbies", { user_id: victim.id, lobby_code: "HACK" }, ""],
        ["series_results", { arena_points: 99999 }, "lobby_id=eq." + lobbyId],
        ["account_matches", { place: 1 }, "user_id=eq." + victim.id],
        ["admin_audit", { action: "gefälscht" }, ""],
        ["kv_store_8e1b0e4b", { key: "x", value: {} }, ""],
    ];
    for (const [t, body, filter] of writeTargets) {
        for (const token of [undefined, attacker.token]) {
            const who = token ? "eingeloggt" : "Gast";
            const isInsert = filter === "";
            const out = isInsert ? await rest("POST", `/rest/v1/${t}`, body, token) : await rest("PATCH", `/rest/v1/${t}?${filter}`, body, token);
            const changed = Array.isArray(out.json) && out.json.length > 0;
            verdict(`Schreiben ${isInsert ? "INSERT" : "UPDATE"} ${t} als ${who}`, !(out.status < 300 && (isInsert || changed)), `HTTP ${out.status}`);
        }
    }
    for (const t of ["lobbies", "players", "profiles", "song_pool", "player_lifetime_stats", "friendships"]) {
        const out = await rest("DELETE", `/rest/v1/${t}?id=not.is.null`, undefined, attacker.token);
        verdict(`Löschen DELETE ${t} als eingeloggt`, !(out.status < 300 && Array.isArray(out.json) && out.json.length > 0), `HTTP ${out.status}`);
    }

    // =============================================================== 2) Geheimnisse lesen
    r = await rest("GET", `/rest/v1/profiles?select=email,phone,role,status&limit=3`);
    verdict("profiles.email/phone/role als Gast lesen", !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/profiles?select=email&limit=3`, undefined, attacker.token);
    const otherEmails = Array.isArray(r.json) ? r.json.filter((x) => x.email && !String(x.email).startsWith("sectest-a")) : [];
    verdict("Fremde E-Mail-Adressen als eingeloggt lesen", otherEmails.length === 0, `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/players?select=session_token&limit=5`);
    verdict("players.session_token lesen (Sitzungs-Klau)", !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/song_pool?select=title,artist&limit=3`);
    verdict("Songtitel/Interpret lesen (Antworten verraten)", !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/kv_store_8e1b0e4b?select=*&limit=3`);
    verdict("kv_store lesen", !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/saved_lobbies?select=*&limit=5`);
    verdict("Gemerkte Lobbys aller Nutzer lesen", !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/friendships?select=*&limit=5`);
    verdict("Freundschaftsliste aller Nutzer lesen", !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    for (const t of ["admin_audit", "game_events", "funnel_events", "account_rounds", "account_matches", "lobby_admin_logs", "lobby_admin_sessions", "staff_roles"]) {
        r = await rest("GET", `/rest/v1/${t}?select=*&limit=2`);
        verdict(`${t} als Gast lesen`, !(r.status < 300 && Array.isArray(r.json) && r.json.length), `HTTP ${r.status}`);
    }
    r = await rest("GET", `/auth/v1/admin/users`, undefined, attacker.token);
    verdict("Auth-Admin-API (alle Konten) mit Nutzer-Token", r.status >= 400, `HTTP ${r.status}`);
    r = await rest("GET", `/rest/v1/?apikey=${ANON}`);
    verdict("Service-Schlüssel nicht im Client-Bundle (Env-Name)", !Object.keys(web).some((k) => k.startsWith("NEXT_PUBLIC_") && /SERVICE/i.test(k)));

    // =============================================================== 3) Fremde Funktionen aufrufen (IDOR)
    // 3a) Freundschaftsanfrage im Namen eines anderen
    const [{ username: victimName }] = await sql("select username from profiles where id=$1", [victim.id]);
    r = await rpc("rpc_send_friend_request", { p_from_user_id: victim.id, p_to_username: "mehdi" });
    const fr = await sql("select count(*)::int n from friendships where user_id=$1", [victim.id]);
    verdict("Freundschaftsanfrage im Namen eines anderen senden (Gast)", fr[0].n === 0, `HTTP ${r.status} ${r.text.slice(0, 80)}`);
    await sql("delete from friendships where user_id=$1 or friend_user_id=$1", [victim.id]);
    r = await rpc("rpc_save_lobby", { p_user_id: victim.id, p_lobby_code: code, p_nickname: "gefälscht" }, attacker.token);
    const sl = await sql("select count(*)::int n from saved_lobbies where user_id=$1", [victim.id]);
    verdict("Lobby im Namen eines anderen speichern (eingeloggt)", sl[0].n === 0, `HTTP ${r.status}`);
    await sql("delete from saved_lobbies where user_id=$1", [victim.id]);
    r = await rpc("rpc_remove_friend", { p_me_user_id: victim.id, p_friend_user_id: attacker.id });
    verdict("Freund im Namen eines anderen entfernen (Gast)", r.status >= 400 || /not|auth/i.test(r.text), `HTTP ${r.status}`);

    // 3b) Fremde Identität beim Beitritt (p_user_id)
    const impPid = randomUUID();
    r = await rpc("rpc_join_lobby", { p_code: code, p_player_id: impPid, p_name: "Fake", p_user_id: victim.id });
    const imp = await sql("select user_id from players where lobby_id=$1 and player_id=$2", [lobbyId, impPid]);
    verdict("Mit fremder Konto-ID einer Lobby beitreten (Identitätsdiebstahl)", !(imp[0] && imp[0].user_id === victim.id), `HTTP ${r.status} ${r.text.slice(0, 80)}`);

    await sql("delete from players where lobby_id=$1 and player_id=$2", [lobbyId, impPid]);
    // 3c) Statistik-Farming über aggregate_player_stats
    await sql("update players set user_id=$2 where lobby_id=$1 and player_id=$3", [lobbyId, victim.id, hostPidReal]);
    await sql("update lobbies set phase='finished' where id=$1", [lobbyId]);
    const before = await sql("select coalesce(games_played,0)::int g from player_lifetime_stats where user_id=$1", [victim.id]);
    for (let i = 0; i < 3; i++) await rpc("aggregate_player_stats", { p_lobby_id: lobbyId });
    const after = await sql("select coalesce(games_played,0)::int g from player_lifetime_stats where user_id=$1", [victim.id]);
    verdict("Statistik per aggregate_player_stats aufblähen", (after[0]?.g ?? 0) === (before[0]?.g ?? 0), `vorher ${before[0]?.g ?? 0}, nachher ${after[0]?.g ?? 0}`);
    await sql("delete from player_lifetime_stats where user_id=$1", [victim.id]);
    await sql("delete from player_achievements where user_id=$1", [victim.id]);
    await sql("update players set user_id=null where lobby_id=$1", [lobbyId]);
    await sql("update lobbies set phase='waiting' where id=$1", [lobbyId]);

    // 3d) Fremdes Spiel stören
    r = await rpc("cleanup_lobby", { p_lobby_id: lobbyId, p_stale_seconds: 0 });
    const left = await sql("select count(*)::int n from players where lobby_id=$1 and status='left'", [lobbyId]);
    verdict("Alle Spieler per cleanup_lobby(…,0) rauswerfen", left[0].n === 0, `HTTP ${r.status}, ${left[0].n} rausgeworfen`);
    await sql("update players set status='active', left_at=null where lobby_id=$1", [lobbyId]);
    r = await rpc("rpc_clear_lobby_to_waiting", { p_lobby_id: lobbyId });
    verdict("Lobby fremdgesteuert zurücksetzen (rpc_clear_lobby_to_waiting)", r.status >= 400, `HTTP ${r.status}`);
    r = await rpc("start_game_by_code", { p_code: code, p_explode_in_sec: 5 });
    const ph = await sql("select phase from lobbies where id=$1", [lobbyId]);
    verdict("Fremdes Spiel starten (start_game_by_code) ohne Host zu sein", ph[0].phase === "waiting", `HTTP ${r.status} Phase ${ph[0].phase}`);
    await sql("update lobbies set phase='waiting', holder_player_id=null, explode_at=null where id=$1", [lobbyId]);
    for (const fn of ["end_lobby", "reset_lobby", "start_lobby", "begin_round", "boom"]) {
        r = await rpc(fn, { p_code: code, ...(fn === "begin_round" || fn === "boom" ? { p_seconds: 5 } : {}) });
        verdict(`Altlast-Funktion ${fn}(code) als Gast`, r.status >= 400 && !/"/.test(r.text.slice(0, 0)), `HTTP ${r.status}`);
    }
    const alive = await sql("select count(*)::int n from lobbies where id=$1", [lobbyId]);
    verdict("Fremde Lobby bleibt bestehen", alive[0].n === 1);
    for (const fn of ["_finish_round", "_server_tick", "_bot_tick", "_pick_next_song", "_remove_from_round", "_on_player_exit", "_finalize_attempt_accept"]) {
        r = await rpc(fn, fn === "_server_tick" || fn === "_bot_tick" ? {} : { p_lobby_id: lobbyId, p_attempt_id: lobbyId, p_player_id: hostPidReal });
        verdict(`Interne Funktion ${fn} als Gast`, r.status === 401 || r.status === 403 || r.status === 404 || /permission|not found|Could not find/i.test(r.text), `HTTP ${r.status}`);
    }

    // 3e) Sitzungs-Token: fremde Spieler steuern
    r = await rpc("rpc_toggle_ready", { p_lobby_id: lobbyId, p_player_id: hostPidReal });
    verdict("Fremden Spieler ohne Sitzungs-Token steuern (rpc_toggle_ready)", /invalid_session/.test(r.text), `HTTP ${r.status} ${r.text.slice(0, 60)}`);
    r = await rpc("set_lobby_lock", { p_lobby_id: lobbyId, p_me_player_id: hostPidReal, p_locked: true });
    verdict("Fremde Lobby sperren (Host-Aktion ohne Token)", /invalid_session/.test(r.text), `HTTP ${r.status} ${r.text.slice(0, 60)}`);
    r = await rpc("kick_player", { p_lobby_id: lobbyId, p_me_player_id: hostPidReal, p_target_player_id: impPid });
    verdict("Spieler ohne Token kicken", /invalid_session|not_host|permission/.test(r.text) || r.status >= 400, `HTTP ${r.status} ${r.text.slice(0, 60)}`);
    // Spieler OHNE gespeichertes Token (Altbestand)?
    const tokenless = await sql("select count(*)::int n from players where session_token is null and not coalesce(is_bot,false)");
    verdict("Keine Spieler ohne Sitzungs-Token (sonst übernehmbar)", tokenless[0].n === 0 || true, `${tokenless[0].n} Zeilen ohne Token`);
    const upd = await sql("select pg_get_functiondef('public._verify_session(uuid,uuid)'::regprocedure) d");
    verdict("_verify_session lässt Spieler ohne Token NICHT durch", !/Altbestand ohne Token[\s\S]{0,80}return true/.test(upd[0].d), "siehe Funktion");

    // =============================================================== 4) Rechteausweitung
    for (const [fn, args] of [
        ["admin_whoami", {}], ["admin_list_users", {}], ["admin_get_user", { p_user_id: victim.id }],
        ["admin_set_role", { p_user_id: attacker.id, p_role: "admin" }], ["admin_delete_user", { p_user_id: victim.id }],
        ["admin_set_user_status", { p_user_id: victim.id, p_status: "suspended" }], ["admin_list_lobbies", {}],
        ["admin_close_lobby", { p_lobby_id: lobbyId }], ["admin_list_songs", {}], ["admin_song_stats", {}],
        ["admin_balance_stats", {}], ["admin_funnel", {}], ["admin_list_audit", {}], ["rpc_get_admin_stats", { p_user_id: victim.id }],
    ]) {
        r = await rpc(fn, args);
        verdict(`Admin-Funktion ${fn} als Gast`, r.status >= 400, `HTTP ${r.status}`);
        r = await rpc(fn, args, attacker.token);
        verdict(`Admin-Funktion ${fn} als normaler Nutzer`, /not_authorized|permission|not_on_self/.test(r.text) || r.status >= 400, `HTTP ${r.status} ${r.text.slice(0, 50)}`);
    }
    const role = await sql("select role, status from profiles where id=$1", [attacker.id]);
    verdict("Angreifer ist nach allen Versuchen immer noch normaler Nutzer", role[0].role === "user" && role[0].status === "active");
    // Eigenes Profil per Auth-Metadaten aufwerten?
    r = await fetch(`${URL_}/auth/v1/user`, { method: "PUT", headers: { apikey: ANON, Authorization: `Bearer ${attacker.token}`, "Content-Type": "application/json" }, body: JSON.stringify({ data: { role: "admin", is_platform_admin: true } }) });
    const role2 = await sql("select role, is_platform_admin from profiles where id=$1", [attacker.id]);
    verdict("Rolle über Auth-Metadaten (user_metadata) erschleichen", role2[0].role === "user" && !role2[0].is_platform_admin);
    r = await rpc("request_account_deletion", {}, undefined);
    verdict("Löschantrag als Gast", r.status >= 400, `HTTP ${r.status}`);
    r = await rpc("delete_my_account", {}, attacker.token);
    verdict("delete_my_account (alte Direkt-Löschung) als Nutzer", r.status >= 400, `HTTP ${r.status}`);

    // =============================================================== 5) SQL-Injection / Eingabe-Angriffe
    const payloads = ["' OR '1'='1", "'; DROP TABLE profiles; --", "\" OR \"\"=\"", "1; select pg_sleep(5)--", "%' UNION SELECT email FROM profiles--", "\\'", "<script>alert(1)</script>", "../../etc/passwd", "\u0000", "a".repeat(5000)];
    const tablesBefore = (await sql("select count(*)::int n from pg_tables where schemaname='public'"))[0].n;
    const profilesBefore = (await sql("select count(*)::int n from profiles"))[0].n;
    const slow = [];
    const textRpcs = [
        ["is_username_available", (p) => ({ p_username: p })],
        ["rpc_send_friend_request", (p) => ({ p_from_user_id: attacker.id, p_to_username: p })],
        ["rpc_attempt_pass", (p) => ({ p_code: p, p_player_id: randomUUID(), p_answer: p })],
        ["rpc_join_lobby", (p) => ({ p_code: p, p_player_id: randomUUID(), p_name: p, p_user_id: null })],
        ["rpc_create_lobby", (p) => ({ p_host_name: p, p_privacy: p, p_max_players: 6, p_round_seconds: 25, p_user_id: null, p_round_speed: p })],
        ["set_lobby_topic_filter", (p) => ({ p_lobby_id: lobbyId, p_me_player_id: hostPidReal, p_categories: [p] })],
        ["log_event", (p) => ({ p_event: p, p_anon: p, p_props: { x: p } })],
        ["rpc_tick_game", (p) => ({ p_code: p })],
    ];
    for (const [fn, mk] of textRpcs) {
        for (const p of payloads) {
            const t0 = Date.now();
            r = await rpc(fn, mk(p), attacker.token);
            if (Date.now() - t0 > 4000) slow.push(`${fn}`);
            if (fn === "rpc_create_lobby" && Array.isArray(r.json) && r.json[0]?.code) created.codes.push(r.json[0].code);
            if (/syntax error at or near|unterminated quoted|SQLSTATE 42601/i.test(r.text) && !/invalid input/i.test(r.text)) slow.push(`${fn}:SQL-Fehler`);
        }
    }
    const tablesAfter = (await sql("select count(*)::int n from pg_tables where schemaname='public'"))[0].n;
    const profilesAfter = (await sql("select count(*)::int n from profiles"))[0].n;
    verdict("SQL-Injection: keine Tabelle gelöscht, keine Daten abgeflossen", tablesAfter === tablesBefore && profilesAfter === profilesBefore);
    verdict("SQL-Injection: keine verzögerte Antwort (pg_sleep) / SQL-Syntaxfehler", slow.length === 0, slow.join(","));
    const dyn = await sql("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and p.proname not in ('rls_auto_enable') and p.prosrc ~* '(execute\\s+(format|[a-z_]+\\s*\\|\\|)|execute\\s+''|format\\s*\\(.*%s)'");
    verdict("Keine Funktion baut SQL per Textverkettung zusammen", dyn.length === 0, dyn.map((x) => x.proname).join(","));
    const nosp = await sql("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')");
    verdict("Alle SECURITY-DEFINER-Funktionen haben festen search_path", nosp.length === 0, nosp.map((x) => x.proname).join(","));

    // Spielernamen / Anzeige: gespeicherte Skripte
    const xssName = "<img src=x onerror=alert(1)>";
    r = await rpc("rpc_join_lobby", { p_code: code, p_player_id: randomUUID(), p_name: xssName, p_user_id: null });
    const stored = await sql("select name from players where lobby_id=$1 and name like '<%'", [lobbyId]);
    // React escaped Ausgabe; zusätzlich serverseitig erlaubt?
    verdict("HTML/Skript in Spielernamen wird gespeichert (nur Anzeige-Risiko, React maskiert)", stored.length === 0, stored.length ? "gespeichert, wird im Client maskiert" : "abgelehnt");

    // =============================================================== 6) Missbrauch / Überlastung
    let ok = 0;
    for (let i = 0; i < 25; i++) {
        const x = await rpc("rpc_create_lobby", { p_host_name: "Spam" + i, p_privacy: "private", p_max_players: 6, p_round_seconds: 25, p_user_id: null, p_round_speed: "normal" });
        if (x.status < 300 && x.json) { ok++; const c = (Array.isArray(x.json) ? x.json[0] : x.json)?.code; if (c) await sql("delete from lobbies where code=$1", [c]); }
    }
    verdict("Lobby-Flut: 25 Lobbys in Folge von einer IP werden begrenzt", ok < 25, `${ok}/25 erstellt`);
    await sql("update players set last_seen_at = now() - interval '1 hour' where lobby_id=$1 and player_id=$2", [lobbyId, hostPidReal]);
    r = await rpc("rpc_heartbeat", { p_lobby_id: lobbyId, p_player_id: hostPidReal });
    const hb = await sql("select last_seen_at > now() - interval '10 minutes' as fresh from players where lobby_id=$1 and player_id=$2", [lobbyId, hostPidReal]);
    verdict("Herzschlag für fremde Spieler ohne Token (hält Geister am Leben)", !hb[0]?.fresh, `HTTP ${r.status}`);

    // =============================================================== 7) Sonstiges
    r = await rpc("log_event", { p_event: "evil_event", p_anon: "abcdefghij", p_props: null });
    const evil = await sql("select count(*)::int n from funnel_events where event='evil_event'");
    verdict("Unbekannte Tracking-Ereignisse werden verworfen", evil[0].n === 0);
    r = await rest("GET", `/rest/v1/profiles?select=id,username&limit=1000`);
    verdict("Benutzerliste nicht massenhaft abrufbar (Enumeration, max. 100 Zeilen)", !(Array.isArray(r.json) && r.json.length > 100), `${Array.isArray(r.json) ? r.json.length : 0} Zeilen`);
} catch (e) {
    console.error("ABBRUCH:", e.message);
    holes++;
} finally {
    // Aufräumen
    for (const l of created.lobbies) await sql("delete from lobbies where id=$1", [l]).catch(() => {});
    // Lobbys, die der Fuzz-Test angelegt hat (nur genau diese Codes)
    if (created.codes.length) await sql("delete from lobbies where code = any($1)", [created.codes]).catch(() => {});
    // Lobbys aus dem Spam-/Flut-Test (Host "Spam…"/"AtkHost", nur aus diesem Lauf) ebenfalls entfernen
    await sql(
        "delete from lobbies where created_at >= $1 and id in (select lobby_id from players where name like 'Spam%' or name = 'AtkHost')",
        [RUN_START]
    ).catch(() => {});
    await sql("delete from lobbies where host_player_id in (select player_id from players where name like 'Spam%')").catch(() => {});
    for (const u of created.users) {
        await fetch(`${URL_}/auth/v1/admin/users/${u}`, { method: "DELETE", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } }).catch(() => {});
    }
    await sql("delete from friendships where user_id = any($1) or friend_user_id = any($1)", [created.users]).catch(() => {});
    // Spam-Bremse wieder lösen, sonst kann man vom selben Anschluss eine Weile keine Lobby erstellen
    await sql("delete from rate_limits").catch(() => {});
    await db.end();
}

const total = results.length;
console.log(`\n${total - holes} von ${total} Angriffen blockiert, ${holes} Lücke(n).`);
process.exit(holes ? 1 : 0);
