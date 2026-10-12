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
    return (
        <Link href={joinHref(l.code)} className="olRow" style={{ ["--i" as string]: i }} title={tr("{name}s Lobby beitreten (Code {code})", { name: host, code: l.code })}>
            <PlayerAvatar seed={host} config={l.hostAvatar} size={32} className="olAvatar" />
            <span className="olText">
                <b>{host}</b>
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
                    {shown.map((l, i) => (
                        <LobbyRow key={l.code} l={l} i={i} />
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
.olBox.has{ background: linear-gradient(160deg, rgba(22,163,74,.28), rgba(22,163,74,.10)); border: 1.5px solid rgba(134,239,172,.6);
  box-shadow: 0 0 0 3px rgba(34,197,94,.10); animation: olGlow 2.4s ease-in-out infinite; }
.olBox.none{ background: rgba(0,0,0,.16); border: 1px dashed rgba(255,255,255,.22); }
.olBox.inline{ margin: 12px auto 0; width: min(640px, 100%); }
@keyframes olGlow{ 0%,100%{ box-shadow: 0 0 0 3px rgba(34,197,94,.10); } 50%{ box-shadow: 0 0 0 6px rgba(34,197,94,.18); } }
.olHead{ display: flex; align-items: center; gap: 8px; font-size: 14.5px; }
.olHead b{ font-weight: 900; }
.olBox.has .olHead b{ color: #dcfce7; }
.olCount{ margin-left: auto; font-size: 12px; font-weight: 900; padding: 2px 9px; border-radius: 999px; background: #4ade80; color: #052e16; }
.olDot{ flex: none; display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: #22c55e; animation: olPulse 1.6s infinite; }
.olDot.off{ background: rgba(255,255,255,.35); animation: none; }
@keyframes olPulse{ 0%{ box-shadow: 0 0 0 0 rgba(34,197,94,.7); } 70%{ box-shadow: 0 0 0 9px rgba(34,197,94,0); } 100%{ box-shadow: 0 0 0 0 rgba(34,197,94,0); } }
.olList{ display: grid; gap: 6px; }
.olRow{ display: flex; align-items: center; gap: 9px; min-width: 0; padding: 6px 7px; border-radius: 14px; color: #fff; text-decoration: none;
  background: rgba(0,0,0,.26); border: 1px solid rgba(255,255,255,.16); transition: transform .15s ease, background .15s ease;
  animation: olIn .45s cubic-bezier(.22,1,.36,1) backwards; animation-delay: calc(var(--i, 0) * 60ms); }
.olRow:hover{ transform: translateX(3px); background: rgba(0,0,0,.4); }
@keyframes olIn{ from{ opacity: 0; transform: translateY(6px); } }
.olAvatar{ width: 32px; height: 32px; flex: none; border-radius: 50%; background: rgba(255,255,255,.14); }
.olText{ display: grid; min-width: 0; line-height: 1.15; flex: 1; }
.olText b{ font-size: 14px; font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.olText span{ font-size: 11.5px; font-weight: 700; opacity: .8; }
.olGo{ flex: none; font-size: 12px; font-weight: 900; color: #052e16; background: #4ade80; padding: 5px 9px; border-radius: 10px; }
.olMore{ justify-self: start; padding: 5px 10px; border-radius: 10px; border: 1px solid rgba(134,239,172,.6); background: rgba(0,0,0,.2); color: #dcfce7; font-weight: 900; font-size: 12px; cursor: pointer; }
.olNone{ font-size: 12.5px; font-weight: 700; opacity: .75; line-height: 1.35; }
@media (prefers-reduced-motion: reduce){ .olBox.has, .olDot, .olRow{ animation: none; } }
`;
