"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { getSupabaseClient } from "@/lib/supabaseClient";
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
const SHOWN = 2;

function joinHref(code: string) {
    return `/join?code=${encodeURIComponent(code)}&go=1`;
}

function LobbyChip({ l }: { l: OpenLobby }) {
    const host = l.hostName ?? "Lobby";
    return (
        <Link href={joinHref(l.code)} className="olChip" title={`${host}s Lobby beitreten (Code ${l.code})`}>
            <PlayerAvatar seed={host} config={l.hostAvatar} size={30} className="olAvatar" />
            <span className="olText">
                <b>{host}</b>
                <span>
                    {l.players}/{l.maxPlayers} Spieler
                </span>
            </span>
            <span className="olGo">Beitreten ›</span>
        </Link>
    );
}

/**
 * "Offene Lobbys" im Hauptmenü (Migration 104): öffentliche Lobbys, die noch nicht gestartet und nicht voll sind –
 * direkt beitreten ohne Code. Klein, aber mit grünem Puls-Punkt gut sichtbar; mehr als 2 -> "Alle"-Fenster.
 * Ohne offene Lobby steht nur eine schmale Zeile da.
 */
export function OpenLobbies() {
    const [list, setList] = useState<OpenLobby[] | null>(null);
    const [open, setOpen] = useState(false);

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

    useEffect(() => {
        if (!open) return;
        const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [open]);

    if (list === null) return <div className="olBar olEmpty" aria-hidden />;

    if (list.length === 0) {
        return (
            <div className="olBar olEmpty">
                <span className="olDot off" aria-hidden />
                Gerade keine offenen Lobbys – hoste eine, dann sehen dich alle hier.
                <style>{STYLES}</style>
            </div>
        );
    }

    return (
        <section className="olBar" aria-label="Offene Lobbys">
            <span className="olHead">
                <span className="olDot" aria-hidden />
                <b>{list.length === 1 ? "1 offene Lobby" : `${list.length} offene Lobbys`}</b>
            </span>
            <div className="olChips">
                {list.slice(0, SHOWN).map((l) => (
                    <LobbyChip key={l.code} l={l} />
                ))}
                {list.length > SHOWN ? (
                    <button type="button" className="olMore" onClick={() => setOpen(true)}>
                        Alle {list.length} ›
                    </button>
                ) : null}
            </div>
            {open
                ? createPortal(
                      <div className="olModalBack" onClick={() => setOpen(false)} role="presentation">
                          <div className="olModal" role="dialog" aria-modal="true" aria-label="Offene Lobbys" onClick={(e) => e.stopPropagation()}>
                              <div className="olModalHead">
                                  <span className="olDot" aria-hidden />
                                  <b>Offene Lobbys</b>
                                  <button type="button" className="olModalClose" onClick={() => setOpen(false)} aria-label="Schließen">
                                      ✕
                                  </button>
                              </div>
                              <div className="olModalList">
                                  {list.map((l) => (
                                      <LobbyChip key={l.code} l={l} />
                                  ))}
                              </div>
                          </div>
                          <style>{STYLES}</style>
                      </div>,
                      document.body
                  )
                : null}
            <style>{STYLES}</style>
        </section>
    );
}

const STYLES = `
.olBar{ margin: 12px auto 0; width: min(640px, 100%); display: flex; align-items: center; gap: 10px; padding: 8px 10px 8px 14px; border-radius: 20px;
  background: linear-gradient(90deg, rgba(22,163,74,.30), rgba(22,163,74,.12)); border: 1.5px solid rgba(134,239,172,.65);
  box-shadow: 0 0 0 4px rgba(34,197,94,.10), 0 10px 24px rgba(0,0,0,.18); animation: olGlow 2.4s ease-in-out infinite; }
.olBar.olEmpty{ justify-content: center; gap: 8px; padding: 6px 12px; min-height: 34px; background: rgba(0,0,0,.14); border: 1px dashed rgba(255,255,255,.22);
  box-shadow: none; animation: none; font-size: 12.5px; font-weight: 700; opacity: .8; text-align: center; }
@keyframes olGlow{ 0%,100%{ box-shadow: 0 0 0 4px rgba(34,197,94,.10), 0 10px 24px rgba(0,0,0,.18); } 50%{ box-shadow: 0 0 0 7px rgba(34,197,94,.16), 0 10px 24px rgba(0,0,0,.18); } }
.olHead{ display: flex; align-items: center; gap: 8px; flex: none; font-size: 13.5px; line-height: 1.1; }
.olHead b{ font-weight: 900; color: #dcfce7; white-space: nowrap; }
.olDot{ display: inline-block; width: 11px; height: 11px; border-radius: 50%; background: #22c55e; box-shadow: 0 0 0 0 rgba(34,197,94,.7); animation: olPulse 1.6s infinite; }
.olDot.off{ background: rgba(255,255,255,.35); animation: none; }
@keyframes olPulse{ 0%{ box-shadow: 0 0 0 0 rgba(34,197,94,.7); } 70%{ box-shadow: 0 0 0 9px rgba(34,197,94,0); } 100%{ box-shadow: 0 0 0 0 rgba(34,197,94,0); } }
.olChips{ display: flex; gap: 8px; flex: 1; min-width: 0; justify-content: flex-end; flex-wrap: wrap; }
.olChip{ display: inline-flex; align-items: center; gap: 8px; min-width: 0; flex: 0 1 230px; padding: 5px 6px 5px 6px; border-radius: 16px; color: #fff; text-decoration: none;
  background: rgba(0,0,0,.28); border: 1px solid rgba(255,255,255,.2); transition: transform .12s, background .12s; }
.olChip:hover{ transform: translateY(-1px); background: rgba(0,0,0,.4); }
.olAvatar{ width: 30px; height: 30px; flex: none; border-radius: 50%; background: rgba(255,255,255,.14); }
.olText{ display: grid; min-width: 0; text-align: left; line-height: 1.15; }
.olText b{ font-size: 13.5px; font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.olText span{ font-size: 11.5px; font-weight: 700; opacity: .8; }
.olGo{ margin-left: auto; flex: none; font-size: 12.5px; font-weight: 900; color: #052e16; background: #4ade80; padding: 5px 9px; border-radius: 11px; }
.olMore{ flex: none; align-self: center; padding: 7px 11px; border-radius: 12px; border: 1px solid rgba(134,239,172,.6); background: rgba(0,0,0,.2); color: #dcfce7; font-weight: 900; font-size: 12.5px; cursor: pointer; }
.olModalBack{ position: fixed; inset: 0; z-index: 4000; background: rgba(10,4,2,.62); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); display: grid; place-items: center; padding: 14px; }
.olModal{ width: min(460px, 100%); max-height: calc(100dvh - 28px); overflow: auto; border-radius: 24px; padding: 16px; color: #fff;
  background: linear-gradient(180deg, rgba(20,60,32,.97), rgba(10,30,16,.98)); border: 1px solid rgba(134,239,172,.45); }
.olModalHead{ display: flex; align-items: center; gap: 10px; margin-bottom: 12px; font-size: 18px; }
.olModalClose{ margin-left: auto; width: 36px; height: 36px; border-radius: 999px; border: 1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.08); color: #fff; cursor: pointer; }
.olModalList{ display: grid; gap: 8px; }
.olModalList .olChip{ flex: none; padding: 8px 10px; }
@media (max-width: 560px){
  .olBar{ flex-wrap: wrap; padding: 8px 10px; }
  .olChips{ flex: 1 1 100%; justify-content: stretch; }
  .olChip{ flex: 1 1 100%; }
}
`;
