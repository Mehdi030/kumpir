"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useI18n } from "@/lib/i18n";

/**
 * "Hauptmenü" in jedem Spiel (Wunsch Mehdi 2026-10-14): kleiner Knopf oben links, in jeder Phase und in jedem Modus.
 * Nachfragen, weil man das Match damit verlässt; wer gehen darf, kommt über Code/Einladung wieder rein (Migration 123).
 * Die gespeicherte Spieler-ID bleibt absichtlich erhalten, damit das Zurückkommen klappt.
 */
export function GameMenuButton() {
    const { tr } = useI18n();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();
    const { mePlayerId } = usePlayerIdentity();
    const [open, setOpen] = useState(false);
    const [busy, setBusy] = useState(false);

    useEffect(() => {
        if (!open) return;
        const onKey = (e: KeyboardEvent) => {
            if (e.key === "Escape") setOpen(false);
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [open]);

    const leave = async () => {
        setBusy(true);
        try {
            if (mePlayerId) {
                const supabase = getSupabaseClient();
                const { data } = await supabase.from("lobbies").select("id").eq("code", code).maybeSingle();
                if (data?.id) await supabase.rpc("rpc_leave_lobby", { p_lobby_id: data.id, p_player_id: mePlayerId });
            }
        } catch {
            /* trotzdem ins Hauptmenü */
        }
        window.location.assign("/?left=1");
    };

    return (
        <>
            <button type="button" className="gmBtn" onClick={() => setOpen(true)} aria-haspopup="dialog">
                <span aria-hidden>🏠</span> <span className="gmBtnText">{tr("Hauptmenü")}</span>
            </button>
            {open ? (
                <div className="gmBack" onClick={() => setOpen(false)} role="presentation">
                    <div className="gmBox" role="dialog" aria-modal="true" aria-label={tr("Spiel verlassen?")} onClick={(e) => e.stopPropagation()}>
                        <div className="gmTitle">{tr("Spiel verlassen?")}</div>
                        <p className="gmText">{tr("Du gehst ins Hauptmenü. Solange das Match läuft, kommst du über den Code wieder rein.")}</p>
                        <div className="gmRow">
                            <button type="button" className="btn btnPrimary btnSmall" onClick={() => void leave()} disabled={busy}>
                                {busy ? "…" : tr("Ins Hauptmenü")}
                            </button>
                            <button type="button" className="btn btnSecondary btnSmall" onClick={() => setOpen(false)} autoFocus>
                                {tr("Weiterspielen")}
                            </button>
                        </div>
                    </div>
                </div>
            ) : null}
            <style>{`
        .gmBtn{ position: fixed; top: 18px; left: 18px; z-index: 70; display: inline-flex; align-items: center; gap: 6px; padding: 8px 14px; border-radius: 999px;
          font: inherit; font-weight: 900; font-size: 13px; color: #fff; cursor: pointer; background: rgba(0,0,0,.34); border: 1px solid rgba(255,255,255,.2);
          backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); transition: background .2s ease, transform .15s ease; }
        .gmBtn:hover{ background: rgba(0,0,0,.5); transform: translateY(-1px); }
        .gmBack{ position: fixed; inset: 0; z-index: 9000; display: grid; place-items: center; padding: 18px; background: rgba(0,0,0,.45); }
        .gmBox{ width: min(380px, 100%); display: grid; gap: 10px; padding: 20px; border-radius: 22px; color: #fff; text-align: center;
          background: linear-gradient(180deg, rgba(60,22,12,.97), rgba(30,12,8,.97)); border: 1px solid rgba(255,255,255,.2); box-shadow: 0 24px 70px rgba(0,0,0,.5); }
        .gmTitle{ font-family: var(--font-display); font-size: 24px; font-weight: 900; }
        .gmText{ margin: 0; font-size: 14px; opacity: .85; line-height: 1.4; }
        .gmRow{ display: flex; gap: 8px; justify-content: center; flex-wrap: wrap; margin-top: 4px; }
        @media (max-width: 640px){ .gmBtn{ top: 12px; left: 12px; padding: 7px 11px; } .gmBtnText{ display: none; } }
      `}</style>
        </>
    );
}
