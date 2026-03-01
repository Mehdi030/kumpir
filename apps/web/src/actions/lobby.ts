/**
 * Platzhalter-Funktionen (Mock).
 * Diese Datei macht aktuell noch KEINE echten Supabase-Calls.
 * Wenn du willst, implementieren wir das sauber mit RPC/Queries,
 * aber dafür brauche ich die Tabellen/RPC-Namen oder die bestehenden Server-Actions.
 */

export async function getLobbyState(code: string) {
    // TODO: später Supabase / Realtime
    return null;
}

export async function joinLobby(code: string) {
    // TODO: später Supabase
    return true;
}

export async function setReady(code: string, ready: boolean) {
    // TODO: später Supabase
    return true;
}

export async function startGame(code: string) {
    // TODO: später Supabase
    return true;
}