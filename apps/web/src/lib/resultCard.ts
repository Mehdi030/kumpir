export type ResultCardRow = { place: number; name: string; score: number; isMe?: boolean };

export type ResultCardInput = {
    winnerName: string;
    isSeries: boolean;
    totalRounds: number;
    me: { place: number; score: number } | null;
    rows: ResultCardRow[];
    siteUrl: string;
    /** Fertig übersetzte Texte (Deutsch/Englisch je nach gewählter Sprache). */
    labels: {
        tagline: string;
        header: string;
        wins: string;
        me: string | null;
        pts: string;
        cta: string;
    };
};

const MEDAL = ["🥇", "🥈", "🥉"];

export function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
}

export function fit(ctx: CanvasRenderingContext2D, text: string, maxW: number): string {
    if (ctx.measureText(text).width <= maxW) return text;
    let t = text;
    while (t.length > 1 && ctx.measureText(`${t}…`).width > maxW) t = t.slice(0, -1);
    return `${t}…`;
}

export const CARD_FONT = "'Kumpir Emoji', 'Bricolage Grotesque', 'Segoe UI', system-ui, -apple-system, Arial, sans-serif";

/** Marken-Verlauf (Rot -> Orange -> Gelb) mit hellem Schein – gemeinsam für alle Teilen-Bilder. */
export function paintCardBackground(ctx: CanvasRenderingContext2D, W: number, H: number) {
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
}

/** Bild teilen (Handy: System-Teilen mit Datei) oder als PNG herunterladen. Gibt "shared" / "saved" zurück. */
export async function shareOrDownloadPng(blob: Blob, fileName: string, text: string, title: string): Promise<"shared" | "saved" | "aborted"> {
    const file = new File([blob], fileName, { type: "image/png" });
    const nav = navigator as Navigator & { canShare?: (d: ShareData) => boolean };
    if (typeof nav.canShare === "function" && nav.canShare({ files: [file] })) {
        try {
            await navigator.share({ files: [file], text, title });
            return "shared";
        } catch (e) {
            if (e instanceof Error && e.name === "AbortError") return "aborted";
        }
    }
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    window.setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    return "saved";
}

const PODIUM_COLORS: Record<number, { top: string; mid: string; low: string; ink: string; ring: string }> = {
    1: { top: "#ffe58a", mid: "#e0a420", low: "#a86f08", ink: "#3d2600", ring: "rgba(255,214,10,0.9)" },
    2: { top: "#f1f4f9", mid: "#b4bfce", low: "#7d8899", ink: "#1f2733", ring: "rgba(226,232,240,0.9)" },
    3: { top: "#f0b27a", mid: "#c07a3e", low: "#8a5222", ink: "#3a1c06", ring: "rgba(222,148,84,0.9)" },
};

