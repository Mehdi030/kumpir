"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { useFriends } from "@/hooks/useFriends";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Invite = { id: string; lobbyCode: string; fromName: string; fromEmoji: string | null; createdAt: string };

/** Andere Teile (z. B. die Freunde-Liste) sollen nach Annehmen/Ablehnen sofort neu laden. */
export const FRIENDS_CHANGED = "kumpir:friends-changed";

function readSet(key: string): Set<string> {
    try {
        return new Set(JSON.parse(sessionStorage.getItem(key) || "[]") as string[]);
    } catch {
        return new Set();
    }
}
function writeSet(key: string, s: Set<string>) {
    try {
        sessionStorage.setItem(key, JSON.stringify([...s].slice(-50)));
    } catch {
        /* privater Modus */
    }
}

/**
 * Benachrichtigungen auf jeder Seite (nur mit Konto):
 *  - Freundschaftsanfrage: Karte unten rechts mit Name + Annehmen / Ablehnen (✕ = später, bleibt in der Freunde-Liste)
 *  - Lobby-Einladung (Migration 092): Pop-up in der Mitte "X lädt dich ein" mit Ja, beitreten / Nicht beitreten
 * Im laufenden Spiel wird die Einladung zurückgehalten (stört sonst), Anfragen erscheinen trotzdem klein unten rechts.
 */
