export function getAppOrigin() {
    // Client: immer korrekt (localhost / preview / prod)
    if (typeof window !== "undefined") return window.location.origin;

    // SSR fallback (optional)
    return process.env.NEXT_PUBLIC_APP_URL || "";
}
