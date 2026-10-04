import "./globals.css";
import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque, Inter } from "next/font/google";
import { AuthProvider } from "@/components/AuthProvider";
import { Analytics } from "@vercel/analytics/next"

export const metadata: Metadata = {
    title: "Kumpir – Heiße Kartoffel",
    description: "Browserbasiertes Partyspiel nach dem Prinzip der heißen Kartoffel.",
    manifest: "/manifest.webmanifest",
    applicationName: "Kumpir",
    appleWebApp: {
        capable: true,
        title: "Kumpir",
        statusBarStyle: "black-translucent",
    },
    icons: {
        icon: "/HGLogo.png",
        apple: "/HGLogo.png",
    },
};

export const viewport: Viewport = {
    themeColor: "#8f0f0f",
    width: "device-width",
    initialScale: 1,
};

// Variable Fonts (ohne weight-Liste): alle Stärken 100-800 stehen sauber zur Verfügung,
// statt dass der Browser fette Schnitte künstlich nachbaut.
const displayFont = Bricolage_Grotesque({
    subsets: ["latin"],
    variable: "--font-display",
});

const bodyFont = Inter({
    subsets: ["latin"],
    variable: "--font-body",
});

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
        <html lang="de" className={`${displayFont.variable} ${bodyFont.variable}`}>
        <body>
        <AuthProvider>{children}</AuthProvider>
        <Analytics />
        </body>
        </html>
    );
}
