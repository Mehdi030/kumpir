import { CARD_FONT, fit, paintCardBackground, roundRect } from "@/lib/resultCard";

export type RecapCardInput = {
    username: string;
    monthLabel: string; // z. B. "Oktober 2026"
    tiles: { label: string; value: string }[]; // bis zu 6 Kacheln (2 Spalten)
    lines: string[]; // z. B. "Lieblings-Playlist: 80er Hits"
    siteUrl: string;
};

/** Zeichnet den Monats-Rückblick als 1080×1350-PNG (gleicher Stil wie die Ergebniskarte). */
export async function renderRecapCard(input: RecapCardInput): Promise<Blob> {
    const W = 1080;
    const H = 1350;
    const canvas = document.createElement("canvas");
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("Canvas nicht verfügbar");
    const font = CARD_FONT;

    paintCardBackground(ctx, W, H);
    ctx.textAlign = "center";
    ctx.fillStyle = "#fff";

    ctx.font = `800 40px ${font}`;
    ctx.globalAlpha = 0.85;
    ctx.fillText("Kumpir · Mein Monat", W / 2, 100);
    ctx.globalAlpha = 1;

    ctx.font = `800 92px ${font}`;
    ctx.shadowColor = "rgba(0,0,0,0.35)";
    ctx.shadowBlur = 24;
    ctx.fillText(fit(ctx, input.monthLabel, W - 120), W / 2, 220);
    ctx.shadowBlur = 0;

    ctx.font = `700 48px ${font}`;
    ctx.fillText(fit(ctx, input.username, W - 160), W / 2, 296);

    // Kacheln 2 × 3
    const tiles = input.tiles.slice(0, 6);
    const tileW = 430;
    const tileH = 170;
    const gapX = 40;
    const gapY = 28;
    const startX = (W - (tileW * 2 + gapX)) / 2;
    const startY = 360;
    tiles.forEach((tile, i) => {
        const col = i % 2;
        const row = Math.floor(i / 2);
        const x = startX + col * (tileW + gapX);
        const y = startY + row * (tileH + gapY);
        ctx.fillStyle = "rgba(0,0,0,0.26)";
        roundRect(ctx, x, y, tileW, tileH, 32);
        ctx.fill();
        ctx.textAlign = "center";
        ctx.fillStyle = "#ffe08a";
        ctx.font = `800 72px ${font}`;
        ctx.fillText(fit(ctx, tile.value, tileW - 40), x + tileW / 2, y + 92);
        ctx.fillStyle = "#fff";
        ctx.globalAlpha = 0.85;
        ctx.font = `700 30px ${font}`;
        ctx.fillText(fit(ctx, tile.label.toUpperCase(), tileW - 40), x + tileW / 2, y + 140);
        ctx.globalAlpha = 1;
    });

    let y = startY + 3 * (tileH + gapY) + 40;
    ctx.fillStyle = "#fff";
    ctx.font = `700 40px ${font}`;
    for (const line of input.lines.slice(0, 3)) {
        ctx.fillText(fit(ctx, line, W - 140), W / 2, y);
        y += 56;
    }

    ctx.font = `800 40px ${font}`;
    ctx.fillText("Spiel mit – kostenlos im Browser", W / 2, 1240);
    ctx.font = `700 44px ${font}`;
    const url = input.siteUrl.replace(/^https?:\/\//, "");
    const tw = ctx.measureText(url).width + 80;
    ctx.fillStyle = "#ffd23f";
    roundRect(ctx, (W - tw) / 2, 1264, tw, 70, 35);
    ctx.fill();
    ctx.fillStyle = "#2b0f04";
    ctx.fillText(url, W / 2, 1313);

    return await new Promise<Blob>((resolve, reject) => {
        canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("Bild konnte nicht erstellt werden"))), "image/png");
    });
}
