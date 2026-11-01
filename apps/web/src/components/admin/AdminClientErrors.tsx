"use client";

import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useI18n } from "@/lib/i18n";

type Row = { msg: string | null; path: string | null; n: number; devices: number; last: string };

/** Häufigste Browser-Fehler der letzten 7 Tage (Migration 138) – damit Abstürze auffallen, bevor jemand sich beschwert. */
export function AdminClientErrors() {
    const { tr } = useI18n();
    const [res, setRes] = useState<{ rows: Row[]; error: string } | null>(null);

    useEffect(() => {
        let alive = true;
        void getSupabaseClient()
            .rpc("admin_client_errors", { p_days: 7 })
            .then(({ data, error }) => {
                if (alive) setRes({ rows: error ? [] : ((data ?? []) as Row[]), error: error?.message ?? "" });
            });
        return () => {
            alive = false;
        };
    }, []);

    return (
        <section style={{ marginTop: 18 }}>
            <h3 style={{ margin: "0 0 8px", fontSize: 16 }}>🐞 {tr("Browser-Fehler (7 Tage)")}</h3>
            {!res ? (
                <div className="fieldHelp">{tr("Lade…")}</div>
            ) : res.error ? (
                <div className="fieldHelp fieldHelpError">{res.error}</div>
            ) : !res.rows.length ? (
                <div className="fieldHelp">{tr("Keine Fehler gemeldet – sehr gut.")}</div>
            ) : (
                <div style={{ display: "grid", gap: 6 }}>
                    {res.rows.map((r, i) => (
                        <div key={i} style={{ display: "grid", gridTemplateColumns: "auto 1fr auto", gap: 10, alignItems: "baseline", padding: "8px 10px", borderRadius: 10, background: "rgba(255,255,255,.06)", fontSize: 13 }}>
                            <b style={{ color: "#ffb4a8" }}>{r.n}×</b>
                            <span style={{ overflowWrap: "anywhere" }}>
                                {r.msg ?? "?"} <span style={{ opacity: 0.6 }}>· {r.path ?? "/"} · {tr("{n} Geräte", { n: r.devices })}</span>
                            </span>
                            <span style={{ opacity: 0.6, fontSize: 12 }}>{new Date(r.last).toLocaleString()}</span>
                        </div>
                    ))}
                </div>
            )}
        </section>
    );
}
