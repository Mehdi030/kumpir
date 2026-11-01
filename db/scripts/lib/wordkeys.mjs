// Gemeinsame Schreibweisen-Regeln für die Roulette-Begriffslisten (Build-Skript und Schnell-Aktualisierung).
export const STOP_PREFIX = /^(fc|sc|sv|vfb|vfl|tsg|rb|bsc|fsv|tsv|ssv|1\.|ac|as|us|ss|sk|fk|cf|rc|real|der|die|das|the|ein|eine|le|la|les|el|los|il|de|het)\s+/i;

export const norm = (s) =>
    (s ?? "")
        .toLowerCase()
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .replace(/ß/g, "ss")
        .replace(/&/g, " und ")
        .replace(/[^a-z0-9 ]/g, " ")
        .replace(/\s+/g, " ")
        .trim();

/** Schlüssel (Schreibweisen), unter denen ein Begriff gefunden wird (Personen: Vor-/Nachname, letzte zwei Namensteile; Sachen: ohne Artikel/Vereinskürzel) */
export function keysOf(label, kind, aliases = []) {
    const keys = new Set();
    const addName = (name, full) => {
        const n = norm(name);
        if (!n) return;
        keys.add(n);
        if (kind === "person") {
            const parts = n.split(" ");
            if (full && parts.length > 1) keys.add(parts[parts.length - 1]);
            if (full && parts.length > 2) {
                keys.add(parts[0] + " " + parts[parts.length - 1]);
                keys.add(parts.slice(-2).join(" "));
            }
        } else {
            const stripped = n.replace(STOP_PREFIX, "").replace(STOP_PREFIX, "");
            if (stripped && stripped !== n) keys.add(stripped);
        }
    };
    addName(label, true);
    for (const a of aliases) addName(a, false);
    return [...keys].filter((k) => /^[a-z]/.test(k) && k.length >= 2);
}

/** "Name=Kurzform/Zweitname" (Handlisten) -> { label, w, aliases } */
export const hand = (list, w) =>
    list.map((e) => {
        const [label, rest] = e.split("=");
        return { label: label.trim(), w, aliases: rest ? rest.split("/").map((x) => x.trim()).filter(Boolean) : [] };
    });
