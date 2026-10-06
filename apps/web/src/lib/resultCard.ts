export type ResultCardRow = { place: number; name: string; score: number; isMe?: boolean };

export type ResultCardInput = {
    winnerName: string;
    isSeries: boolean;
    totalRounds: number;
    me: { place: number; score: number } | null;
    rows: ResultCardRow[];
    siteUrl: string;
};

const MEDAL = ["🥇", "🥈", "🥉"];

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
}

function fit(ctx: CanvasRenderingContext2D, text: string, maxW: number): string {
    if (ctx.measureText(text).width <= maxW) return text;
    let t = text;
    while (t.length > 1 && ctx.measureText(`${t}…`).width > maxW) t = t.slice(0, -1);
    return `${t}…`;
}

/** Zeichnet eine 1080×1350-Ergebniskarte (Hochformat, gut für Stories/Chats) und liefert sie als PNG. */
export async function renderResultCard(input: ResultCardInput): Promise<Blob> {
    const W = 1080;
    const H = 1350;
    const canvas = document.createElement("canvas");
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("Canvas nicht verfügbar");

    const font = "'Bricolage Grotesque', 'Segoe UI', system-ui, -apple-system, Arial, sans-serif";

    // Hintergrund: Marken-Verlauf
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, "#8f0f0f");
    g.addColorStop(0.4, "#c53a12");
    g.addColorStop(0.8, "#f08a1a");
    g.addColorStop(1, "#f6d645");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    const glow = ctx.createRadialGradient(W / 2, 380, 40, W / 2, 380, 640);
    glow.addColorStop(0, "rgba(255,255,255,0.28)");
    glow.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = glow;
    ctx.fillRect(0, 0, W, H);

    ctx.textAlign = "center";
    ctx.fillStyle = "#fff";

    ctx.font = `800 40px ${font}`;
    ctx.globalAlpha = 0.85;
    ctx.fillText("Kumpir · Die heiße Kartoffel mit Musik", W / 2, 100);
    ctx.globalAlpha = 1;

    ctx.font = `800 36px ${font}`;
    ctx.globalAlpha = 0.9;
    ctx.fillText(input.isSeries ? `MATCH BEENDET · ${input.totalRounds} RUNDEN` : "RUNDE BEENDET", W / 2, 160);
    ctx.globalAlpha = 1;

    // Pokal
    ctx.font = `140px ${font}`;
    ctx.fillText("🏆", W / 2, 330);

    ctx.font = `800 96px ${font}`;
    ctx.shadowColor = "rgba(0,0,0,0.35)";
    ctx.shadowBlur = 24;
    ctx.fillText(fit(ctx, input.winnerName, W - 120), W / 2, 460);
    ctx.shadowBlur = 0;
    ctx.font = `600 40px ${font}`;
    ctx.globalAlpha = 0.9;
    ctx.fillText(input.isSeries ? "gewinnt das Match" : "gewinnt die Runde", W / 2, 520);
    ctx.globalAlpha = 1;

    // Tabelle (Top 5, eigene Zeile immer dabei)
    const rows = input.rows.slice(0, 5);
    const meRow = input.rows.find((r) => r.isMe);
    if (meRow && !rows.includes(meRow)) rows[rows.length - 1] = meRow;
    const rowH = 96;
    let y = 590;
    for (const r of rows) {
        ctx.fillStyle = r.isMe ? "rgba(34,211,238,0.28)" : r.place === 1 ? "rgba(255,214,10,0.28)" : "rgba(0,0,0,0.26)";
        roundRect(ctx, 80, y, W - 160, rowH - 12, 28);
        ctx.fill();
        if (r.isMe) {
            ctx.strokeStyle = "rgba(34,211,238,0.9)";
            ctx.lineWidth = 4;
            ctx.stroke();
        }
        ctx.fillStyle = "#fff";
        ctx.textAlign = "left";
        ctx.font = `800 44px ${font}`;
        ctx.fillText(MEDAL[r.place - 1] ?? String(r.place), 112, y + 56);
        ctx.font = `800 44px ${font}`;
        ctx.fillText(fit(ctx, r.name, 520), 200, y + 56);
        ctx.textAlign = "right";
        ctx.fillStyle = "#ffe08a";
        ctx.fillText(`${r.score} Pkt`, W - 112, y + 56);
        y += rowH;
    }

    ctx.textAlign = "center";
    ctx.fillStyle = "#fff";
    if (input.me) {
        ctx.font = `800 52px ${font}`;
        ctx.fillText(`Ich: Platz ${input.me.place} · ${input.me.score} Punkte`, W / 2, Math.max(y + 70, 1130));
    }

    ctx.font = `800 40px ${font}`;
    ctx.fillText("Spiel mit – kostenlos im Browser", W / 2, 1240);
    ctx.font = `700 44px ${font}`;
    ctx.fillStyle = "#2b0f04";
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
