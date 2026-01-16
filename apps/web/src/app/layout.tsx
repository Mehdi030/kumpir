import "./globals.css";
import Link from "next/link";
import Image from "next/image";

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
        <html lang="de">
        <body>
        <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
            <Image src="/Logo.png" alt="Kumpir" width={56} height={56} priority />
        </Link>

        {children}
        </body>
        </html>
    );
}
