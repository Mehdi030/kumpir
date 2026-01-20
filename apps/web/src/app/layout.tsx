import "./globals.css";
import { Baloo_2 } from "next/font/google";

const baloo = Baloo_2({
    subsets: ["latin"],
    weight: ["600", "700", "800"],
    variable: "--font-display",
});

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
        <html lang="de" className={baloo.variable}>
        <body>{children}</body>
        </html>
    );
}

