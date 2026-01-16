import type { ButtonHTMLAttributes } from "react";

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
    variant?: "primary" | "secondary";
    fullWidth?: boolean;
};

export function Button({ variant = "primary", fullWidth, style, ...props }: Props) {
    const isSecondary = variant === "secondary";

    return (
        <button
            {...props}
            style={{
                width: fullWidth ? "100%" : undefined,
                padding: "12px 14px",
                borderRadius: 12,
                border: "1px solid rgba(255,255,255,0.14)",
                background: props.disabled
                    ? "rgba(255,255,255,0.06)"
                    : isSecondary
                        ? "rgba(0,0,0,0.14)"
                        : "linear-gradient(135deg, #F3D1A1, #E7B97E)",
                color: props.disabled ? "rgba(255,255,255,0.55)" : isSecondary ? "rgba(255,255,255,0.92)" : "#3A2410",
                fontWeight: 900,
                letterSpacing: ".01em",
                cursor: props.disabled ? "not-allowed" : "pointer",
                transition: "transform .15s ease, filter .2s ease, box-shadow .2s ease",
                ...(props.disabled
                    ? {}
                    : {
                        boxShadow: isSecondary ? "none" : "0 10px 26px rgba(0,0,0,.16)",
                    }),
                ...style,
            }}
            onMouseDown={(e) => {
                props.onMouseDown?.(e);
                if (props.disabled) return;
                (e.currentTarget as HTMLButtonElement).style.transform = "translateY(0)";
            }}
            onMouseEnter={(e) => {
                props.onMouseEnter?.(e);
                if (props.disabled) return;
                (e.currentTarget as HTMLButtonElement).style.transform = "translateY(-1px)";
                (e.currentTarget as HTMLButtonElement).style.filter = "brightness(1.05)";
            }}
            onMouseLeave={(e) => {
                props.onMouseLeave?.(e);
                (e.currentTarget as HTMLButtonElement).style.transform = "translateY(0)";
                (e.currentTarget as HTMLButtonElement).style.filter = "none";
            }}
        />
    );
}
