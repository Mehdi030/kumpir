import type { MetadataRoute } from "next";

const BASE = process.env.NEXT_PUBLIC_APP_URL || "https://kumpir-web.vercel.app";

export default function robots(): MetadataRoute.Robots {
    return {
        rules: [
            {
                userAgent: "*",
                allow: ["/", "/join"],
                // /solo legt beim Öffnen sofort eine echte Lobby mit Bots an -> für Crawler tabu
                disallow: ["/solo", "/game/", "/lobby/", "/admin/", "/auth/", "/profile", "/friends"],
            },
        ],
        sitemap: `${BASE}/sitemap.xml`,
    };
}
