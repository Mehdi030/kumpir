#!/usr/bin/env node
/**
 * One-shot env-setup. Writes apps/web/.env.local interactively if it's missing.
 * The dev server is started afterwards by the npm script (`&& next dev`)
 * so we don't have to deal with cross-platform child_process spawn quirks.
 *
 * Use: `npm run play` (vom apps/web Verzeichnis)
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline/promises";

const __filename = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(__filename), "..");
const ENV_PATH = resolve(ROOT, ".env.local");

const C = {
    bold: (s) => `\x1b[1m${s}\x1b[0m`,
    dim: (s) => `\x1b[2m${s}\x1b[0m`,
    red: (s) => `\x1b[31m${s}\x1b[0m`,
    green: (s) => `\x1b[32m${s}\x1b[0m`,
    yellow: (s) => `\x1b[33m${s}\x1b[0m`,
    cyan: (s) => `\x1b[36m${s}\x1b[0m`,
};

function parseEnv(text) {
    const map = {};
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const eq = line.indexOf("=");
        if (eq < 0) continue;
        const key = line.slice(0, eq).trim();
        let val = line.slice(eq + 1).trim();
        if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
            val = val.slice(1, -1);
        }
        map[key] = val;
    }
    return map;
}

function looksLikeSupabaseUrl(s) {
    return /^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(s.trim());
}
function looksLikeAnonKey(s) {
    // JWT-ish, three base64url segments separated by dots
    return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(s.trim());
}

async function ensureEnv() {
    if (existsSync(ENV_PATH)) {
        const env = parseEnv(readFileSync(ENV_PATH, "utf8"));
        const haveUrl = !!env.NEXT_PUBLIC_SUPABASE_URL;
        const haveKey = !!env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
        if (haveUrl && haveKey) {
            console.log(C.dim(`✓ ${ENV_PATH} existiert mit Keys – überspringe Setup.`));
            return;
        }
        console.log(C.yellow(`⚠️  ${ENV_PATH} existiert, aber Keys unvollständig. Ich frag nochmal.`));
    }

    console.log("");
    console.log(C.bold("🥔 Kumpir – einmalig Supabase-Keys einrichten"));
    console.log(C.dim("   Findest du im Supabase-Dashboard → Project Settings → API"));
    console.log("");

    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

    let url = "";
    while (!url) {
        url = (await rl.question(C.cyan("Project URL ") + C.dim("(https://xxx.supabase.co): "))).trim();
        if (!looksLikeSupabaseUrl(url)) {
            console.log(C.red("   ✗ Sieht nicht nach einer Supabase-URL aus, bitte nochmal."));
            url = "";
        }
    }

    let key = "";
    while (!key) {
        key = (await rl.question(C.cyan("Anon Key ") + C.dim("(JWT, beginnt meist mit eyJ...): "))).trim();
        if (!looksLikeAnonKey(key)) {
            console.log(C.red("   ✗ Das sieht nicht nach einem JWT aus. Achte: kein service_role Key, sondern der anon/public Key."));
            key = "";
        }
    }

    rl.close();

    const content = [
        "# Auto-erzeugt von npm run play",
        `NEXT_PUBLIC_SUPABASE_URL=${url.replace(/\/$/, "")}`,
        `NEXT_PUBLIC_SUPABASE_ANON_KEY=${key}`,
        "# Auth opt-in: setze auf 1 für strikten Gast-Modus",
        "NEXT_PUBLIC_AUTH_DISABLED=0",
        "",
    ].join("\n");

    writeFileSync(ENV_PATH, content, "utf8");
    console.log(C.green(`\n✓ ${ENV_PATH} geschrieben.\n`));
}

(async () => {
    try {
        await ensureEnv();
        console.log(C.bold("🚀 Dev-Server startet gleich …"));
        console.log(C.dim("   ⤷ http://localhost:3000"));
        console.log(C.dim("   ⤷ Tipp: 3 Inkognito-Fenster für 3 Spieler"));
        console.log(C.dim("   ⤷ Stop: Strg+C"));
        console.log("");
        process.exit(0);
    } catch (e) {
        console.error(C.red(`\n✗ Env-Setup fehlgeschlagen: ${e?.message ?? e}`));
        process.exit(1);
    }
})();
