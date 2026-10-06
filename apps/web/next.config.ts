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

const nextConfig: NextConfig = {
    reactCompiler: true,
    // Statische Bilder/Icons lange cachen (Dateinamen ändern sich nur mit neuem Inhalt)
    async headers() {
        const long = [{ key: "Cache-Control", value: "public, max-age=604800, stale-while-revalidate=86400" }];
        return [
            { source: "/:file(.*\\.(?:png|webp|svg|ico|woff2))", headers: long },
            { source: "/manifest.webmanifest", headers: long },
        ];
    },
    env: {
        NEXT_PUBLIC_BUILD_SHA: resolveBuildSha(),
        NEXT_PUBLIC_BUILD_DATE: new Date().toISOString().slice(0, 16).replace("T", " "),
    },
};

export default nextConfig;
