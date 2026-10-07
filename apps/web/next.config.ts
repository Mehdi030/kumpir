import type { NextConfig } from "next";
import { execSync } from "node:child_process";

// Baut sich einmal beim Build (nicht bei jedem Request) einen kurzen
// Versions-/Datums-Stempel, der z.B. statt "v0 - Gast-Modus" auf der
// Startseite steht. Auf Vercel liefert VERCEL_GIT_COMMIT_SHA den echten
// Deploy-Commit; lokal (npm run dev/build) fällt das auf den aktuellen
// Git-Kurz-Hash zurück, zur Not auf "dev".
function resolveBuildSha(): string {
    if (process.env.VERCEL_GIT_COMMIT_SHA) {
        return process.env.VERCEL_GIT_COMMIT_SHA.slice(0, 7);
    }
    try {
        return execSync("git rev-parse --short HEAD", { cwd: __dirname }).toString().trim();
    } catch {
        return "dev";
    }
}

const isDev = process.env.NODE_ENV !== "production";

// Erlaubte Quellen: eigene Seite, Supabase (API + Realtime), iTunes-Vorschauen, Vercel Analytics.
// 'unsafe-inline' bei Skripten braucht Next.js für seine Start-Skripte; 'unsafe-eval' nur lokal (Hot Reload).
const CSP = [
    "default-src 'self'",
    `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ""} https://va.vercel-scripts.com`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    "media-src 'self' data: blob: https://*.itunes.apple.com https://*.mzstatic.com",
    `connect-src 'self' https://*.supabase.co wss://*.supabase.co https://va.vercel-scripts.com https://vitals.vercel-insights.com${isDev ? " ws: http://localhost:*" : ""}`,
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "frame-src 'none'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
].join("; ");

const SECURITY_HEADERS = [
    { key: "Content-Security-Policy", value: CSP },
    { key: "X-Frame-Options", value: "DENY" },
    { key: "X-Content-Type-Options", value: "nosniff" },
    { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
    { key: "Permissions-Policy", value: "camera=(), geolocation=(), payment=(), usb=(), microphone=(self)" },
    { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" },
    { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
];

const nextConfig: NextConfig = {
    poweredByHeader: false,
    // Nur lokal: zweiter Test-Spieler über http://127.0.0.1:3000 (eigener Browser-Speicher = eigener Spieler)
    allowedDevOrigins: ["127.0.0.1"],
    reactCompiler: true,
    // Statische Bilder/Icons lange cachen (Dateinamen ändern sich nur mit neuem Inhalt)
    async headers() {
        const long = [{ key: "Cache-Control", value: "public, max-age=604800, stale-while-revalidate=86400" }];
        return [
            // Sicherheits-Header für alle Seiten (siehe db/scripts/security-attack.mjs / Migration 080)
            { source: "/:path*", headers: SECURITY_HEADERS },
            { source: "/:file(.*\\.(?:png|webp|svg|ico|woff2))", headers: long },
            { source: "/manifest.webmanifest", headers: long },
            // Service Worker nie lange cachen, sonst kommen Updates nicht an
            { source: "/sw.js", headers: [{ key: "Cache-Control", value: "no-cache, max-age=0" }, { key: "Service-Worker-Allowed", value: "/" }] },
        ];
    },
    env: {
        NEXT_PUBLIC_BUILD_SHA: resolveBuildSha(),
        NEXT_PUBLIC_BUILD_DATE: new Date().toISOString().slice(0, 16).replace("T", " "),
    },
};

export default nextConfig;
