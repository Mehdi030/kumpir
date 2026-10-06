import type { MetadataRoute } from "next";

const BASE = process.env.NEXT_PUBLIC_APP_URL || "https://kumpir-web.vercel.app";

export default function sitemap(): MetadataRoute.Sitemap {
    return ["", "/join", "/host", "/login", "/register"].map((p) => ({
        url: `${BASE}${p}`,
        changeFrequency: p === "" ? "weekly" : "monthly",
        priority: p === "" ? 1 : 0.6,
    }));
}
