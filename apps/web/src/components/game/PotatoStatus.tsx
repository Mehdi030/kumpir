"use client";

type PotatoStatusProps = {
    isHolder: boolean;
};

export function PotatoStatus({ isHolder }: PotatoStatusProps) {
    return (
        <div
            style={{
                marginTop: 18,
                marginBottom: 18,
                padding: "18px 16px",
                borderRadius: 18,
                textAlign: "center",
                fontWeight: 900,
                fontSize: 20,
                border: "1px solid rgba(255,255,255,0.12)",
                background: isHolder
                    ? "linear-gradient(135deg, rgba(255,140,0,0.35), rgba(255,80,0,0.25))"
                    : "rgba(255,255,255,0.05)",
                boxShadow: isHolder
                    ? "0 0 40px rgba(255,120,0,0.25)"
                    : "none",
            }}
        >
            {isHolder ? (
                <>
                    🔥 <span style={{ fontWeight: 950 }}>DU HAST DIE KARTOFFEL</span>
                </>
            ) : (
                <>
                    ⏳ <span style={{ opacity: 0.9 }}>Warte…</span>
                </>
            )}
        </div>
    );
}
