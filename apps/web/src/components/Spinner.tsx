"use client";

import React from "react";

type Props = {
    size?: number;
    label?: string;
};

export function Spinner({ size = 22, label }: Props) {
    return (
        <span
            role="status"
            aria-live="polite"
            style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 10,
                fontWeight: 850,
                opacity: 0.92,
            }}
        >
      <span
          aria-hidden
          style={{
              width: size,
              height: size,
              borderRadius: "50%",
              border: `${Math.max(2, Math.round(size / 9))}px solid rgba(255,255,255,0.16)`,
              borderTopColor: "rgba(255,255,255,0.85)",
              animation: "kumpirSpin 0.85s linear infinite",
              display: "inline-block",
          }}
      />
            {label ? <span>{label}</span> : null}

            <style jsx global>{`
        @keyframes kumpirSpin {
          from { transform: rotate(0deg); }
          to   { transform: rotate(360deg); }
        }
      `}</style>
    </span>
    );
}
