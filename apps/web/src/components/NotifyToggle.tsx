"use client";

import { useEffect, useState } from "react";
import {
    getNotifyPref,
    isNotificationSupported,
    requestNotifyPermission,
    setNotifyPref,
    type NotificationPref,
} from "@/lib/notifications";

/**
 * Kleiner Toggle-Button um Browser-Notifications zu aktivieren/deaktivieren.
 * Wenn aktiviert: Permission wird angefragt, Pref auf "on" gesetzt.
 * Auf nicht-supporteten Browsern: Button wird gar nicht gerendert.
 */
export function NotifyToggle({ className }: { className?: string }) {
    // Lazy-init: SSR-safe (während Server-Render isNotificationSupported = false)
    const [pref, setPrefState] = useState<NotificationPref>(() =>
        typeof window === "undefined" ? "off" : getNotifyPref()
    );
    const [supported, setSupported] = useState<boolean>(() =>
        typeof window === "undefined" ? false : isNotificationSupported()
    );

    // External state (Browser-API + localStorage) nach Hydration nachziehen.
    /* eslint-disable react-hooks/set-state-in-effect */
    useEffect(() => {
        setSupported(isNotificationSupported());
        setPrefState(getNotifyPref());
    }, []);
    /* eslint-enable react-hooks/set-state-in-effect */

    if (!supported) return null;

    const handleToggle = async () => {
        if (pref === "on") {
            setNotifyPref("off");
            setPrefState("off");
            return;
        }
        const result = await requestNotifyPermission();
        if (result === "granted") {
            setNotifyPref("on");
            setPrefState("on");
        }
    };

    return (
        <button
            type="button"
            className={className ?? "btn btnSecondary btnSmall"}
            onClick={() => void handleToggle()}
            title={pref === "on" ? "Browser-Notifications aus" : "Browser-Notifications an"}
        >
            {pref === "on" ? "🔔 An" : "🔕 Aus"}
        </button>
    );
}
