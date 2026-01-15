import type { ButtonHTMLAttributes } from "react";

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
    variant?: "primary" | "secondary";
};

export function Button({ variant = "primary", style, ...props }: Props) {
    const isSecondary = variant === "secondary";

    return (
        <button
            {...props}
            style={{
                padding: "12px 14px",
                borderRadius: 12,
                border: "1px solid rgba(255,255,255,0.14)",
                background: props.disabled
                    ? "rgba(255,255,255,0.06)"
                    : isSecondary
                        ? "rgba(255,255,255,0.08)"
                        : "linear-gradient(180deg, rgba(124,92,255,0.95), rgba(124,92,255,0.75))",
                color: "white",
                fontWeight: 800,
                cursor: props.disabled ? "not-allowed" : "pointer",
                ...style,
            }}
        />
    );
}
