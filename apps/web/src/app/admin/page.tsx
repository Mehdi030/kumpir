"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useProfile } from "@/hooks/useProfile";
import { Spinner } from "@/components/Spinner";
import { AdminPanel } from "@/components/admin/AdminPanel";
import { supabaseAdminApi } from "@/lib/adminApi";
import { useI18n } from "@/lib/i18n";

/**
 * Admin-Panel: nur für Konten mit Rolle Admin oder Supporter (Migration 078).
 * Die Seite blendet sich für alle anderen aus; die eigentliche Rechteprüfung passiert
 * bei jeder Aktion in der Datenbank.
 */
export default function AdminPage() {
    const { tr } = useI18n();
    const { user, profile, loading } = useProfile();
    const api = useMemo(() => supabaseAdminApi(), []);

    if (loading) {
        return (
            <main className="container">
                <Spinner size={26} label={tr("Lade…")} />
            </main>
        );
    }

    if (!user || !profile?.isStaff) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" style={{ textAlign: "center" }}>
                        <h1 className="h1" style={{ fontSize: 34 }}>
                            {tr("⛔ Kein Zugriff")}
                        </h1>
                        <p className="p hostSub" style={{ marginTop: 10 }}>
                            {user ? tr("Dieser Bereich ist nur für Admins und Supporter.") : tr("Bitte melde dich mit einem Team-Konto an.")}
                        </p>
                        <div className="ctaRow" style={{ marginTop: 16 }}>
                            {!user ? (
                                <Link href="/login?next=%2Fadmin" className="btn btnPrimary">
                                    {tr("Anmelden")}
                                </Link>
                            ) : null}
                            <Link href="/" className="btn btnSecondary">
                                {tr("Zur Startseite")}
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
                <section className="card" aria-label={tr("Admin-Panel")}>
                    <AdminPanel api={api} meId={user.id} />
                </section>
            </div>
        </main>
    );
}
