import "./globals.css";
import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque, Inter } from "next/font/google";
import { AuthProvider } from "@/components/AuthProvider";
import { Analytics } from "@vercel/analytics/next"

const SITE_URL = process.env.NEXT_PUBLIC_APP_URL || "https://kumpir-web.vercel.app";
const SITE_DESC = "Die heiße Kartoffel mit Musik: Song erkennen, Kumpir weitergeben, überleben. Gratis im Browser, ohne Download – allein gegen Bots oder mit Freunden.";

export const metadata: Metadata = {
    metadataBase: new URL(SITE_URL),
    title: { default: "Kumpir – Heiße Kartoffel", template: "%s · Kumpir" },
    description: SITE_DESC,
    openGraph: {
        type: "website",
        siteName: "Kumpir",
        locale: "de_DE",
        title: "Kumpir – Die heiße Kartoffel mit Musik",
        description: SITE_DESC,
        images: [{ url: "/og.png", width: 1200, height: 630, alt: "Kumpir – die heiße Kartoffel mit Musik" }],
    },
    twitter: { card: "summary_large_image", title: "Kumpir – Die heiße Kartoffel mit Musik", description: SITE_DESC, images: ["/og.png"] },
    manifest: "/manifest.webmanifest",
    applicationName: "Kumpir",
    appleWebApp: {
        capable: true,
        title: "Kumpir",
        statusBarStyle: "black-translucent",
    },
    icons: {
        icon: [
            { url: "/icon-192.png", sizes: "192x192", type: "image/png" },
            { url: "/icon-512.png", sizes: "512x512", type: "image/png" },
        ],
        apple: "/apple-touch-icon.png",
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
