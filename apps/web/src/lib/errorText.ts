/**
 * Server-Fehlercodes (RAISE EXCEPTION in den SQL-Funktionen) -> verständlicher Text für Spieler.
 * Vorher landeten Codes wie "rate_limited" oder "lobby_full" roh im Pop-up.
 * Unbekannte Meldungen werden unverändert durchgereicht (oder durch `fallback` ersetzt, wenn leer).
 */
import { tk, trNow } from "@/lib/i18n";

const TEXT: [RegExp, string][] = [
    [/rate_limited|rate limit|too many/i, tk("Zu viele Anfragen hintereinander. Bitte kurz warten und erneut versuchen.")],
    [/too_fast/, tk("Kurz warten …")],
    [/quiz_closed/, tk("Zu spät – diese Frage ist schon vorbei.")],
    [/quiz_not_your_turn/, tk("Du bist gerade nicht dran.")],
    [/quiz_already_answered/, tk("Du hast schon geantwortet.")],
    [/quiz_locked_out/, tk("Du bist für diesen Song raus.")],
    [/quiz_bad_choice|quiz_wrong_action/, tk("Das geht in diesem Modus nicht.")],
    [/quiz_bad_year/, tk("Bitte ein Jahr zwischen 1900 und 2100 eingeben.")],
    [/empty_answer/, tk("Bitte erst etwas eingeben.")],
    [/already_friends/, tk("Ihr seid schon befreundet.")],
    [/already_requested/, tk("Die Anfrage läuft schon.")],
    [/user_not_found/, tk("Diesen Benutzernamen gibt es nicht.")],
    [/avatar_reserved/, tk("Das ist für jemand anderen reserviert.")],
    [/lobby_closed/, tk("Diese Lobby ist geschlossen.")],
    [/lobby_full/, tk("Die Lobby ist voll.")],
    [/lobby_locked/, tk("Die Lobby ist abgeschlossen – der Host hat sie gesperrt.")],
    [/lobby_not_found|lobby nicht gefunden|lobby not found/i, tk("Diese Lobby gibt es nicht (mehr).")],
    [/lobby_not_waiting|lobby_not_running|game not running|spiel ist bereits beendet/i, tk("Das geht gerade nicht – die Runde läuft schon oder ist vorbei.")],
    [/lobby_not_finished/, tk("Das geht erst, wenn die Runde vorbei ist.")],
    [/identity_taken|user_mismatch|invalid_session/, tk("Dieser Spieler ist schon auf einem anderen Gerät in der Lobby.")],
    [/not_host|only host/i, tk("Das darf nur der Host.")],
    [/not_holder|not holder/i, tk("Du hast die Kartoffel gerade nicht.")],
    [/not_a_member|player_not_found|player not found/i, tk("Du bist nicht (mehr) in dieser Lobby.")],
    [/not_authorized/, tk("Dafür fehlen dir die Rechte.")],
    [/not_logged_in/, tk("Dafür musst du angemeldet sein.")],
    [/cannot_kick_self/, tk("Du kannst dich nicht selbst rauswerfen.")],
    [/cannot_kick_host/, tk("Der Host kann nicht rausgeworfen werden.")],
    [/target_not_active|target player not in lobby/i, tk("Dieser Spieler ist nicht mehr dabei.")],
    [/answer_already_used/, tk("Diese Antwort wurde schon gesagt.")],
    [/answer_too_long|topic_too_long/, tk("Das ist zu lang.")],
    [/empty_answer/, tk("Bitte erst etwas eintippen.")],
    [/attempt_already_open/, tk("Es läuft schon eine Abstimmung.")],
    [/attempt_closed|attempt_not_found/, tk("Die Abstimmung ist schon vorbei.")],
    [/holder_cannot_vote/, tk("Der Halter stimmt nicht mit ab.")],
    [/time_up|too_late/, tk("Zu spät.")],
    [/no_skips_left/, tk("Kein Joker mehr übrig.")],
    [/duel_no_revenge|no_revenge_available/, tk("Rache geht gerade nicht.")],
    [/no_song|song_not_found|playlist_missing/, tk("Für diese Auswahl gibt es gerade keine Songs.")],
    [/too_small_for_current_players/, tk("Es sind schon mehr Spieler in der Lobby.")],
    [/invalid_max_players/, tk("Ungültige Spielerzahl.")],
    [/display_name_invalid|username_invalid/, tk("Ungültiger Name.")],
    [/username_profane/, tk("Dieser Name ist nicht erlaubt.")],
    [/username_taken/, tk("Dieser Name ist schon vergeben.")],
    [/not all players are ready|nicht alle spieler sind bereit/i, tk("Noch nicht alle Spieler sind bereit.")],
    [/unknown_error|unknown error|unbekannter fehler/i, tk("Unbekannter Fehler.")],
    [/failed to fetch|networkerror|load failed|network request failed/i, tk("Keine Verbindung zum Server. Bitte Internet prüfen und erneut versuchen.")],
];

export function errorText(raw: string | null | undefined, fallback = tk("Das hat nicht geklappt.")): string {
    const msg = (raw ?? "").trim();
    if (!msg) return trNow(fallback);
    for (const [re, text] of TEXT) if (re.test(msg)) return trNow(text);
    return msg;
}
