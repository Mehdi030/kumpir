"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useProfile } from "@/hooks/useProfile";
import { Spinner } from "@/components/Spinner";
import { AdminPanel } from "@/components/admin/AdminPanel";
import { supabaseAdminApi } from "@/lib/adminApi";

/**
 * Admin-Panel: nur für Konten mit Rolle Admin oder Supporter (Migration 078).
 * Die Seite blendet sich für alle anderen aus; die eigentliche Rechteprüfung passiert
 * bei jeder Aktion in der Datenbank.
 */
export default function AdminPage() {
    const { user, profile, loading } = useProfile();
    const api = useMemo(() => supabaseAdminApi(), []);

    if (loading) {
        return (
            <main className="container">
                <Spinner size={26} label="Lade…" />
            </main>
        );
    }

    if (!user || !profile?.isStaff) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" style={{ textAlign: "center" }}>
                        <h1 className="h1" style={{ fontSize: 34 }}>
                            ⛔ Kein Zugriff
                        </h1>
                        <p className="p hostSub" style={{ marginTop: 10 }}>
                            {user ? "Dieser Bereich ist nur für Admins und Supporter." : "Bitte melde dich mit einem Team-Konto an."}
                        </p>
                        <div className="ctaRow" style={{ marginTop: 16 }}>
                            {!user ? (
                                <Link href="/login?next=%2Fadmin" className="btn btnPrimary">
                                    Anmelden
                                </Link>
                            ) : null}
                            <Link href="/" className="btn btnSecondary">
                                Zur Startseite
                            </Link>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    return (
        <main className="container" style={{ alignItems: "flex-start" }}>
            <div className="landingWrap" style={{ width: "min(1100px, 100%)" }}>
                <section className="card" aria-label="Admin-Panel">
                    <AdminPanel api={api} meId={user.id} />
                </section>
            </div>
        </main>
    );
}
