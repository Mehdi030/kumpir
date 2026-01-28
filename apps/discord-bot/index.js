import "dotenv/config";
import {
    Client,
    GatewayIntentBits,
    Partials,
    PermissionsBitField
} from "discord.js";

const TOKEN = process.env.DISCORD_BOT_TOKEN;
const PREVIEW_CHANNEL_ID = process.env.PREVIEW_CHANNEL_ID;
const PREVIEW_WEBHOOK_ID = process.env.PREVIEW_WEBHOOK_ID || null;
const KEEP_LATEST = Number(process.env.KEEP_LATEST || "1");

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
    // passt zu deinem Workflow-Text:
    return content.includes("aktuelle spiel-vorschau") && content.includes("kumpir");
}

function isFromExpectedWebhook(message) {
    if (!PREVIEW_WEBHOOK_ID) return true; // wenn nicht gesetzt: alles erlauben
    // Webhook-Messages haben webhookId gesetzt
    return message.webhookId === PREVIEW_WEBHOOK_ID;
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

    const keep = previews.slice(0, KEEP_LATEST);
    const toDelete = previews.slice(KEEP_LATEST);

    if (toDelete.length === 0) return;

    console.log(
        `Cleanup: keeping ${keep.length}, deleting ${toDelete.length} old preview messages...`
    );

    for (const msg of toDelete) {
        try {
            await msg.delete();
        } catch (e) {
            console.log(`Failed to delete message ${msg.id}:`, e?.message || e);
        }
    }
}

client.on("ready", () => {
    console.log(`Logged in as ${client.user.tag}`);
});

client.on("messageCreate", async (message) => {
    try {
        if (!message.guild) return;
        if (message.channelId !== PREVIEW_CHANNEL_ID) return;

        // nur reagieren, wenn das wirklich eine Preview-Nachricht ist
        if (!isPreviewMessage(message)) return;

        // optionaler Sicherheitsfilter: nur dein Webhook
        if (!isFromExpectedWebhook(message)) return;

        await cleanupPreviewChannel(message.channel);
    } catch (e) {
        console.log("messageCreate error:", e?.message || e);
    }
});

client.login(TOKEN);
