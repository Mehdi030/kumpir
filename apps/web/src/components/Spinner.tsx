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
          className="kmSpinner"
          style={{
              width: size,
              height: size,
              borderWidth: Math.max(2, Math.round(size / 9)),
          }}
      />
            {label ? <span>{label}</span> : null}
    </span>
    );
}
