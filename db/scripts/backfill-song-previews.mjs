#!/usr/bin/env node
/**
 * Füllt song_pool.preview_url einmalig über die iTunes Search API, damit
 * SongRound.tsx im Spiel selbst nie mehr live nachfragen muss (siehe
 * Migration 036). Idempotent: überspringt Songs, die schon eine
 * preview_url haben, außer --force ist gesetzt.
 *
 * Aufruf:
 *   node db/scripts/backfill-song-previews.mjs           # nur fehlende
 *   node db/scripts/backfill-song-previews.mjs --force   # alle neu ziehen
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dbDir = resolve(__dirname, "..");
const force = process.argv.includes("--force");

function parseEnv(text) {
    const map = {};
    for (const line of text.split(/\r?\n/)) {
        if (!line.trim() || line.trim().startsWith("#")) continue;
        const i = line.indexOf("=");
        if (i < 0) continue;
        map[line.slice(0, i).trim()] = line.slice(i + 1);
    }
    return map;
}

const env = parseEnv(readFileSync(resolve(dbDir, ".env.local"), "utf8"));
const client = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Wirft bei einem Request-/Parse-Fehler (iTunes liefert gelegentlich eine
// leere/kaputte Antwort) -- der Aufrufer lässt den Song dann OHNE
// preview_checked_at stehen, damit ein erneuter Lauf ihn automatisch
// nochmal versucht, statt ihn fälschlich als "geprüft, kein Treffer"
// abzuspeichern.
async function lookupPreview(title, artist) {
    const query = [title, artist].filter(Boolean).join(" ");
    // entity=song wurde testweise ergänzt (ein Musikvideo landete bei
    // "Lose Yourself" auf Platz 1, ohne previewUrl) -- lieferte aber in der
    // Praxis DEUTLICH weniger Treffer insgesamt (68 -> 1 von 36 Restposten),
    // weil es viele echte Song-Treffer zu strikt rausfiltert. Wieder entfernt.
    const res = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(query)}&media=music&country=DE&limit=1`);
    if (!res.ok) {
        // Apple antwortet bei Rate-Limiting mit 403 + leerem Body statt einem
        // JSON-Fehler -- OHNE diese Prüfung sah das wie "kein Treffer" aus und
        // wurde fälschlich dauerhaft als geprüft abgespeichert (traf sogar
        // Welthits wie "Hotel California" oder "Smells Like Teen Spirit").
        throw new Error(`iTunes antwortete mit HTTP ${res.status}`);
    }
    const text = await res.text();
    const json = text ? JSON.parse(text) : null;
    return json?.results?.[0]?.previewUrl ?? null;
}

await client.connect();
try {
    const { rows } = await client.query(
        force
            ? "select id, title, artist from song_pool order by title"
            : "select id, title, artist from song_pool where preview_checked_at is null order by title"
    );

    console.log(`${rows.length} Song(s) zu prüfen...`);
    let found = 0;
    let missed = 0;
    let failed = 0;

    for (const row of rows) {
        let url = null;
        let ok = false;
        for (let attempt = 0; attempt < 2 && !ok; attempt++) {
            try {
                url = await lookupPreview(row.title, row.artist);
                ok = true;
            } catch (e) {
                if (attempt === 0) {
                    await sleep(5000); // kurzer Cooldown, dann ein zweiter Versuch
                } else {
                    failed++;
                    console.log(`  ❌ Request fehlgeschlagen (wird beim nächsten Lauf erneut versucht): ${row.title} — ${e.message}`);
                }
            }
        }
        if (!ok) {
            await sleep(1500);
            continue;
        }

        await client.query("update song_pool set preview_url = $1, preview_checked_at = now() where id = $2", [url, row.id]);
        if (url) {
            found++;
            console.log(`  ✅ ${row.title}${row.artist ? " — " + row.artist : ""}`);
        } else {
            missed++;
            console.log(`  ⚠️  kein Preview gefunden: ${row.title}${row.artist ? " — " + row.artist : ""}`);
        }
        await sleep(1500); // iTunes-API nicht überrennen -- war bei 200ms spürbar rate-limitet
    }

    console.log(`\nFertig. ${found} mit Preview, ${missed} ohne Treffer, ${failed} Request-Fehler (erneut versuchen: gleicher Aufruf ohne --force).`);
} finally {
    await client.end();
}
