"use client";

import { useCallback, useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { useI18n } from "@/lib/i18n";
import { track } from "@/lib/track";

type Props = { code: string; disabled?: boolean };

/** Einladen mit einem Tipp: Teilen (System-Teilen / WhatsApp) und QR-Code zum Abscannen. */
export function InviteActions({ code, disabled = false }: Props) {
    const { t } = useI18n();
    const [showQr, setShowQr] = useState(false);

    const link = () => `${window.location.origin}/join?code=${encodeURIComponent(code)}`;
    const text = () => `${t("invite.text", { code })}\n${link()}`;

    const share = useCallback(async () => {
        track("invite_share");
        const nav = navigator as Navigator & { share?: (data: ShareData) => Promise<void> };
        if (typeof nav.share === "function") {
            try {
                await nav.share({ title: "Kumpir-Lobby", text: text(), url: link() });
                return;
            } catch (e) {
                if (e instanceof Error && e.name === "AbortError") return;
            }
        }
        // Desktop ohne System-Teilen: WhatsApp-Link öffnen
        window.open(`https://wa.me/?text=${encodeURIComponent(text())}`, "_blank", "noopener,noreferrer");
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [code, t]);

    return (
        <div className="inviteWrap">
            <div className="inviteRow">
                <button type="button" className="btn btnPrimary btnSmall" onClick={() => void share()} disabled={disabled}>
                    {t("invite.share")}
                </button>
                <button type="button" className="btn btnSecondary btnSmall" onClick={() => {
                        if (!showQr) track("invite_qr");
                        setShowQr((v) => !v);
                    }} aria-expanded={showQr} disabled={disabled}>
                    {showQr ? t("invite.qrHide") : t("invite.qr")}
                </button>
            </div>
            {showQr ? (
                <div className="inviteQr">
                    <div className="inviteQrBox">
                        <QRCodeSVG value={typeof window !== "undefined" ? `${window.location.origin}/join?code=${code}` : ""} size={200} level="M" marginSize={2} bgColor="#ffffff" fgColor="#2b0f04" title={`QR-Code für Lobby ${code}`} />
                    </div>
                    <div className="inviteQrHint">{t("invite.qrHint")}</div>
                </div>
            ) : null}
            <style>{`
        .inviteWrap{ display:grid; gap:6px; justify-items:center; }
        .inviteRow{ display:flex; gap:8px; flex-wrap:wrap; justify-content:center; }
        .inviteQr{ display:grid; gap:8px; justify-items:center; animation: inviteIn .25s ease both; }
        .inviteQrBox{ background:#fff; padding:10px; border-radius:18px; box-shadow:0 12px 30px rgba(0,0,0,.35); line-height:0; }
        .inviteQrHint{ font-size:13px; opacity:.8; }
        @keyframes inviteIn{ from{opacity:0; transform:translateY(6px)} to{opacity:1; transform:none} }
      `}</style>
        </div>
    );
}
