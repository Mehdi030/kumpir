"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useI18n } from "@/lib/i18n";
import { PlayerAvatar, type AvatarConfig } from "@/components/game/PlayerAvatar";

type OpenLobby = {
    code: string;
    hostName: string | null;
    hostAvatar: AvatarConfig | null;
    players: number;
    humans: number;
    maxPlayers: number;
    speed: string | null;
};

const REFRESH_MS = 12000;

/** Jede Lobby bekommt eine eigene Farbe (Reihenfolge der Liste), damit man sie auseinanderhalten kann. */
const LOBBY_COLORS: { bg: string; fg: string }[] = [
    { bg: "#ef4444", fg: "#fff" }, // rot
    { bg: "#facc15", fg: "#2a1a00" }, // gelb
    { bg: "#3b82f6", fg: "#fff" }, // blau
    { bg: "#a855f7", fg: "#fff" }, // lila
    { bg: "#f97316", fg: "#2a1200" }, // orange
    { bg: "#ec4899", fg: "#fff" }, // pink
    { bg: "#14b8a6", fg: "#042f2e" }, // türkis
    { bg: "#a3e635", fg: "#1a2e05" }, // hellgrün
];

function joinHref(code: string) {
    return `/join?code=${encodeURIComponent(code)}&go=1`;
}

/** Offene Lobbys laden (alle 12 s, nur wenn der Tab sichtbar ist). */
function useOpenLobbies() {
    const [list, setList] = useState<OpenLobby[] | null>(null);
    const load = useCallback(async () => {
        const { data, error } = await getSupabaseClient().rpc("get_public_lobbies");
        if (!error && Array.isArray(data)) setList(data as OpenLobby[]);
    }, []);
    useEffect(() => {
        const first = window.setTimeout(() => void load(), 0);
        const t = window.setInterval(() => {
            if (document.visibilityState === "visible") void load();
        }, REFRESH_MS);
        const onVis = () => document.visibilityState === "visible" && void load();
        document.addEventListener("visibilitychange", onVis);
        return () => {
            window.clearTimeout(first);
            window.clearInterval(t);
            document.removeEventListener("visibilitychange", onVis);
        };
    }, [load]);
    return list;
}

function LobbyRow({ l, i }: { l: OpenLobby; i: number }) {
    const { tr } = useI18n();
    const host = l.hostName ?? "Lobby";
    const c = LOBBY_COLORS[i % LOBBY_COLORS.length];
    return (
        <Link
            href={joinHref(l.code)}
            className="olRow"
            style={{ ["--i" as string]: i, ["--lc" as string]: c.bg, ["--lf" as string]: c.fg }}
            title={tr("{name}s Lobby beitreten (Code {code})", { name: host, code: l.code })}
        >
            <PlayerAvatar seed={host} config={l.hostAvatar} size={32} className="olAvatar" />
            <span className="olText">
                <span className="olName">
                    <b>{host}</b>
                    <code className="olCode" title={tr("Lobby-Code")}>
                        {l.code}
                    </code>
                </span>
                <span>{tr("{n}/{max} Spieler", { n: l.players, max: l.maxPlayers })}</span>
            </span>
            <span className="olGo">{tr("Beitreten ›")}</span>
        </Link>
    );
}

/**
 * "Offene Lobbys" (Migration 104): öffentliche Lobbys, die noch nicht gestartet und nicht voll sind –
 * direkt beitreten ohne Code. Steht an der Seite unter den Freunden (Wunsch Mehdi 2026-10-12):
 *  - variant "side": eigener Block in der Freunde-Leiste (breite Bildschirme), auch ohne Lobby sichtbar
 *  - variant "inline": schmale Bildschirme, nur wenn es wirklich offene Lobbys gibt
 */
export function OpenLobbies({ variant = "side" }: { variant?: "side" | "inline" }) {
    const { tr } = useI18n();
    const list = useOpenLobbies();
    const [showAll, setShowAll] = useState(false);

    if (list === null) return null;
    if (!list.length && variant === "inline") return null;

    const shown = showAll ? list : list.slice(0, 3);
    return (
        <section className={`olBox ${variant} ${list.length ? "has" : "none"}`} aria-label={tr("Offene Lobbys")}>
            <div className="olHead">
                <span className={`olDot ${list.length ? "" : "off"}`} aria-hidden />
                <b>{list.length ? tr("Offene Lobbys") : tr("Keine offenen Lobbys")}</b>
                {list.length ? <span className="olCount">{list.length}</span> : null}
            </div>
            {list.length ? (
                <div className="olList">
                    {shown.map((l) => (
                        <LobbyRow key={l.code} l={l} i={list.indexOf(l)} />
                    ))}
                    {list.length > 3 ? (
                        <button type="button" className="olMore" onClick={() => setShowAll((v) => !v)}>
                            {showAll ? tr("Weniger anzeigen") : tr("Alle {n} anzeigen", { n: list.length })}
                        </button>
                    ) : null}
                </div>
            ) : (
                <div className="olNone">{tr("Hoste eine öffentliche Lobby – dann sehen dich alle hier.")}</div>
            )}
            <style>{STYLES}</style>
        </section>
    );
}

