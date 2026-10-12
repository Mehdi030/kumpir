/** Markiert einen deutschen Text zur Übersetzung, ohne ihn schon zu übersetzen (z. B. in Tabellen, die beim
 *  Laden des Moduls entstehen). Übersetzt wird beim Anzeigen mit tr(text) bzw. trNow(text).
 *  Eigene Datei ohne "use client", damit auch Server-Code (actions/) sie importieren kann. */
export function tk(text: string): string {
    return text;
}
