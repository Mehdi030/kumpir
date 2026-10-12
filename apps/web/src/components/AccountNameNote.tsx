"use client";

import Link from "next/link";
import { useI18n } from "@/lib/i18n";

/** Mit Konto: fester Spielername statt Eingabefeld – ändern nur in den Einstellungen (Wunsch Mehdi 2026-10-12). */
export function AccountNameNote({ name }: { name: string }) {
    const { tr } = useI18n();
    return (
        <div className="accountName">
            <span className="accountNameLabel">{tr("Du spielst als")}</span>
            <b className="accountNameValue">{name}</b>
            <Link href="/profile" className="accountNameLink">
                {tr("Ändern in den Einstellungen")}
            </Link>
        </div>
    );
}
