import "./globals.css";
import { Bricolage_Grotesque, Inter } from "next/font/google";
import { AuthProvider } from "@/components/AuthProvider";
import { Analytics } from "@vercel/analytics/next"

const displayFont = Bricolage_Grotesque({
    subsets: ["latin"],
    weight: ["600", "700", "800"],
    variable: "--font-display",
});

const bodyFont = Inter({
    subsets: ["latin"],
    weight: ["400", "500", "600"],
    variable: "--font-body",
});

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
        <html lang="de" className={`${displayFont.variable} ${bodyFont.variable}`}>
        <body>
        <AuthProvider>{children}</AuthProvider>
        </body>
        </html>
    );
}
