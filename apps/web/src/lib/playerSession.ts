const KEY = "kumpir:player_id";

export function getPlayerId(): string | null {
    if (typeof window === "undefined") return null;
    return window.localStorage.getItem(KEY);
}

export function setPlayerId(id: string) {
    window.localStorage.setItem(KEY, id);
}

export function clearPlayerId() {
    window.localStorage.removeItem(KEY);
}
