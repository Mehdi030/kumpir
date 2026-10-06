"use client";

import React from "react";
import type { Toast } from "@/hooks/useToastStack";

type Props = {
    toasts: Toast[];
    /** Render toasts inline (no fixed positioning). Default: false (fixed bottom-center). */
    inline?: boolean;
};

export function ToastStack({ toasts, inline = false }: Props) {
    if (!toasts.length) return null;

    return (
        <div
            aria-live="polite"
            aria-atomic="true"
            style={
                inline
                    ? { display: "grid", gap: 6, marginTop: 12 }
                    : {
                        position: "fixed",
                        left: "50%",
                        bottom: 88,
                        transform: "translateX(-50%)",
                        zIndex: 1000,
                        display: "grid",
                        gap: 8,
                        pointerEvents: "none",
                        maxWidth: "min(560px, 92vw)",
                    }
            }
        >
            {toasts.map((t) => (
                <div
                    key={t.id}
                    style={{
                        background: "rgba(0,0,0,0.62)",
                        backdropFilter: "blur(10px)",
                        WebkitBackdropFilter: "blur(10px)",
                        color: "white",
                        padding: "10px 14px",
                        borderRadius: 999,
                        fontWeight: 900,
                        fontSize: 14,
                        textAlign: "center",
                        boxShadow: "0 14px 40px rgba(0,0,0,0.32), inset 0 1px 0 rgba(255,255,255,0.10)",
                        border: "1px solid rgba(255,255,255,0.12)",
                        animation: "kumpirToastIn 420ms cubic-bezier(.34,1.56,.64,1) both",
                        pointerEvents: "auto",
                    }}
                >
                    {t.msg}
                </div>
            ))}

            <style jsx global>{`
        @keyframes kumpirToastIn {
          0%   { opacity: 0; transform: translateY(14px) scale(0.9); }
          100% { opacity: 1; transform: translateY(0)    scale(1); }
        }
      `}</style>
        </div>
    );
}
