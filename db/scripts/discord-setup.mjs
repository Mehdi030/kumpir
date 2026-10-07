#!/usr/bin/env node
/**
 * Richtet den Kumpir-Discord ein (einmalig, darf beliebig oft wiederholt werden):
 *  1. zeigt die aktuelle Kanal-Struktur
 *  2. legt die Kategorie "📡 KUMPIR LIVE" mit Kanälen an (falls noch nicht da):
 *       🎮・spiele-live      Start + Ergebnis jedes Spiels
 *       👋・neue-spieler     neue / gelöschte Konten
 *       🛡️・admin-protokoll  Admin-Aktionen (nur für dich sichtbar)
 *       📊・tagesbericht     jeden Abend um 23 Uhr
 *  3. legt in jedem Kanal einen Webhook "Kumpir" an und trägt ihn in die Datenbank ein
 *     (private.discord_hooks, Migration 090) – ab dann schickt die Datenbank die Logs selbst
 *  4. räumt den Preview-Kanal auf: alte Vorschau-Nachrichten weg, nur die neueste bleibt
 *  5. schickt in jeden neuen Kanal eine kurze Begrüßung
 *
 * Braucht: apps/discord-bot/.env mit DISCORD_BOT_TOKEN und PREVIEW_CHANNEL_ID.
 * Der Bot braucht auf dem Server: Kanäle verwalten, Webhooks verwalten, Nachrichten verwalten.
 * Aufruf: node db/scripts/discord-setup.mjs            (nur anzeigen: --dry)
 */
import { readFileSync } from "node:fs";
import pg from "pg";

const DRY = process.argv.includes("--dry");
const env = (f) =>
    Object.fromEntries(
        readFileSync(f, "utf8")
            .split(/\r?\n/)
            .filter((l) => l.includes("=") && !l.startsWith("#"))
            .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
    );
const bot = env("apps/discord-bot/.env");
const dbe = env("db/.env.local");
const API = "https://discord.com/api/v10";
const H = { Authorization: `Bot ${bot.DISCORD_BOT_TOKEN}`, "Content-Type": "application/json" };

async function dc(method, path, body) {
    for (let attempt = 0; attempt < 5; attempt++) {
        const r = await fetch(API + path, { method, headers: H, body: body ? JSON.stringify(body) : undefined });
        if (r.status === 429) {
            const j = await r.json().catch(() => ({}));
            await new Promise((res) => setTimeout(res, Math.ceil((j.retry_after ?? 1) * 1000) + 100));
            continue;
        }
        const text = await r.text();
        const json = text ? JSON.parse(text) : null;
        if (!r.ok) throw new Error(`${method} ${path} -> ${r.status} ${text.slice(0, 200)}`);
        return json;
    }
    throw new Error(`${method} ${path}: zu viele Anfragen`);
}

const me = await fetch(`${API}/users/@me`, { headers: H });
if (!me.ok) {
    console.error("❌ Bot-Token ungültig (Discord sagt " + me.status + ").");
    console.error("   Discord Developer Portal -> deine App -> Bot -> Reset Token, neuen Token in apps/discord-bot/.env eintragen.");
    process.exit(1);
}
console.log(`✅ Angemeldet als Bot ${(await me.json()).username}`);

const preview = await dc("GET", `/channels/${bot.PREVIEW_CHANNEL_ID}`);
const guildId = preview.guild_id;
const guild = await dc("GET", `/guilds/${guildId}`);
let channels = await dc("GET", `/guilds/${guildId}/channels`);
console.log(`\nServer: ${guild.name}\n`);
const byParent = (pid) => channels.filter((c) => (c.parent_id ?? null) === pid).sort((a, b) => a.position - b.position);
for (const c of byParent(null)) {
    console.log(c.type === 4 ? `📁 ${c.name}` : `#${c.name}`);
    if (c.type === 4) for (const k of byParent(c.id)) console.log(`   ${k.type === 2 ? "🔊" : "#"}${k.name}${k.id === preview.id ? "   ← Preview-Kanal" : ""}`);
}
if (DRY) process.exit(0);

// ---------------------------------------------------------------- Kategorie + Kanäle
const CATEGORY = "📡 KUMPIR LIVE";
const WANT = [
    { key: "spiele", name: "🎮・spiele-live", topic: "Jedes Spiel automatisch: Start und Ergebnis mit Rangliste." },
    { key: "konten", name: "👋・neue-spieler", topic: "Neue und gelöschte Konten – automatisch." },
    { key: "admin", name: "🛡️・admin-protokoll", topic: "Admin-Aktionen aus dem Protokoll (nur für das Team sichtbar).", private: true },
    { key: "bericht", name: "📊・tagesbericht", topic: "Jeden Abend um 23 Uhr: Matches, Spieler, neue Konten." },
];

let cat = channels.find((c) => c.type === 4 && c.name.toLowerCase() === CATEGORY.toLowerCase());
if (!cat) {
    cat = await dc("POST", `/guilds/${guildId}/channels`, { name: CATEGORY, type: 4 });
    console.log(`\n➕ Kategorie angelegt: ${CATEGORY}`);
}
const VIEW = String(1 << 10);
const db = new pg.Client({ host: dbe.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: dbe.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();

for (const w of WANT) {
    let ch = channels.find((c) => c.type === 0 && c.name === w.name);
    if (!ch) {
        ch = await dc("POST", `/guilds/${guildId}/channels`, {
            name: w.name,
            type: 0,
            topic: w.topic,
            parent_id: cat.id,
            // privater Kanal: @everyone sieht ihn nicht (Server-Inhaber und Admins schon)
            permission_overwrites: w.private ? [{ id: guildId, type: 0, deny: VIEW, allow: "0" }] : [],
        });
        console.log(`➕ Kanal angelegt: #${w.name}`);
    }
    const hooks = await dc("GET", `/channels/${ch.id}/webhooks`);
    let hook = hooks.find((h) => h.name === "Kumpir" && h.token);
    if (!hook) hook = await dc("POST", `/channels/${ch.id}/webhooks`, { name: "Kumpir" });
    const url = `https://discord.com/api/webhooks/${hook.id}/${hook.token}`;
    await db.query("insert into private.discord_hooks(channel, url) values ($1, $2) on conflict (channel) do update set url = excluded.url, updated_at = now()", [w.key, url]);
    console.log(`🔗 #${w.name} ist mit der Datenbank verbunden`);
    await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: "Kumpir", embeds: [{ title: "✅ Kanal ist verbunden", description: w.topic, color: 16750615 }] }),
    });
}
await db.end();

// ---------------------------------------------------------------- Preview-Kanal aufräumen
const msgs = await dc("GET", `/channels/${preview.id}/messages?limit=100`);
const isPreview = (m) => {
    const t = `${m.content ?? ""} ${(m.embeds ?? []).map((e) => e.title ?? "").join(" ")}`.toLowerCase();
    return t.includes("spiel-vorschau") || t.includes("neueste version") || t.includes("deploy fehlgeschlagen");
};
const previews = msgs.filter(isPreview).sort((a, b) => b.id.localeCompare(a.id, undefined, { numeric: true }));
const old = previews.slice(1);
for (const m of old) {
    await dc("DELETE", `/channels/${preview.id}/messages/${m.id}`).catch((e) => console.log("   konnte nicht löschen:", e.message));
}
console.log(`\n🧹 Preview-Kanal: ${old.length} alte Vorschau-Nachricht(en) gelöscht, die neueste bleibt.`);
console.log("\nFertig. Ab jetzt landen Spiele, neue Konten, Admin-Aktionen und der Tagesbericht automatisch in Discord.");