const STYLES = `
.olBox{ display: grid; gap: 8px; padding: 12px; border-radius: 20px; }
.olBox.has{ background: linear-gradient(160deg, rgba(255,210,63,.20), rgba(255,210,63,.06)); border: 1.5px solid rgba(255,224,138,.55);
  box-shadow: 0 0 0 3px rgba(255,210,63,.10); animation: olGlow 2.4s ease-in-out infinite; }
.olBox.none{ background: rgba(0,0,0,.16); border: 1px dashed rgba(255,255,255,.22); }
.olBox.inline{ margin: 12px auto 0; width: min(640px, 100%); }
@keyframes olGlow{ 0%,100%{ box-shadow: 0 0 0 3px rgba(255,210,63,.10); } 50%{ box-shadow: 0 0 0 6px rgba(255,210,63,.18); } }
.olHead{ display: flex; align-items: center; gap: 8px; font-size: 14.5px; }
.olHead b{ font-weight: 900; }
.olBox.has .olHead b{ color: #fff3cf; }
.olCount{ margin-left: auto; font-size: 12px; font-weight: 900; padding: 2px 9px; border-radius: 999px; background: #ffd23f; color: #2a1200; }
.olDot{ flex: none; display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: #ffd23f; animation: olPulse 1.6s infinite; }
.olDot.off{ background: rgba(255,255,255,.35); animation: none; }
@keyframes olPulse{ 0%{ box-shadow: 0 0 0 0 rgba(255,210,63,.7); } 70%{ box-shadow: 0 0 0 9px rgba(255,210,63,0); } 100%{ box-shadow: 0 0 0 0 rgba(255,210,63,0); } }
.olList{ display: grid; gap: 6px; }
.olRow{ display: flex; align-items: center; gap: 9px; min-width: 0; padding: 6px 7px; border-radius: 14px; color: #fff; text-decoration: none;
  background: linear-gradient(90deg, color-mix(in srgb, var(--lc) 34%, transparent), rgba(0,0,0,.26) 70%);
  border: 1px solid color-mix(in srgb, var(--lc) 65%, transparent); border-left: 5px solid var(--lc);
  transition: transform .15s ease, background .15s ease;
  animation: olIn .45s cubic-bezier(.22,1,.36,1) backwards; animation-delay: calc(var(--i, 0) * 60ms); }
.olRow:hover{ transform: translateX(3px); background: linear-gradient(90deg, color-mix(in srgb, var(--lc) 48%, transparent), rgba(0,0,0,.34) 75%); }
@keyframes olIn{ from{ opacity: 0; transform: translateY(6px); } }
.olAvatar{ width: 32px; height: 32px; flex: none; border-radius: 50%; background: rgba(255,255,255,.14); box-shadow: 0 0 0 2px var(--lc); }
.olText{ display: grid; min-width: 0; line-height: 1.15; flex: 1; }
.olName{ display: flex; align-items: center; gap: 6px; min-width: 0; }
.olName b{ font-size: 14px; font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.olCode{ flex: none; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11.5px; font-weight: 900; letter-spacing: 1px;
  padding: 1px 6px; border-radius: 6px; background: var(--lc); color: var(--lf); }
.olText > span:last-child{ font-size: 11.5px; font-weight: 700; opacity: .8; }
.olGo{ flex: none; font-size: 12px; font-weight: 900; color: var(--lf); background: var(--lc); padding: 5px 9px; border-radius: 10px; }
.olMore{ justify-self: start; padding: 5px 10px; border-radius: 10px; border: 1px solid rgba(255,224,138,.55); background: rgba(0,0,0,.2); color: #fff3cf; font-weight: 900; font-size: 12px; cursor: pointer; }
.olNone{ font-size: 12.5px; font-weight: 700; opacity: .75; line-height: 1.35; }
@media (prefers-reduced-motion: reduce){ .olBox.has, .olDot, .olRow{ animation: none; } }
`;
