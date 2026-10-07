"use client";

import { getSupabaseClient } from "@/lib/supabaseClient";
import { getSessionToken } from "@/lib/playerSession";
import { startGame } from "@/actions/startGame";

export type BotSkill = "mixed" | "1" | "2" | "3";
const BOT_NAMES = ["Bot Anna", "Bot Ben", "Bot Cleo", "Bot Dino", "Bot Emma"];
// "Gemischt": überwiegend Anfänger und Mittel, ab 3 Bots ein Profi dabei
const MIXED_SKILLS: (1 | 2 | 3)[] = [1, 2, 3, 1, 2];

export function botLineup(count: number, skill: BotSkill): { name: string; skill: 1 | 2 | 3 }[] {
    const n = Math.max(1, Math.min(5, count));
    return BOT_NAMES.slice(0, n).map((name, i) => ({ name, skill: skill === "mixed" ? MIXED_SKILLS[i]! : (Number(skill) as 1 | 2 | 3) }));
}

/**
 * Spiel gegen Bots mit einem Klick: Lobby anlegen, beitreten, Bots dazu, Playlists setzen, starten.
 * Gibt den Lobby-Code zurück (danach /game/<code> öffnen). Wirft bei Fehlern (Text vom Server).
 */
export async function startBotGame(opts: {
    name: string;
    userId: string | null;
    bots: number;
    skill: BotSkill;
    speed: "fast" | "normal" | "calm";
    roundSeconds: number;
    seriesTotal: 1 | 3 | 5;
    topicFilter: string[]; // leer = alle Playlists
}): Promise<string> {
    const supabase = getSupabaseClient();
    const lineup = botLineup(opts.bots, opts.skill);

    const { data, error } = await supabase.rpc("rpc_create_lobby", {
        p_host_name: opts.name,
        p_privacy: "private",
        p_max_players: Math.max(6, lineup.length + 1),
        p_round_seconds: opts.roundSeconds,
        p_user_id: opts.userId,
        p_round_speed: opts.speed,
    });
    if (error) throw new Error(error.message);
    const row = Array.isArray(data) ? data[0] : data;
    const code = String(row?.code ?? "").toUpperCase();
    const me = String(row?.host_player_id ?? "");
    if (code.length !== 4 || !me) throw new Error("Lobby konnte nicht erstellt werden.");

    try {
        localStorage.setItem("kumpir_player_name", opts.name);
        localStorage.setItem("kumpir_player_id", me);
        sessionStorage.setItem("kumpir_player_name", opts.name);
        sessionStorage.setItem("kumpir_player_id", me);
    } catch {
        /* privater Modus */
    }

    const join = await supabase.rpc("rpc_join_lobby", { p_code: code, p_player_id: me, p_name: opts.name, p_user_id: opts.userId });
    if (join.error) throw new Error(join.error.message);

    const { data: lobby, error: lErr } = await supabase.from("lobbies").select("id").eq("code", code).single();
    if (lErr || !lobby?.id) throw new Error(lErr?.message ?? "Lobby nicht gefunden.");

    await supabase.rpc("set_lobby_topic_filter", { p_lobby_id: lobby.id, p_me_player_id: me, p_categories: opts.topicFilter });
    if (opts.seriesTotal !== 1) {
        await supabase.rpc("set_lobby_series", { p_lobby_id: lobby.id, p_me_player_id: me, p_total: opts.seriesTotal });
    }
    for (const b of lineup) {
        const { error: bErr } = await supabase.rpc("rpc_add_bot", { p_lobby_id: lobby.id, p_me_player_id: me, p_bot_name: b.name, p_skill: b.skill });
        if (bErr) throw new Error(bErr.message);
    }

    const res = await startGame(code, me, getSessionToken() ?? "");
    if (!res.ok) throw new Error("error" in res ? res.error : "Start fehlgeschlagen.");
    return code;
}
