"use client";

import { useEffect, useState } from "react";
import { useI18n } from "@/lib/i18n";

type InstallEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };

const DISMISS_KEY = "kumpir_install_dismissed";

function isStandalone(): boolean {
    return window.matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
}

/**
 * Ohne `showHint` (im Layout, also auf jeder Seite): registriert den Service Worker (nur in der Produktion),
 * damit auch Leute, die über einen Einladungslink kommen, die Offline-Seite bekommen.
 * Mit `showHint` (Startseite): kleiner Installationshinweis – Android/Chrome mit echtem Install-Knopf, iPhone mit Anleitung.
 */
export function PwaSetup({ showHint = false }: { showHint?: boolean }) {
    const { t } = useI18n();
    const [evt, setEvt] = useState<InstallEvent | null>(null);
    const [ios, setIos] = useState(false);
    const [hidden, setHidden] = useState(true);

    useEffect(() => {
        if (showHint) return; // registriert wird über die Instanz im Layout
        if (process.env.NODE_ENV === "production" && "serviceWorker" in navigator) {
            void navigator.serviceWorker.register("/sw.js").catch(() => undefined);
        }
    }, [showHint]);

    useEffect(() => {
        if (!showHint) return;
        try {
            if (localStorage.getItem(DISMISS_KEY)) return;
        } catch {
            /* ignore */
        }
        if (isStandalone()) return;
        const ua = navigator.userAgent;
        const isIos = /iPad|iPhone|iPod/.test(ua) && !/CriOS|FxiOS/.test(ua);
        // iPhone-Safari kennt kein Install-Ereignis: dort direkt die Anleitung zeigen (nach dem ersten Render).
        const timer = window.setTimeout(() => {
            setIos(isIos);
            setHidden((h) => (isIos ? false : h));
        }, 0);
        const onPrompt = (e: Event) => {
            e.preventDefault();
            setEvt(e as InstallEvent);
            setHidden(false);
        };
        const onInstalled = () => setHidden(true);
        window.addEventListener("beforeinstallprompt", onPrompt);
        window.addEventListener("appinstalled", onInstalled);
        return () => {
            window.clearTimeout(timer);
            window.removeEventListener("beforeinstallprompt", onPrompt);
            window.removeEventListener("appinstalled", onInstalled);
        };
    }, [showHint]);

    const dismiss = () => {
        setHidden(true);
        try {
            localStorage.setItem(DISMISS_KEY, "1");
        } catch {
            /* ignore */
        }
    };

    const install = async () => {
        if (!evt) return;
        await evt.prompt();
        await evt.userChoice.catch(() => undefined);
        setEvt(null);
        setHidden(true);
    };

    if (!showHint || hidden || (!evt && !ios)) return null;

    return (
        <div className="pwaHint" role="note">
            <span className="pwaText">{evt ? t("pwa.install") : t("pwa.ios")}</span>
            {evt ? (
                <button type="button" className="btn btnPrimary btnSmall" onClick={() => void install()}>
                    {t("pwa.btn")}
                </button>
            ) : null}
            <button type="button" className="pwaClose" onClick={dismiss} aria-label={t("pwa.dismiss")}>
                ✕
            </button>
            <style>{`
        .pwaHint{ display:flex; gap:10px; align-items:center; justify-content:center; flex-wrap:wrap; margin-top:14px; padding:10px 14px; border-radius:16px; background:rgba(255,255,255,.12); border:1px solid rgba(255,255,255,.22); font-size:14px; font-weight:600; }
        .pwaText{ flex:1 1 200px; text-align:left; }
        .pwaClose{ border:0; background:transparent; color:#fff; font-size:16px; cursor:pointer; opacity:.8; padding:4px 8px; }
        .pwaClose:hover{ opacity:1; }
      `}</style>
        </div>
    );
}
