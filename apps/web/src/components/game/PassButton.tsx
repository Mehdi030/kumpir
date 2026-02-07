"use client";

type PassButtonProps = {
    disabled?: boolean;
    onClick: () => void;
};

export function PassButton({ disabled, onClick }: PassButtonProps) {
    return (
        <button
            type="button"
            onClick={onClick}
            disabled={disabled}
            className={`btn btnXL ${
                disabled ? "btnDisabled" : "btnPrimary btnGlow"
            }`}
            style={{
                minWidth: 220,
                fontWeight: 950,
                letterSpacing: 0.4,
            }}
        >
            {disabled ? "⛔ Nicht an dir" : "🥔 Weitergeben"}
        </button>
    );
}
