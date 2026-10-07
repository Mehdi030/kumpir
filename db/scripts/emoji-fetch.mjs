// Lädt für jedes benutzte Emoji die Microsoft-Fluent-Emoji-Grafik ("Color", SVG) und legt sie für nanoemoji ab.
//   node db/scripts/emoji-fetch.mjs      -> C:/Users/mehdi/emoji-build/svg/emoji_u<cp>_<cp>.svg + Bericht
// Fluent Emoji (https://github.com/microsoft/fluentui-emoji) · Lizenz MIT
// Quelle: npm-Pakete "@iconify-json/fluent-emoji" (Grafiken) und "unicode-emoji-json" (Emoji -> Name).
// Fluent nutzt für Glanz/Schatten Weichzeichner-Filter, die eine Farbschrift nicht kann: die Filter werden
// entfernt, die Formen bleiben (sieht praktisch gleich aus, getestet 2026-10-07).
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";

const BUILD = "C:/Users/mehdi/emoji-build";
const OUT = `${BUILD}/svg`;
const PKG = `${BUILD}/pkg`;
const FLUENT = "@iconify-json/fluent-emoji@1.2.7";
const NAMES = "unicode-emoji-json@0.9.0";

// Pakete einmal holen und entpacken
mkdirSync(PKG, { recursive: true });
for (const [spec, dir] of [
    [FLUENT, "fluent"],
    [NAMES, "names"],
]) {
    if (existsSync(`${PKG}/${dir}/package/package.json`)) continue;
    const tgz = execSync(`npm pack ${spec} --silent`, { cwd: PKG }).toString().trim().split("\n").pop();
    mkdirSync(`${PKG}/${dir}`, { recursive: true });
    execSync(`tar -xzf "${tgz}" -C "${dir}"`, { cwd: PKG });
}
const icons = JSON.parse(readFileSync(`${PKG}/fluent/package/icons.json`, "utf8"));
const byEmoji = JSON.parse(readFileSync(`${PKG}/names/package/data-by-emoji.json`, "utf8"));
const W = icons.width ?? 32;
const H = icons.height ?? 32;

// Namen, die zwischen Unicode-Liste und Fluent abweichen
const EXTRA = { "👢": "womans-boot", "🕘": "nine-oclock" };

// Fluent zeichnet diese Emojis sehr dunkel -> auf dem dunklen Spiel-Hintergrund kaum sichtbar: Farben aufhellen
const LIGHTEN = { "🎵": 0.55, "👥": 0.5, "👤": 0.5, "🎶": 0.55 };
function lighten(svg, k) {
    const mix = (h) => {
        const n = parseInt(h, 16);
        const c = [n >> 16, (n >> 8) & 255, n & 255].map((v) => Math.round(v + (255 - v) * k));
        return c.map((v) => v.toString(16).padStart(2, "0")).join("");
    };
    // Ein Durchlauf: #rrggbb oder #rgb (nicht doppelt umfärben)
    return svg.replace(/#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-fA-F])/g, (_, h) =>
        "#" + mix(h.length === 3 ? h.split("").map((c) => c + c).join("") : h)
    );
}

const used = JSON.parse(readFileSync("db/scripts/data/emoji-used.json", "utf8"));
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const report = { ok: [], missing: [] };
for (const u of used) {
    const e = u.emoji;
    const info = byEmoji[e] ?? byEmoji[e.replace(/\uFE0F/g, "")] ?? byEmoji[e + "\uFE0F"];
    const slug = EXTRA[e] ?? (info ? info.slug.replace(/_/g, "-") : null);
    const name = slug && (icons.icons[slug] ? slug : icons.aliases?.[slug]?.parent);
    if (!name) {
        report.missing.push(e);
        continue;
    }
    const ic = icons.icons[name];
    // Filter weg; nanoemoji kennt bei <use> nur xlink:href
    const body = ic.body.replace(/\sfilter="url\([^)]*\)"/g, "").replace(/<use href=/g, "<use xlink:href=");
    let svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 ${ic.width ?? W} ${ic.height ?? H}">${body}</svg>`;
    const lk = LIGHTEN[e] ?? LIGHTEN[e.replace(/\uFE0F/g, "")];
    if (lk) svg = lighten(svg, lk);
    // nanoemoji-Namen: Codepunkte (ohne FE0F) klein, mit _ verbunden
    const noFe = u.cps.filter((c) => c !== "FE0F").join("_").toLowerCase();
    writeFileSync(`${OUT}/emoji_u${noFe}.svg`, svg);
    report.ok.push({ emoji: e, name });
}
writeFileSync("db/scripts/data/emoji-report.json", JSON.stringify({ source: FLUENT, ...report }, null, 1));
console.log(`geladen: ${report.ok.length}, fehlt (bleibt System-Emoji): ${report.missing.length} ${report.missing.join(" ")}`);