export function Notifications() {
    const { user } = useAuth();
    const friends = useFriends(user?.id ?? null);
    const router = useRouter();
    const path = usePathname() ?? "";
    const [invites, setInvites] = useState<Invite[]>([]);
    const [hiddenReq, setHiddenReq] = useState<Set<string>>(() => new Set());
    const [hiddenInv, setHiddenInv] = useState<Set<string>>(() => new Set());
    const [busy, setBusy] = useState<string | null>(null);
    const refreshRef = useRef(friends.refresh);
    useEffect(() => {
        refreshRef.current = friends.refresh;
    }, [friends.refresh]);

    useEffect(() => {
        setHiddenReq(readSet("kumpir_hidden_requests"));
        setHiddenInv(readSet("kumpir_hidden_invites"));
    }, []);

    const loadInvites = useCallback(async () => {
        if (!user) return;
        const { data } = await getSupabaseClient().rpc("rpc_my_invites");
        if (Array.isArray(data)) setInvites(data as Invite[]);
    }, [user]);

    // Abfragen: Einladungen alle 6 s, Anfragen alle 15 s (nur wenn der Tab sichtbar ist)
    useEffect(() => {
        if (!user) return;
        void loadInvites();
        let n = 0;
        const t = window.setInterval(() => {
            if (document.visibilityState !== "visible") return;
            n++;
            void loadInvites();
            if (n % 5 === 0) void refreshRef.current();
        }, 6000);
        const onChanged = () => void refreshRef.current();
        window.addEventListener(FRIENDS_CHANGED, onChanged);
        return () => {
            window.clearInterval(t);
            window.removeEventListener(FRIENDS_CHANGED, onChanged);
        };
    }, [user, loadInvites]);

    if (!user) return null;

    const requests = friends.incoming.filter((r) => !hiddenReq.has(r.user_id));
    const inGame = path.startsWith("/game/");
    const invite = inGame ? null : invites.find((i) => !hiddenInv.has(i.id) && !path.endsWith(`/lobby/${i.lobbyCode}`)) ?? null;

    const hideReq = (id: string) => {
        const s = new Set(hiddenReq).add(id);
        setHiddenReq(s);
        writeSet("kumpir_hidden_requests", s);
    };
    const answerReq = async (id: string, accept: boolean) => {
        setBusy(id);
        if (accept) await friends.acceptRequest(id);
        else await friends.removeFriend(id);
        setBusy(null);
        window.dispatchEvent(new Event(FRIENDS_CHANGED));
    };
    const answerInvite = async (inv: Invite, accept: boolean) => {
        setBusy(inv.id);
        const s = new Set(hiddenInv).add(inv.id);
        setHiddenInv(s);
        writeSet("kumpir_hidden_invites", s);
        await getSupabaseClient().rpc("rpc_respond_invite", { p_invite_id: inv.id, p_accept: accept });
        setBusy(null);
        if (accept) router.push(`/join?code=${encodeURIComponent(inv.lobbyCode)}&go=1`);
    };

    return (
        <>
            {requests.length ? (
                <div className="ntStack" aria-live="polite">
                    {requests.slice(0, 3).map((r) => (
                        <div key={r.user_id} className="ntCard" role="status">
                            <button type="button" className="ntClose" onClick={() => hideReq(r.user_id)} aria-label="Später" title="Später (bleibt in der Freunde-Liste)">
                                ✕
                            </button>
                            <div className="ntRow">
                                <span className="ntAvatar" aria-hidden>
                                    {r.friend_username.slice(0, 1).toUpperCase()}
                                </span>
                                <div className="ntText">
                                    <div className="ntTitle">Freundschaftsanfrage</div>
                                    <div>
                                        <b>{r.friend_username}</b> möchte mit dir befreundet sein.
                                    </div>
                                </div>
                            </div>
                            <div className="ntBtns">
                                <button type="button" className="btn btnPrimary btnSmall" disabled={busy === r.user_id} onClick={() => void answerReq(r.user_id, true)}>
                                    ✅ Annehmen
                                </button>
                                <button type="button" className="btn btnSecondary btnSmall" disabled={busy === r.user_id} onClick={() => void answerReq(r.user_id, false)}>
                                    Ablehnen
                                </button>
                            </div>
                        </div>
                    ))}
                </div>
            ) : null}

            {invite ? (
                <div className="ntInvBack" role="presentation">
                    <div className="ntInv" role="dialog" aria-modal="true" aria-label="Einladung">
                        <div className="ntInvIcon" aria-hidden>
                            {invite.fromEmoji || "🎮"}
                        </div>
                        <div className="ntInvTitle">
                            <b>{invite.fromName}</b> hat dich eingeladen!
                        </div>
                        <div className="ntInvSub">
                            Lobby <span className="ntCode">{invite.lobbyCode}</span> – spiel mit?
                        </div>
                        <div className="ntInvBtns">
                            <button type="button" className="btn btnPrimary btnXL" disabled={busy === invite.id} onClick={() => void answerInvite(invite, true)}>
                                🚀 Ja, beitreten
                            </button>
                            <button type="button" className="btn btnSecondary" disabled={busy === invite.id} onClick={() => void answerInvite(invite, false)}>
                                Nicht beitreten
                            </button>
                        </div>
                    </div>
                </div>
            ) : null}

            <style>{`
                .ntStack{ position: fixed; right: 18px; bottom: 18px; z-index: 4500; display: grid; gap: 10px; width: min(360px, calc(100vw - 36px)); }
                .ntCard{ position: relative; padding: 14px 16px; border-radius: 20px; color: #fff;
                  background: linear-gradient(180deg, rgba(70,22,10,.96), rgba(40,12,6,.96)); border: 1px solid rgba(255,210,63,.55);
                  box-shadow: 0 20px 60px rgba(0,0,0,.45); display: grid; gap: 10px; animation: ntIn .45s cubic-bezier(.16,1,.3,1) both; }
                .ntClose{ position: absolute; top: 8px; right: 8px; width: 28px; height: 28px; border-radius: 999px; border: 0; background: rgba(255,255,255,.1); color: #fff; cursor: pointer; font-size: 12px; }
                .ntClose:hover{ background: rgba(255,255,255,.2); }
                .ntRow{ display: flex; gap: 12px; align-items: center; padding-right: 22px; }
                .ntAvatar{ flex: none; width: 42px; height: 42px; border-radius: 999px; display: grid; place-items: center; font-weight: 900; font-size: 18px; background: #f59e0b; border: 2px solid rgba(255,255,255,.6); }
                .ntText{ font-size: 14.5px; line-height: 1.35; }
                .ntTitle{ font-size: 11px; font-weight: 900; letter-spacing: 1.2px; text-transform: uppercase; color: #ffe08a; }
                .ntBtns{ display: flex; gap: 8px; }
                .ntBtns .btn{ flex: 1; }
                .ntInvBack{ position: fixed; inset: 0; z-index: 4600; display: grid; place-items: center; padding: 18px; background: rgba(10,4,2,.55); backdrop-filter: blur(5px); -webkit-backdrop-filter: blur(5px); animation: ntFade .25s ease both; }
                .ntInv{ width: min(420px, 100%); padding: 26px 24px 22px; border-radius: 28px; text-align: center; color: #fff;
                  background: linear-gradient(180deg, rgba(80,24,10,.97), rgba(40,12,6,.97)); border: 2px solid rgba(255,210,63,.7);
                  box-shadow: 0 0 0 6px rgba(255,210,63,.15), 0 40px 120px rgba(0,0,0,.55); display: grid; gap: 10px; justify-items: center;
                  animation: ntPop .5s cubic-bezier(.34,1.56,.64,1) both; }
                .ntInvIcon{ font-size: 54px; line-height: 1; animation: ntWiggle 1.6s ease-in-out .5s infinite; }
                .ntInvTitle{ font-family: var(--font-display); font-size: 24px; font-weight: 800; }
                .ntInvSub{ font-size: 15px; opacity: .85; font-weight: 700; }
                .ntCode{ font-family: var(--font-display); letter-spacing: .14em; color: #ffd23f; }
                .ntInvBtns{ display: grid; gap: 8px; width: 100%; margin-top: 8px; }
                @keyframes ntIn{ from{ opacity: 0; transform: translateY(16px) scale(.97); } to{ opacity: 1; transform: none; } }
                @keyframes ntFade{ from{ opacity: 0; } to{ opacity: 1; } }
                @keyframes ntPop{ from{ opacity: 0; transform: scale(.85); } to{ opacity: 1; transform: none; } }
                @keyframes ntWiggle{ 0%,100%{ transform: rotate(0); } 25%{ transform: rotate(-8deg); } 75%{ transform: rotate(8deg); } }
                @media (prefers-reduced-motion: reduce){ .ntCard, .ntInv, .ntInvIcon, .ntInvBack{ animation: none; } }
            `}</style>
        </>
    );
}
