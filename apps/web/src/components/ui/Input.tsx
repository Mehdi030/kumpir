"use client";

type Props = React.InputHTMLAttributes<HTMLInputElement>;

export function Input({ style, ...props }: Props) {
    return (
        <input
            {...props}
            style={{
                width: "100%",
                padding: "12px 12px",
                borderRadius: 12,
                border: "1px solid rgba(255,255,255,0.14)",
                background: "rgba(255,255,255,0.06)",
                color: "rgba(255,255,255,0.92)",
                outline: "none",
                ...style,
            }}
        />
    );
}
