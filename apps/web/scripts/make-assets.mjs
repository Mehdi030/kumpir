// Erzeugt die kleinen Web-Assets aus den großen Original-Bildern (einmalig ausführen):
//   node apps/web/scripts/make-assets.mjs
// Originale liegen in apps/web/assets-src/ (nicht im Web-Bundle), Ergebnisse in apps/web/public/.
import sharp from "sharp";
import { existsSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = (f) => join(root, "assets-src", f);
const out = (f) => join(root, "public", f);
if (!existsSync(src("HGLogo.png"))) throw new Error("assets-src/HGLogo.png fehlt");

// 1) Maskottchen oben auf der Startseite (halb versteckte Kartoffel): WebP statt 2,4-MB-PNG
await sharp(src("HGLogo.png")).resize({ width: 1200 }).webp({ quality: 82, effort: 6 }).toFile(out("HGLogo.webp"));

// 2) Logo (mit Schriftzug) freistellen
const logo = await sharp(src("LogoK.png")).trim().toBuffer();
const lm = await sharp(logo).metadata();

// Hintergrund: Marken-Verlauf Rot -> Orange -> Gelb
const gradientSvg = (w, h) =>
    Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">` +
            `<stop offset="0" stop-color="#8f0f0f"/><stop offset="0.35" stop-color="#c53a12"/><stop offset="0.7" stop-color="#f08a1a"/><stop offset="1" stop-color="#f6d645"/></linearGradient>` +
            `<radialGradient id="r" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#fff" stop-opacity="0.22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs>` +
            `<rect width="${w}" height="${h}" fill="url(#g)"/><rect width="${w}" height="${h}" fill="url(#r)"/></svg>`
    );

async function icon(size, file, scale) {
    const inner = Math.round(size * scale);
    const resized = await sharp(logo).resize({ width: inner, height: inner, fit: "inside" }).toBuffer();
    await sharp(gradientSvg(size, size)).composite([{ input: resized, gravity: "center" }]).png({ compressionLevel: 9, palette: true, quality: 90 }).toFile(out(file));
}
await icon(512, "icon-512.png", 0.9);
await icon(192, "icon-192.png", 0.9);
await icon(180, "apple-touch-icon.png", 0.9);
await icon(512, "icon-maskable-512.png", 0.68); // Sicherheitsrand für runde/abgeschnittene Icons

// 3) Link-Vorschau (Open Graph) 1200x630
{
    const W = 1200, H = 630;
    const logoH = 430;
    const logoBuf = await sharp(logo).resize({ height: logoH }).toBuffer();
    const text = Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">` +
            `<style>.t{font-family:Arial,Helvetica,sans-serif;font-weight:800;fill:#fff}</style>` +
            `<text x="${W / 2}" y="${H - 52}" text-anchor="middle" font-size="56" class="t">Die heiße Kartoffel mit Musik</text>` +
            `</svg>`
    );
    await sharp(gradientSvg(W, H)).composite([{ input: logoBuf, top: 40, left: Math.round((W - (await sharp(logoBuf).metadata()).width) / 2) }, { input: text }]).png({ compressionLevel: 9, palette: true, quality: 88 }).toFile(out("og.png"));
}

// 4) favicon.ico (Browser-Tab) aus dem fertigen App-Icon: ICO-Container mit PNG-Bildern 16/32/48 px
{
    const sizes = [16, 32, 48];
    const pngs = await Promise.all(sizes.map((n) => sharp(out("icon-192.png")).resize(n, n).ensureAlpha().png({ compressionLevel: 9, palette: false }).toBuffer()));
    const header = Buffer.alloc(6 + 16 * sizes.length);
    header.writeUInt16LE(0, 0);
    header.writeUInt16LE(1, 2); // Typ: Icon
    header.writeUInt16LE(sizes.length, 4);
    let offset = header.length;
    sizes.forEach((n, i) => {
        const e = 6 + i * 16;
        header.writeUInt8(n, e);
        header.writeUInt8(n, e + 1);
        header.writeUInt16LE(1, e + 4); // Farbebenen
        header.writeUInt16LE(32, e + 6); // Bit pro Pixel
        header.writeUInt32LE(pngs[i].length, e + 8);
        header.writeUInt32LE(offset, e + 12);
        offset += pngs[i].length;
    });
    writeFileSync(join(root, "src", "app", "favicon.ico"), Buffer.concat([header, ...pngs]));
}

// 5) Benachrichtigungs-Icon klein
await sharp(logo).resize({ width: 192, height: 192, fit: "inside" }).png({ compressionLevel: 9, palette: true }).toFile(out("notify-icon.png"));
console.log("fertig", lm.width + "x" + lm.height);
