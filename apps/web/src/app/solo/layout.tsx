import type { Metadata } from "next";

// Solo legt beim Öffnen sofort eine Lobby an: nicht in Suchmaschinen aufnehmen.
export const metadata: Metadata = {
    title: "Solo gegen Bots",
    robots: { index: false, follow: false },
};

export default function SoloLayout({ children }: { children: React.ReactNode }) {
    return children;
}
