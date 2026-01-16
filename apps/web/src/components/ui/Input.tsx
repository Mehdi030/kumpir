"use client";

import type React from "react";

type Props = React.InputHTMLAttributes<HTMLInputElement> & {
    fullWidth?: boolean;
};

export function Input({ style, fullWidth = true, ...props }: Props) {
    return (
        <input
            {...props}
            style={{
                width: fullWidth ? "100%" : undefined,
                padding: "12px 12px",
                borderRadius: 12,
                border: "1px solid rgba(255,255,255,0.14)",
                background: "rgba(255,255,255,0.06)",
                color: "rgba(255,255,255,0.92)",
                outline: "none",
                transition: "box-shadow .2s ease, border-color .2s ease, background .2s ease",
                ...style,
            }}
            onFocus={(e) => {
                props.onFocus?.(e);
                e.currentTarget.style.boxShadow = "0 0 0 3px rgba(255,255,255,.14), 0 0 0 6px rgba(167,139,250,.18)";
                e.currentTarget.style.borderColor = "rgba(255,255,255,.22)";
            }}
            onBlur={(e) => {
                props.onBlur?.(e);
                e.currentTarget.style.boxShadow = "none";
                e.currentTarget.style.borderColor = "rgba(255,255,255,0.14)";
            }}
        />
    );
}
