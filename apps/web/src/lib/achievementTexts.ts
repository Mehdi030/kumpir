/** Texte der Erfolge aus der Datenbank (Tabelle achievements). Nur markiert, damit der Übersetzungs-Test
 *  sie kennt – angezeigt werden sie mit tr(a.title) / tr(a.description). Neue Erfolge hier ergänzen. */
import { tk } from "@/lib/i18nMark";

export const ACHIEVEMENT_TEXTS = [
    [tk("Clutch-Master"), tk("Mache 10 Pässe weniger als 2 Sek. vor der Explosion.")],
    [tk("Eiskalt"), tk("Mache 50 Clutch-Pässe.")],
    [tk("Erstgeborener"), tk("Gewinne deine erste Runde.")],
    [tk("Stammgast"), tk("Spiele 10 Runden zu Ende.")],
    [tk("Veteran"), tk("Spiele 50 Runden zu Ende.")],
    [tk("Matchwinner"), tk("Gewinne ein Match über 3 Runden.")],
    [tk("Serienmeister"), tk("Gewinne ein Match über 5 Runden.")],
    [tk("Allrounder"), tk("Gewinne in jeder der 6 Playlists mindestens eine Runde.")],
    [tk("Lauf"), tk("Erkenne 5 Titel in Folge in einer Runde.")],
    [tk("Ohrwurm"), tk("Erkenne deinen ersten Songtitel.")],
    [tk("Genre-Kenner"), tk("Erkenne 50 Titel aus derselben Playlist.")],
    [tk("Blitzohr"), tk("Erkenne einen Titel in unter 3 Sekunden.")],
    [tk("Musiklexikon"), tk("Erkenne insgesamt 250 Songtitel.")],
    [tk("Plattensammler"), tk("Erkenne insgesamt 50 Songtitel.")],
    [tk("Unzerstörbar"), tk("10 Runden hintereinander am Leben bleiben.")],
    [tk("Überlebenskünstler"), tk("3 Runden hintereinander am Leben bleiben.")],
    [tk("Legende"), tk("Gewinne 100 Runden.")],
    [tk("Champion"), tk("Gewinne 25 Runden.")],
    [tk("Gewinner-Typ"), tk("Gewinne 5 Runden.")],
];
