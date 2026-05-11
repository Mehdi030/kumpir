"use client";

/**
 * Schlanker Browser-Notification-Helper.
 *
 * - Kein Push-Server (keine VAPID-Keys, kein Service Worker im Hintergrund),
 *   sondern echtzeit-Notifications aus dem Tab heraus über die Notification-API.
 *   Funktioniert dadurch nur solange der Tab offen ist (aber im Hintergrund OK).
 * - Permission wird LAZY angefragt — erst wenn der User eine Aktion ausführt
 *   die das opt-in begründet (z.B. "Notify me when it's my turn").
 *
 * Was alles unterstützt:
 *   - "your_turn"     — der Halter hat gewechselt zu mir
 *   - "achievement"   — neues Achievement freigeschaltet
 */

const PREF_KEY = "kumpir_notify_pref";

export type NotificationPref = "off" | "on";

export function getNotifyPref(): NotificationPref {
    if (typeof window === "undefined") return "off";
    try {
        return (window.localStorage.getItem(PREF_KEY) as NotificationPref) ?? "off";
    } catch {
        return "off";
    }
}

export function setNotifyPref(value: NotificationPref) {
    if (typeof window === "undefined") return;
    try {
        window.localStorage.setItem(PREF_KEY, value);
    } catch {
        // ignore
    }
}

export function isNotificationSupported(): boolean {
    return typeof window !== "undefined" && typeof Notification !== "undefined";
}

/**
 * Permission anfragen wenn nötig. Returns "granted" | "denied" | "default".
 */
export async function requestNotifyPermission(): Promise<NotificationPermission> {
    if (!isNotificationSupported()) return "denied";
    if (Notification.permission === "granted") return "granted";
    if (Notification.permission === "denied") return "denied";
    try {
        return await Notification.requestPermission();
    } catch {
        return "denied";
    }
}

/**
 * Zeigt eine Notification — aber nur wenn:
 *  - Browser-API supported
 *  - User-Permission == granted
 *  - User-Pref == "on"
 *  - Tab ist NICHT fokussiert (sonst stört es nur)
 */
export function notify(title: string, body: string, options?: { tag?: string; silent?: boolean }) {
    if (!isNotificationSupported()) return;
    if (Notification.permission !== "granted") return;
    if (getNotifyPref() !== "on") return;
    if (typeof document !== "undefined" && !document.hidden) return; // Tab ist fokussiert

    try {
        new Notification(title, {
            body,
            icon: "/LogoK.png",
            badge: "/LogoK.png",
            tag: options?.tag,
            silent: options?.silent,
        });
    } catch {
        // ignore (z.B. quota errors)
    }
}
