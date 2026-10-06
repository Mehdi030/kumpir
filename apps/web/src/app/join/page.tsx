import type { Metadata } from "next";
import JoinClient from "./JoinClient";

export async function generateMetadata({ searchParams }: { searchParams: Promise<{ code?: string }> }): Promise<Metadata> {
    const code = ((await searchParams).code ?? "").toString().toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 4);
    if (code.length !== 4) return { title: "Lobby beitreten" };
    const title = `Komm in meine Kumpir-Lobby (Code ${code})`;
    const description = "Tippen, Name eingeben, mitspielen – ohne Download und ohne Konto. Song erkennen, bevor die Zündschnur durch ist!";
    return { title, description, openGraph: { title, description, images: ["/og.png"] }, twitter: { card: "summary_large_image", title, description, images: ["/og.png"] } };
}

export default async function JoinPage({
                                           searchParams,
                                       }: {
    searchParams: Promise<{ code?: string }>;
}) {
    const sp = await searchParams;
    const initialCode = (sp.code ?? "").toString();
    return <JoinClient initialCode={initialCode} />;
}