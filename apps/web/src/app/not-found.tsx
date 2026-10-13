import { NotFoundContent } from "@/components/NotFoundContent";

export const metadata = { title: "Seite nicht gefunden" };

/** Eigene 404-Seite im Kumpir-Stil (statt der schwarzen englischen Standardseite). */
export default function NotFound() {
    return (
        <main className="container">
            <div className="landingWrap" style={{ width: "min(560px, 100%)" }}>
                <NotFoundContent />
            </div>
        </main>
    );
}