/** Siegerpodest im Stil des Endbildschirms (Scheinwerfer, Sockel Gold/Silber/Bronze, Krone). Gibt die y-Position für den Rest zurück. */
function paintPodium(ctx: CanvasRenderingContext2D, W: number, top: ResultCardRow[], pts: string, font: string): number {
    const base = 900;
    const slotW = 300;
    const gap = 24;
    const order = top.length >= 3 ? [top[1], top[0], top[2]] : [top[1], top[0]];
    const startX = W / 2 - (order.length * slotW + (order.length - 1) * gap) / 2;
    const heights: Record<number, number> = { 1: 300, 2: 220, 3: 160 };

    // Bodenschein
    const floor = ctx.createRadialGradient(W / 2, base + 10, 20, W / 2, base + 10, 520);
    floor.addColorStop(0, "rgba(255,226,140,0.55)");
    floor.addColorStop(1, "rgba(255,226,140,0)");
    ctx.save();
    ctx.scale(1, 0.18);
    ctx.fillStyle = floor;
    ctx.beginPath();
    ctx.arc(W / 2, (base + 10) / 0.18, 520, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();

    order.forEach((r, i) => {
        const place = Math.min(r.place, 3);
        const col = PODIUM_COLORS[place];
        const x = startX + i * (slotW + gap);
        const cx = x + slotW / 2;
        const h = heights[place];
        const topY = base - h;

        // Scheinwerferkegel
        const beam = ctx.createLinearGradient(0, 200, 0, base);
        beam.addColorStop(0, "rgba(255,246,214,0.45)");
        beam.addColorStop(1, "rgba(255,236,170,0)");
        ctx.fillStyle = beam;
        ctx.beginPath();
        ctx.moveTo(cx - 30, 200);
        ctx.lineTo(cx + 30, 200);
        ctx.lineTo(cx + slotW / 2 + 10, base);
        ctx.lineTo(cx - slotW / 2 - 10, base);
        ctx.closePath();
        ctx.fill();

        // Sockel
        const g = ctx.createLinearGradient(0, topY, 0, base);
        g.addColorStop(0, col.top);
        g.addColorStop(0.55, col.mid);
        g.addColorStop(1, col.low);
        ctx.shadowColor = "rgba(0,0,0,0.4)";
        ctx.shadowBlur = 30;
        ctx.shadowOffsetY = 14;
        ctx.fillStyle = g;
        roundRect(ctx, x, topY, slotW, h, 22);
        ctx.fill();
        ctx.shadowColor = "transparent";
        ctx.shadowBlur = 0;
        ctx.shadowOffsetY = 0;
        ctx.strokeStyle = "rgba(255,255,255,0.7)";
        ctx.lineWidth = 3;
        ctx.stroke();
        // Glanzkante
        ctx.fillStyle = "rgba(255,255,255,0.35)";
        roundRect(ctx, x + 6, topY + 6, slotW - 12, 10, 5);
        ctx.fill();

        ctx.textAlign = "center";
        ctx.fillStyle = col.ink;
        ctx.font = `900 ${place === 1 ? 110 : place === 2 ? 90 : 72}px ${font}`;
        ctx.fillText(String(r.place), cx, topY + (place === 1 ? 128 : place === 2 ? 108 : 90));
        ctx.font = `800 36px ${font}`;
        ctx.fillText(`${String(r.score).replace(".", ",")} ${pts}`, cx, base - 28);

        // Avatar (Anfangsbuchstabe im Ring), Namensschild
        const rad = place === 1 ? 92 : 72;
        const ay = topY - 70 - rad;
        ctx.shadowColor = col.ring;
        ctx.shadowBlur = place === 1 ? 40 : 18;
        ctx.fillStyle = "rgba(255,255,255,0.18)";
        ctx.beginPath();
        ctx.arc(cx, ay, rad + 8, 0, Math.PI * 2);
        ctx.fill();
        ctx.shadowBlur = 0;
        const ag = ctx.createRadialGradient(cx - rad / 3, ay - rad / 3, 6, cx, ay, rad);
        ag.addColorStop(0, "#fff6d6");
        ag.addColorStop(1, col.mid);
        ctx.fillStyle = ag;
        ctx.beginPath();
        ctx.arc(cx, ay, rad, 0, Math.PI * 2);
        ctx.fill();
        ctx.lineWidth = 6;
        ctx.strokeStyle = col.ring;
        ctx.stroke();
        ctx.fillStyle = col.ink;
        ctx.font = `900 ${Math.round(rad * 1.05)}px ${font}`;
        ctx.fillText((r.name.trim()[0] ?? "?").toUpperCase(), cx, ay + rad * 0.37);
        ctx.font = `${place === 1 ? 64 : 48}px ${font}`;
        ctx.fillText(MEDAL[place - 1], cx + rad * 0.8, ay + rad * 0.95);
        if (place === 1) {
            ctx.font = `84px ${font}`;
            ctx.fillText("👑", cx, ay - rad - 6);
        }

        // Namensschild
        ctx.font = `800 ${place === 1 ? 42 : 34}px ${font}`;
        const label = fit(ctx, r.name, slotW - 40);
        const tw = Math.min(slotW + 10, ctx.measureText(label).width + 44);
        ctx.fillStyle = r.isMe ? "rgba(8,60,70,0.85)" : "rgba(22,8,6,0.72)";
        roundRect(ctx, cx - tw / 2, topY - 56, tw, 46, 23);
        ctx.fill();
        if (r.isMe) {
            ctx.strokeStyle = "rgba(34,211,238,0.9)";
            ctx.lineWidth = 3;
            ctx.stroke();
        }
        ctx.fillStyle = "#fff";
        ctx.fillText(label, cx, topY - 22);
    });

    return base + 50;
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

    // Emoji-Schrift muss geladen sein, sonst zeichnet das Bild System-Emojis
    try {
        await document.fonts.load("100px 'Kumpir Emoji'", "🏆🥔🥇");
    } catch {
        /* ohne Schrift: System-Emoji */
    }
    const font = CARD_FONT;

    paintCardBackground(ctx, W, H);

    ctx.textAlign = "center";
    ctx.fillStyle = "#fff";

    ctx.font = `800 40px ${font}`;
    ctx.globalAlpha = 0.85;
    ctx.fillText(input.labels.tagline, W / 2, 100);
    ctx.globalAlpha = 1;

    ctx.font = `800 36px ${font}`;
    ctx.globalAlpha = 0.9;
    ctx.fillText(input.labels.header.toUpperCase(), W / 2, 160);
    ctx.globalAlpha = 1;

    const sorted = [...input.rows].sort((x, y) => x.place - y.place);
    const top = sorted.slice(0, 3);
    let y = 590;

    if (top.length >= 2) {
        y = paintPodium(ctx, W, top, input.labels.pts, font);
    } else {
        // nur ein Mensch: Pokal wie bisher
        ctx.font = `140px ${font}`;
        ctx.fillText("🏆", W / 2, 330);
        ctx.font = `800 96px ${font}`;
        ctx.shadowColor = "rgba(0,0,0,0.35)";
        ctx.shadowBlur = 24;
        ctx.fillText(fit(ctx, input.winnerName, W - 120), W / 2, 460);
        ctx.shadowBlur = 0;
        ctx.font = `600 40px ${font}`;
        ctx.globalAlpha = 0.9;
        ctx.fillText(input.labels.wins, W / 2, 520);
        ctx.globalAlpha = 1;
    }

    // Rest der Wertung (ab Platz 4; die eigene Zeile ist immer dabei), kompakt unter dem Podest
    const rest = sorted.slice(top.length >= 2 ? top.length : 0, (top.length >= 2 ? top.length : 0) + 3);
    const meRow = sorted.find((r) => r.isMe);
    if (meRow && !rest.includes(meRow) && !top.includes(meRow)) rest[rest.length ? rest.length - 1 : 0] = meRow;
    const rowH = top.length >= 2 ? 78 : 96;
    for (const r of rest) {
        ctx.fillStyle = r.isMe ? "rgba(34,211,238,0.28)" : "rgba(0,0,0,0.26)";
        roundRect(ctx, 80, y, W - 160, rowH - 12, 26);
        ctx.fill();
        if (r.isMe) {
            ctx.strokeStyle = "rgba(34,211,238,0.9)";
            ctx.lineWidth = 4;
            ctx.stroke();
        }
        ctx.fillStyle = "#fff";
        ctx.textAlign = "left";
        ctx.font = `800 40px ${font}`;
        ctx.fillText(MEDAL[r.place - 1] ?? String(r.place), 112, y + rowH / 2 + 8);
        ctx.fillText(fit(ctx, r.name, 520), 200, y + rowH / 2 + 8);
        ctx.textAlign = "right";
        ctx.fillStyle = "#ffe08a";
        ctx.fillText(`${String(r.score).replace(".", ",")} ${input.labels.pts}`, W - 112, y + rowH / 2 + 8);
        y += rowH;
    }

    ctx.textAlign = "center";
    ctx.fillStyle = "#fff";
    if (input.labels.me) {
        ctx.font = `800 52px ${font}`;
        ctx.fillText(input.labels.me, W / 2, Math.max(y + 70, 1130));
    }

    ctx.font = `800 40px ${font}`;
    ctx.fillText(input.labels.cta, W / 2, 1240);
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
