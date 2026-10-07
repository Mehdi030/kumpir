/**
 * Server-Fehlercodes (RAISE EXCEPTION in den SQL-Funktionen) -> verständlicher Text für Spieler.
 * Vorher landeten Codes wie "rate_limited" oder "lobby_full" roh im Pop-up.
 * Unbekannte Meldungen werden unverändert durchgereicht (oder durch `fallback` ersetzt, wenn leer).
 */
const TEXT: [RegExp, string][] = [
    [/rate_limited|rate limit|too many/i, "Zu viele Anfragen hintereinander. Bitte kurz warten und erneut versuchen."],
    [/too_fast/, "Kurz warten …"],
    [/lobby_full/, "Die Lobby ist voll."],
    [/lobby_locked/, "Die Lobby ist abgeschlossen – der Host hat sie gesperrt."],
    [/lobby_not_found|lobby nicht gefunden|lobby not found/i, "Diese Lobby gibt es nicht (mehr)."],
    [/lobby_not_waiting|lobby_not_running|game not running|spiel ist bereits beendet/i, "Das geht gerade nicht – die Runde läuft schon oder ist vorbei."],
    [/lobby_not_finished/, "Das geht erst, wenn die Runde vorbei ist."],
    [/identity_taken|user_mismatch|invalid_session/, "Dieser Spieler ist schon auf einem anderen Gerät in der Lobby."],
    [/not_host|only host/i, "Das darf nur der Host."],
    [/not_holder|not holder/i, "Du hast die Kartoffel gerade nicht."],
    [/not_a_member|player_not_found|player not found/i, "Du bist nicht (mehr) in dieser Lobby."],
    [/not_authorized/, "Dafür fehlen dir die Rechte."],
    [/not_logged_in/, "Dafür musst du angemeldet sein."],
    [/cannot_kick_self/, "Du kannst dich nicht selbst rauswerfen."],
    [/cannot_kick_host/, "Der Host kann nicht rausgeworfen werden."],
    [/target_not_active|target player not in lobby/i, "Dieser Spieler ist nicht mehr dabei."],
    [/answer_already_used/, "Diese Antwort wurde schon gesagt."],
    [/answer_too_long|topic_too_long/, "Das ist zu lang."],
    [/empty_answer/, "Bitte erst etwas eintippen."],
    [/attempt_already_open/, "Es läuft schon eine Abstimmung."],
    [/attempt_closed|attempt_not_found/, "Die Abstimmung ist schon vorbei."],
    [/holder_cannot_vote/, "Der Halter stimmt nicht mit ab."],
    [/time_up|too_late/, "Zu spät."],
    [/no_skips_left/, "Kein Joker mehr übrig."],
    [/duel_no_revenge|no_revenge_available/, "Rache geht gerade nicht."],
    [/no_song|song_not_found|playlist_missing/, "Für diese Auswahl gibt es gerade keine Songs."],
    [/too_small_for_current_players/, "Es sind schon mehr Spieler in der Lobby."],
    [/invalid_max_players/, "Ungültige Spielerzahl."],
    [/display_name_invalid|username_invalid/, "Ungültiger Name."],
    [/username_profane/, "Dieser Name ist nicht erlaubt."],
    [/username_taken/, "Dieser Name ist schon vergeben."],
    [/not all players are ready|nicht alle spieler sind bereit/i, "Noch nicht alle Spieler sind bereit."],
    [/failed to fetch|networkerror|load failed|network request failed/i, "Keine Verbindung zum Server. Bitte Internet prüfen und erneut versuchen."],
];

export function errorText(raw: string | null | undefined, fallback = "Das hat nicht geklappt."): string {
    const msg = (raw ?? "").trim();
    if (!msg) return fallback;
    for (const [re, text] of TEXT) if (re.test(msg)) return text;
    return msg;
}
