"use client";

import Link from "next/link";

export function AuthGateModal({
                                  open,
                                  onClose,
                                  nextPath,
                                  title = "Konto erforderlich",
                                  text = "Für diese Aktion brauchst du ein Konto. Danach geht’s direkt weiter.",
                              }: {
    open: boolean;
    onClose: () => void;
    nextPath: string;
    title?: string;
    text?: string;
}) {
    if (!open) return null;

    const loginHref = `/login?next=${encodeURIComponent(nextPath)}`;

    return (
        <div role="dialog" aria-modal="true" className="modalOverlay" onClick={onClose}>
            <div className="modalCard" onClick={(e) => e.stopPropagation()}>
                <div className="panelHead">
                    <div className="panelTitle">{title}</div>
                    <div className="panelHint">Kurz & wichtig</div>
                </div>

                <div className="fieldHelp" style={{ marginTop: 8 }}>
                    {text}
                </div>

                <div className="actionsRow" style={{ marginTop: 14 }}>
                    <Link className="btn btnPrimary" href={loginHref}>
                        Anmelden
                    </Link>
                    <Link className="btn btnSecondary" href={loginHref}>
                        Registrieren
                    </Link>
                    <button className="btn btnSecondary" onClick={onClose}>
                        Abbrechen
                    </button>
                </div>
            </div>
        </div>
    );
}
