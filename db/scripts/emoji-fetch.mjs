// Lädt für jedes benutzte Emoji die OpenMoji-Grafik (Farbe, SVG) und legt sie für nanoemoji ab.
//   node db/scripts/emoji-fetch.mjs      -> C:/Users/mehdi/emoji-build/svg/emoji_u<cp>_<cp>.svg + Bericht
// OpenMoji (https://openmoji.org) · Lizenz CC BY-SA 4.0 · Quelle: npm-Paket "openmoji" über jsDelivr
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";

const OUT = "C:/Users/mehdi/emoji-build/svg";
const VERSION = "15.1.0";
const used = JSON.parse(readFileSync("db/scripts/data/emoji-used.json", "utf8"));

const listRes = await fetch(`https://data.jsdelivr.com/v1/packages/npm/openmoji@${VERSION}?structure=flat`);
const files = new Set((await listRes.json()).files.map((f) => f.name).filter((n) => n.startsWith("/color/svg/")).map((n) => n.slice("/color/svg/".length, -4)));
console.log(`OpenMoji ${VERSION}: ${files.size} Farb-Grafiken verfügbar`);

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const report = { ok: [], missing: [] };
for (const u of used) {
    const cps = u.cps; // ohne FE0F-Sonderbehandlung: erst volle Folge, dann ohne FE0F
    const withFe = cps.join("-");
    const noFe = cps.filter((c) => c !== "FE0F").join("-");
    const cand = [withFe, noFe, noFe + "-FE0F"];
    const hit = cand.find((c) => files.has(c));
    if (!hit) {
        report.missing.push(u.emoji);
        continue;
    }
    const svg = await (await fetch(`https://cdn.jsdelivr.net/npm/openmoji@${VERSION}/color/svg/${hit}.svg`)).text();
    // nanoemoji-Namen: Codepunkte (ohne FE0F) klein, mit _ verbunden
    const name = "emoji_u" + noFe.toLowerCase().replace(/-/g, "_") + ".svg";
    writeFileSync(`${OUT}/${name}`, svg);
    report.ok.push({ emoji: u.emoji, file: hit });
}
writeFileSync("db/scripts/data/emoji-report.json", JSON.stringify({ version: VERSION, ...report }, null, 1));
console.log(`geladen: ${report.ok.length}, fehlt: ${report.missing.length} ${report.missing.join(" ")}`);
