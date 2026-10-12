// Prüft die Antwort-Erkennung (Migration 098) mit typischen Eingaben.  node db/scripts/test-answers.mjs
import { readFileSync } from "node:fs";
import pg from "pg";
const env = Object.fromEntries(readFileSync("db/.env.local", "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]));
const db = new pg.Client({ host: env.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
// [Titel, Künstler, Features, Eingabe, erwartete Punkte]
const CASES = [
    ["Guerilla", "Farid Bang", ["Samra", "Capital Bra"], "Samra", 0.5],
    ["Guerilla", "Farid Bang", ["Samra", "Capital Bra"], "capitalbra", 0.5],
    ["Guerilla", "Farid Bang", ["Samra", "Capital Bra"], "Guerilla Samra", 1.5],
    ["Guerilla", "Farid Bang", ["Samra", "Capital Bra"], "guerila", 1],
    ["Wolke 7", "Gzuz", [], "Wolke 7 Gzuz", 1.5],
    ["Wolke 7", "Gzuz", [], "Gzuz - Wolke 7", 1.5],
    ["Wolke 7", "Gzuz", [], "wolke 7 von gzuz", 1.5],
    ["Wolke 7", "Gzuz", [], "wolke7", 1],
    ["Wolke 7", "Gzuz", [], "Gzus", 0.5], // Tippfehler
    ["Wolke 7", "Gzuz", [], "Gzzzzz", 0],
    ["HOKUS POKUS", "Kurdo & Dardan", [], "Kurdo & Dardan", 0.5],
    ["HOKUS POKUS", "Kurdo & Dardan", [], "dardan und kurdo", 0.5],
    ["HOKUS POKUS", "Kurdo & Dardan", [], "hokus pokus dardan", 1.5],
    ["Früher pleite heute Benz", "Summer Cem", [], "frueher pleite heute benz", 1],
    ["Früher pleite heute Benz", "Summer Cem", [], "fruher pleite heute benz", 1],
    ["Let's Go", "Summer Cem", [], "lets go", 1],
    ["MIND ON MY $$$", "Summer Cem", [], "mind on my sss", 1],
    ["AK Ausserkontrolle", "AK AUSSERKONTROLLE", [], "AK Außerkontrolle", 1],
    ["IMMER UNTERWEGS", "AK AUSSERKONTROLLE & Haftbefehl", [], "Haftbefehl", 0.5],
    ["IMMER UNTERWEGS", "AK AUSSERKONTROLLE & Haftbefehl", [], "ak ausserkontrolle", 0.5],
    ["Vertrauen", "Nimo & Eno", [], "Eno", 0.5],
    ["Vertrauen", "Nimo & Eno", [], "Ena", 0],
    ["Vertrauen", "Nimo & Eno", [], "Vertrauen Eno Nimo", 1.5],
    ["HOKUS POKUS", "Kurdo & Dardan", [], "dardan kurdo", 0.5],
    ["Vertrauen", "Nimo & Eno", [], "Vertrauen Eno Kartoffel", 0],
    ["Bullet", "MERO & AYLIVA", [], "Ayliva Bullet", 1.5],
    ["Kaybeden", "MERO", [], "Kaybeden Mero", 1.5],
    ["Ararım Yarın", "MERO", [], "ararim yarin", 1],
    ["7 Stunden", "Capital Bra", [], "Kartoffel", 0],
    ["7 Stunden", "Capital Bra", [], "Capital Bra Kartoffel", 0],
    ["Nador", "Miami Yacine", [], "Nador Kartoffelsalat", 0],
];
let bad = 0;
for (const [t, a, f, inp, exp] of CASES) {
    const { rows } = await db.query("select public._score_song_answer($1, $2, $3, $4) p", [t, a, f, inp]);
    const got = Number(rows[0].p);
    const ok = got === exp;
    if (!ok) bad++;
    console.log(`${ok ? "✅" : "❌"} "${inp}" → ${got} (erwartet ${exp})   [${t} – ${a}${f.length ? " feat. " + f.join(", ") : ""}]`);
}
await db.end();
console.log(bad ? `\n${bad} Fehler` : `\nAlle ${CASES.length} Fälle richtig.`);
process.exit(bad ? 1 : 0);
