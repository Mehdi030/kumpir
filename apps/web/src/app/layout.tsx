import "./globals.css";
import "./motion.css";
import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque } from "next/font/google";
import { AuthProvider } from "@/components/AuthProvider";
import { ProfileProvider } from "@/components/ProfileProvider";
import { PreferencesSync } from "@/components/PreferencesSync";
import { AudioUnlock } from "@/components/AudioUnlock";
import { LocaleSync } from "@/components/LocaleSync";
import { PwaSetup } from "@/components/PwaSetup";
import { AdminQuickPanel } from "@/components/admin/AdminQuickPanel";
import { PresencePing } from "@/components/PresencePing";
import { UiFx } from "@/components/UiFx";
import { Embers } from "@/components/Embers";
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

// Nur die Überschriften-Schrift wird geladen (Variable Font); Fließtext nutzt die System-Schrift (spart ~45 KB und einen Request).
const displayFont = Bricolage_Grotesque({
    subsets: ["latin"],
    variable: "--font-display-nf",
});

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
        <html lang="de" className={`${displayFont.variable}`}>
        <head>
            <link rel="preload" href="/fonts/kumpir-emoji.woff2" as="font" type="font/woff2" crossOrigin="anonymous" />
            {/* Song-Vorschauen kommen von hier: Verbindung schon vorher aufbauen, damit der erste Song schneller startet */}
            <link rel="preconnect" href="https://audio-ssl.itunes.apple.com" />
        </head>
        <body>
        <Embers />
        <AuthProvider>
            <ProfileProvider>
                {children}
                <PreferencesSync />
                <AdminQuickPanel />
                <PresencePing />
                <UiFx />
            </ProfileProvider>
        </AuthProvider>
        <Analytics />
        <LocaleSync />
        <AudioUnlock />
        <PwaSetup />
        </body>
        </html>
    );
}
