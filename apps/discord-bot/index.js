import "dotenv/config";
import express from "express";
import {
    Client,
    GatewayIntentBits,
    Partials,
    PermissionsBitField,
    EmbedBuilder
} from "discord.js";

const TOKEN = process.env.DISCORD_BOT_TOKEN;
const PREVIEW_CHANNEL_ID = process.env.PREVIEW_CHANNEL_ID;

// Optional: Wenn du trotzdem nur “erwartete” Webhook-Messages aufräumen willst
// (für Bot-posts ist message.webhookId = null). Daher eher nicht erzwingen.
const PREVIEW_WEBHOOK_ID = process.env.PREVIEW_WEBHOOK_ID || null;

const KEEP_LATEST = Number(process.env.KEEP_LATEST || "1");

// Webhook Server
const PORT = Number(process.env.PORT || "3001");
const VERCEL_WEBHOOK_SECRET = process.env.VERCEL_WEBHOOK_SECRET || null;

if (!TOKEN) throw new Error("Missing DISCORD_BOT_TOKEN");
if (!PREVIEW_CHANNEL_ID) throw new Error("Missing PREVIEW_CHANNEL_ID");

const client = new Client({
    intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent
    ],
    partials: [Partials.Channel, Partials.Message]
});

function isPreviewMessage(message) {
    const content = (message.content || "").toLowerCase();
    return content.includes("aktuelle spiel-vorschau") && content.includes("kumpir");
}

function isFromExpectedWebhook(message) {
    // Achtung: Bot-Nachrichten haben webhookId = null.
    // Wenn du PREVIEW_WEBHOOK_ID setzt, würde der Bot seine eigenen Messages NICHT cleanupen.
    // Daher: Wenn PREVIEW_WEBHOOK_ID gesetzt ist, erlauben wir zusätzlich Bot-User.
    if (!PREVIEW_WEBHOOK_ID) return true;

    if (message.webhookId === PREVIEW_WEBHOOK_ID) return true;
    if (message.author?.bot && message.author?.id === client.user?.id) return true;

    return false;
}

async function cleanupPreviewChannel(channel) {
    const me = channel.guild.members.me;
    if (!me) return;

    const perms = channel.permissionsFor(me);
    if (!perms?.has(PermissionsBitField.Flags.ManageMessages)) {
        console.log("Missing ManageMessages permission in preview channel.");
        return;
    }

    const fetched = await channel.messages.fetch({ limit: 50 });

    const previews = [...fetched.values()]
        .filter((m) => isPreviewMessage(m) && isFromExpectedWebhook(m))
        .sort((a, b) => b.createdTimestamp - a.createdTimestamp);

    const toDelete = previews.slice(KEEP_LATEST);

    if (toDelete.length === 0) return;

    console.log(`Cleanup: deleting ${toDelete.length} old preview messages...`);

    for (const msg of toDelete) {
        try {
            await msg.delete();
        } catch (e) {
            console.log(`Failed to delete message ${msg.id}:`, e?.message || e);
        }
    }
}

async function postPreview({ url, branch, status, commitSha }) {
    const channel = await client.channels.fetch(PREVIEW_CHANNEL_ID);
    if (!channel?.isTextBased()) throw new Error("Preview channel not found / not text-based");

    const safeUrl = url || "(keine URL übergeben)";
    const safeBranch = branch || "unknown";
    const safeStatus = status || "unknown";
    const shortSha = commitSha ? commitSha.slice(0, 7) : null;

    // Content so formuliert, dass isPreviewMessage() greift:
    const contentLines = [
        "🎮 **Aktuelle Spiel-Vorschau (Kumpir)**",
        `Status: **${safeStatus}**`,
        `Branch: **${safeBranch}**`,
        shortSha ? `Commit: **${shortSha}**` : null,
        `Link: ${safeUrl}`
    ].filter(Boolean);

    // Optional: als Embed (schöner)
    const embed = new EmbedBuilder()
        .setTitle("Aktuelle Spiel-Vorschau (Kumpir)")
        .setDescription(`Status: **${safeStatus}**\nBranch: **${safeBranch}**${shortSha ? `\nCommit: **${shortSha}**` : ""}`)
        .addFields({ name: "Preview", value: safeUrl })
        .setTimestamp(new Date());

    await channel.send({ content: contentLines.join("\n"), embeds: [embed] });

    // Direkt danach cleanup (damit im Kanal nur das neueste bleibt)
    await cleanupPreviewChannel(channel);
}

client.on("ready", () => {
    console.log(`Logged in as ${client.user.tag}`);
});

// Dein bisheriger Auto-Cleanup wenn jemand/etwas im Preview-Kanal postet
client.on("messageCreate", async (message) => {
    try {
        if (!message.guild) return;
        if (message.channelId !== PREVIEW_CHANNEL_ID) return;

        if (!isPreviewMessage(message)) return;
        if (!isFromExpectedWebhook(message)) return;

        await cleanupPreviewChannel(message.channel);
    } catch (e) {
        console.log("messageCreate error:", e?.message || e);
    }
});

// ===== Webhook Server =====
const app = express();
app.use(express.json({ limit: "2mb" }));

app.post("/vercel", async (req, res) => {
    try {
        // Simple Secret check (Header frei wählbar)
        if (VERCEL_WEBHOOK_SECRET) {
            const provided = req.header("x-vercel-secret");
            if (provided !== VERCEL_WEBHOOK_SECRET) {
                return res.status(401).send("Unauthorized");
            }
        }

        // Vercel Payload kann je nach Webhook-Typ variieren.
        // Daher: wir lesen defensiv mehrere Felder.
        const body = req.body || {};

        const url =
            body?.deployment?.url ||
            body?.payload?.deployment?.url ||
            body?.url ||
            body?.target_url ||
            body?.environment_url ||
            null;

        const status =
            body?.status ||
            body?.deployment?.state ||
            body?.payload?.deployment?.state ||
            body?.deployment?.status ||
            "success";

        const branch =
            body?.git?.ref ||
            body?.payload?.deployment?.meta?.githubCommitRef ||
            body?.deployment?.meta?.githubCommitRef ||
            body?.ref ||
            null;

        const commitSha =
            body?.git?.sha ||
            body?.payload?.deployment?.meta?.githubCommitSha ||
            body?.deployment?.meta?.githubCommitSha ||
            body?.sha ||
            null;

        // Wenn Vercel nur Hostname liefert, mach https draus
        const finalUrl = url && !url.startsWith("http") ? `https://${url}` : url;

        await postPreview({ url: finalUrl, branch, status, commitSha });

        res.status(200).send("ok");
    } catch (e) {
        console.log("Webhook error:", e?.message || e);
        res.status(500).send("error");
    }
});

app.get("/health", (req, res) => res.status(200).send("ok"));

app.listen(PORT, () => {
    console.log(`Webhook server listening on :${PORT}`);
});

client.login(TOKEN);
