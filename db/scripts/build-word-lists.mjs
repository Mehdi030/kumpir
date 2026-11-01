#!/usr/bin/env node
/**
 * Baut die Begriffs-Listen für den Modus "Roulette" (Buchstabe + Kategorie) -> db/scripts/data/word-lists.json
 * Quelle: Wikidata (öffentliche SPARQL-Abfrage, deutsche Bezeichnungen). Nur BEKANNTE Begriffe: je Kategorie ein
 * Mindest-Wert an Sprachversionen der Wikipedia-Seite (sitelinks) – damit keine Nonames auftauchen.
 * Dazu handgepflegte Listen (Rapper, Tiere, Obst & Gemüse, Automarken; Erweiterungen in data/word-extras.mjs).
 * Damit möglichst viel Richtiges erkannt wird: niedrige Mindest-Werte (viele Einträge), Zweitnamen/Kurzformen aus Wikidata
 * (altLabel), mehrere Schreibweisen je Person (Vor-+Nachname, Nachname, letzte zwei Namensteile) und ein Gewicht (Bekanntheit =
 * Anzahl Sprachversionen), nach dem die Bots nur aus dem bekannteren Teil der Liste tippen.
 *
 * Aufruf: node db/scripts/build-word-lists.mjs
 * Danach laden: node db/scripts/load-word-lists.mjs
 */
import { writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { TIERE_EXTRA, OBST_GEMUESE_EXTRA, AUTOMARKEN_EXTRA, RAPPER_EXTRA } from "./data/word-extras.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** kind: "person" = Vor- ODER Nachname zählt für den Buchstaben; "thing" = nur der Anfang des Namens (ohne Artikel/Vereinskürzel) */
const WD = [
    { name: "Länder", kind: "thing", min: 25, where: "?item wdt:P31 wd:Q3624078. FILTER NOT EXISTS { ?item wdt:P576 ?end }" },
    { name: "Hauptstädte", kind: "thing", min: 25, where: "?c wdt:P31 wd:Q3624078. FILTER NOT EXISTS { ?c wdt:P576 ?e } ?c wdt:P36 ?item." },
    { name: "Städte", kind: "thing", min: 40, where: "?item wdt:P31 wd:Q1549591.", limit: 4000 },
    { name: "Schauspieler", kind: "person", min: 28, where: "VALUES ?occ { wd:Q33999 wd:Q10800557 wd:Q10798782 } ?item wdt:P106 ?occ. ?item wdt:P31 wd:Q5.", limit: 7000 },
    { name: "Sänger", kind: "person", min: 28, where: "VALUES ?occ { wd:Q177220 wd:Q488205 } ?item wdt:P106 ?occ. ?item wdt:P31 wd:Q5.", limit: 5000 },
    { name: "Bands", kind: "thing", min: 25, where: "?item wdt:P31 wd:Q215380.", limit: 3000 },
    { name: "Fußballspieler", kind: "person", min: 30, where: "?item wdt:P106 wd:Q937857. ?item wdt:P31 wd:Q5.", limit: 6000 },
    { name: "Fußballvereine", kind: "thing", min: 22, where: "?item wdt:P31 wd:Q476028.", limit: 3000 },
    { name: "Flüsse", kind: "thing", min: 25, where: "?item wdt:P31 wd:Q4022.", limit: 2500 },
    { name: "Serien", kind: "thing", min: 25, where: "?item wdt:P31 wd:Q5398426.", limit: 3000 },
];

/** Deutsche Rapper (Künstlernamen) – bekannte, handgepflegt (Wikidata kennt viele Straßenrapper nicht) */
const RAPPER = `Capital Bra, Bushido, Sido, Kollegah, Farid Bang, Fler, Massiv, Eko Fresh, Kool Savas, Azad, Haftbefehl, Samra, Mero, Animus, Majoe, Hanybal, Celo & Abdi, Ali Bumaye, Shindy, Casper, Marteria, Cro, Prinz Pi, Samy Deluxe, Olexesh, Nimo, Ufo361, Gzuz, Bonez MC, RAF Camora, Azet, Zuna, Mois, Dardan, Eno, Luciano, Apache 207, Kontra K, Jamule, Veysel, LX, Maxwell, SSIO, Fard, Genetikk, Sonny Black, Frank White, Toni der Assi, Bass Sultan Hengzt, Jalil, Gringo, Hamad 45, Reezy, Miami Yacine, Trettmann, Nura, Sero El Mero, Ardian Bujupi, Disarstar, Content, Pa Sports, 18 Karat, Lil Lano, Loredana, Shirin David, Alpa Gun, Bozza, KC Rebell, Summer Cem, Moses Pelham, Jonesmann, Sabrina Setlur, Afrob, Torch, Curse, Kaas, Cora E, Dendemann, Chefket, Ben Salomo, Tua, Megaloh, Kurdo, Dú Maroc, Ensemble, Ahzumjot, Kalazh44, Lugatti, Capo, Jazeek, Lune, MC Fitti, Fettes Brot, Die Fantastischen Vier, Deichkind, Peter Fox, Seeed, Jan Delay, Textor, Dr. Dre, Eminem, 50 Cent, Snoop Dogg, 2Pac, Notorious B.I.G., Jay-Z, Kanye West, Drake, Kendrick Lamar, Nas, Ice Cube, Ludacris, Lil Wayne, Travis Scott, Post Malone, Future, Nicki Minaj, Cardi B, Lil Nas X, Tyler the Creator, Macklemore, Busta Rhymes, DMX, Method Man, Snoop Lion, Ice-T, LL Cool J, Run DMC, Wiz Khalifa, Mac Miller, Juice WRLD, Megan Thee Stallion, A$AP Rocky, Pitbull, Flo Rida, T.I., Nelly, Chingy`.split(/\s*,\s*/);

const TIERE = `Affe, Ameisenbär, Antilope, Adler, Ameise, Amsel, Biene, Bär, Biber, Büffel, Bussard, Cobra, Chamäleon, Delfin, Dachs, Dackel, Dromedar, Drossel, Ente, Elefant, Esel, Eule, Eichhörnchen, Echse, Elch, Eisbär, Frosch, Fuchs, Falke, Flamingo, Fledermaus, Fisch, Forelle, Fliege, Floh, Gans, Giraffe, Gorilla, Gepard, Gecko, Gazelle, Gürteltier, Hase, Hund, Huhn, Hirsch, Hai, Hamster, Hirsch, Hyäne, Hummer, Hornisse, Igel, Iltis, Impala, Jaguar, Känguru, Katze, Kuh, Krokodil, Koala, Kamel, Kaninchen, Krake, Kranich, Krebs, Kobra, Kolibri, Kakadu, Käfer, Kiwi, Löwe, Leopard, Libelle, Lama, Luchs, Laus, Maus, Marder, Maulwurf, Möwe, Mücke, Murmeltier, Nashorn, Nilpferd, Nandu, Natter, Otter, Orang-Utan, Ochse, Oktopus, Papagei, Pferd, Pinguin, Panther, Puma, Pelikan, Pfau, Python, Qualle, Rabe, Reh, Ratte, Robbe, Rentier, Raupe, Rotkehlchen, Schwein, Schaf, Schlange, Schmetterling, Schwan, Seehund, Seepferdchen, Skorpion, Spatz, Specht, Spinne, Storch, Stier, Strauß, Schildkröte, Salamander, Sardine, Tiger, Taube, Tintenfisch, Truthahn, Tukan, Termite, Uhu, Waschbär, Wal, Wolf, Wespe, Wurm, Wildschwein, Wiesel, Walross, Yak, Zebra, Ziege, Zecke, Zander, Hering, Lachs, Thunfisch, Karpfen, Hecht, Aal, Barsch, Meerschweinchen, Wellensittich, Kanarienvogel, Nacktmull, Erdmännchen, Faultier, Tapir, Okapi, Lemur, Mungo, Pavian, Schimpanse, Panda, Wombat, Beuteltier, Frettchen, Gnu, Warzenschwein, Steinbock, Gämse, Alpaka, Husky, Pudel, Bulldogge, Schäferhund, Mops, Dobermann, Chihuahua`.split(/\s*,\s*/);

const OBST_GEMUESE = `Apfel, Birne, Banane, Orange, Mandarine, Zitrone, Limette, Erdbeere, Himbeere, Brombeere, Blaubeere, Heidelbeere, Johannisbeere, Stachelbeere, Kirsche, Pflaume, Zwetschge, Pfirsich, Nektarine, Aprikose, Ananas, Mango, Papaya, Kiwi, Melone, Wassermelone, Honigmelone, Traube, Granatapfel, Feige, Dattel, Kokosnuss, Avocado, Maracuja, Litschi, Grapefruit, Quitte, Mirabelle, Holunder, Cranberry, Kürbis, Karotte, Möhre, Kartoffel, Tomate, Gurke, Paprika, Zwiebel, Knoblauch, Lauch, Brokkoli, Blumenkohl, Rosenkohl, Rotkohl, Weißkohl, Spinat, Salat, Radieschen, Rettich, Sellerie, Spargel, Zucchini, Aubergine, Erbse, Bohne, Linse, Mais, Fenchel, Kohlrabi, Rote Bete, Petersilie, Schnittlauch, Pilz, Champignon, Süßkartoffel, Ingwer, Chili, Oliven, Artischocke, Mangold, Pastinake, Meerrettich, Rhabarber, Wirsing, Radicchio, Rucola, Kresse, Dill, Basilikum, Oregano, Thymian, Rosmarin, Minze`.split(/\s*,\s*/);

const AUTOMARKEN = `Audi, BMW, Mercedes, Mercedes-Benz, Volkswagen, VW, Porsche, Opel, Ford, Toyota, Honda, Nissan, Mazda, Mitsubishi, Suzuki, Subaru, Lexus, Hyundai, Kia, Skoda, Seat, Cupra, Renault, Peugeot, Citroën, Fiat, Alfa Romeo, Lancia, Ferrari, Lamborghini, Maserati, Bugatti, Pagani, Bentley, Rolls-Royce, Aston Martin, Jaguar, Land Rover, Mini, McLaren, Lotus, Volvo, Saab, Tesla, Chevrolet, Cadillac, Dodge, Jeep, Chrysler, Buick, Lincoln, Hummer, Smart, Dacia, Daihatsu, Infiniti, Acura, Genesis, Polestar, BYD, Maybach, Trabant, Wartburg, Borgward, Ssangyong, Isuzu, Lada, Tata, Mahindra, Rover, Pontiac, Mustang, DS, Alpine, Abarth, Koenigsegg, Rimac, NIO, Lucid, Rivian, Brabus, Alpina, Opel Manta`.split(/\s*,\s*/);

const ALIASES = {
    "Länder": ["USA", "Amerika", "England", "Holland", "Großbritannien", "Schottland", "Wales", "Nordirland", "Emirate", "Tschechien", "Weißrussland", "Elfenbeinküste", "Kongo", "Myanmar", "Burma", "Swasiland", "Türkei", "Korea"],
    "Städte": ["New York", "Los Angeles", "San Francisco", "Las Vegas", "Rio de Janeiro", "Buenos Aires", "Mexiko-Stadt", "Hongkong", "Sankt Petersburg", "Frankfurt", "Mailand", "Neapel", "Venedig", "Florenz", "Prag", "Wien", "Zürich", "Kopenhagen"],
};

const STOP_PREFIX = /^(fc|sc|sv|vfb|vfl|tsg|rb|bsc|fsv|tsv|ssv|1\.|ac|as|us|ss|sk|fk|cf|rc|real|der|die|das|the|ein|eine|le|la|les|el|los|il|de|het)\s+/i;

const norm = (s) =>
    (s ?? "")
        .toLowerCase()
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .replace(/ß/g, "ss")
        .replace(/&/g, " und ")
        .replace(/[^a-z0-9 ]/g, " ")
        .replace(/\s+/g, " ")
        .trim();

/** Manche sehr bekannte Einträge (z. B. Lady Gaga, Shakira) haben bei Wikidata gerade kein Label und kämen nur als Q-Nummer – ihr Name wird dann aus dem Titel der deutschen/englischen Wikipedia-Seite geholt */
async function fixLabels(rows) {
    const missing = rows.filter((r) => /^Q[0-9]+$/.test(r.label));
    for (let i = 0; i < missing.length; i += 150) {
        const part = missing.slice(i, i + 150);
        const q = `SELECT ?item ?de ?en WHERE { VALUES ?item { ${part.map((x) => "wd:" + x.id).join(" ")} } OPTIONAL { ?a schema:about ?item; schema:isPartOf <https://de.wikipedia.org/>; schema:name ?de } OPTIONAL { ?b schema:about ?item; schema:isPartOf <https://en.wikipedia.org/>; schema:name ?en } }`;
        try {
            const r = await fetch("https://query.wikidata.org/sparql?format=json&query=" + encodeURIComponent(q), {
                headers: { "User-Agent": "KumpirGameBot/1.0 (private game; contact via repo owner)", Accept: "application/sparql-results+json" },
            });
            const names = new Map();
            for (const b of (await r.json()).results.bindings) names.set(b.item.value.split("/").pop(), (b.de?.value ?? b.en?.value ?? "").replace(/ ?[(].*[)] ?$/, ""));
            for (const x of part) if (names.get(x.id)) x.label = names.get(x.id);
        } catch (e) {
            console.log("  Label-Fehler", e.message);
        }
        await sleep(1500);
    }
    return rows;
}

async function sparql(where, min, limit) {
    const q = `SELECT ?item ?itemLabel ?sl WHERE { ${where} ?item wikibase:sitelinks ?sl. FILTER(?sl >= ${min}) SERVICE wikibase:label { bd:serviceParam wikibase:language "de,en". } } ORDER BY DESC(?sl) ${limit ? `LIMIT ${limit}` : ""}`;
    for (let a = 0; a < 4; a++) {
        try {
            const r = await fetch("https://query.wikidata.org/sparql?format=json&query=" + encodeURIComponent(q), {
                headers: { "User-Agent": "KumpirGameBot/1.0 (private game; contact via repo owner)", Accept: "application/sparql-results+json" },
            });
            if (r.ok) return await fixLabels((await r.json()).results.bindings.map((b) => ({ label: b.itemLabel.value, sl: Number(b.sl.value), id: b.item.value.split("/").pop() })));
            console.log("  HTTP", r.status);
        } catch (e) {
            console.log("  Fehler", e.message);
        }
        await sleep(8000 * (a + 1));
    }
    return [];
}

/** Zweitnamen/Kurzformen (altLabel, deutsch + englisch) für viele Wikidata-Einträge auf einmal: id -> [Namen] */
async function fetchAliases(ids) {
    const map = new Map();
    for (let i = 0; i < ids.length; i += 120) {
        const part = ids.slice(i, i + 120);
        const q = `SELECT ?item ?alt WHERE { VALUES ?item { ${part.map((x) => "wd:" + x).join(" ")} } ?item skos:altLabel ?alt. FILTER(LANG(?alt) = "de" || LANG(?alt) = "en") }`;
        for (let a = 0; a < 3; a++) {
            try {
                const r = await fetch("https://query.wikidata.org/sparql?format=json&query=" + encodeURIComponent(q), {
                    headers: { "User-Agent": "KumpirGameBot/1.0 (private game; contact via repo owner)", Accept: "application/sparql-results+json" },
                });
                if (r.ok) {
                    for (const b of (await r.json()).results.bindings) {
                        const id = b.item.value.split("/").pop();
                        const arr = map.get(id) ?? [];
                        arr.push(b.alt.value);
                        map.set(id, arr);
                    }
                    break;
                }
            } catch {
                /* nochmal */
            }
            await sleep(4000 * (a + 1));
        }
        await sleep(800);
        if ((i / 120) % 10 === 9) process.stdout.write(`${i + 120}/${ids.length} `);
    }
    return map;
}

/** Schlüssel (Schreibweisen), unter denen ein Begriff gefunden wird */
function keysOf(label, kind, aliases = []) {
    const keys = new Set();
    const addName = (name, full) => {
        const n = norm(name);
        if (!n) return;
        keys.add(n);
        if (kind === "person") {
            const parts = n.split(" ");
            if (full && parts.length > 1) keys.add(parts[parts.length - 1]); // Nachname
            if (full && parts.length > 2) {
                keys.add(parts[0] + " " + parts[parts.length - 1]); // Vor- + Nachname ohne Zweitnamen
                keys.add(parts.slice(-2).join(" ")); // letzte zwei Namensteile ("van Damme", "dos Santos")
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

const out = {};
/** items: { label, w, aliases[] }. Gleiche Schreibweise nur einmal (höchstes Gewicht, Zweitnamen zusammengelegt). */
const addAll = (name, kind, items) => {
    const seen = new Map();
    for (const it of items) {
        const l = it.label;
        if (!l || /^Q[0-9]+$/.test(l) || !/[A-Za-zÄÖÜäöü]/.test(l.slice(0, 1))) continue;
        if (l.length > 48) continue;
        const k = norm(l);
        if (!k) continue;
        const prev = seen.get(k);
        if (prev) {
            prev.w = Math.max(prev.w, it.w ?? 0);
            prev.aliases = [...new Set([...prev.aliases, ...(it.aliases ?? [])])];
        } else seen.set(k, { label: l, w: it.w ?? 0, aliases: [...(it.aliases ?? [])] });
    }
    out[name] = { kind, terms: [...seen.values()] };
    console.log(`${name}: ${out[name].terms.length} Begriffe`);
};
/** "Name=Kurzform/Zweitname" (Handlisten) -> { label, w, aliases } */
const hand = (list, w) =>
    list.map((e) => {
        const [label, rest] = e.split("=");
        return { label: label.trim(), w, aliases: rest ? rest.split("/").map((x) => x.trim()).filter(Boolean) : [] };
    });
const plain = (list, w) => list.map((label) => ({ label, w, aliases: [] }));

const wdRows = new Map(); // Kategorie -> Zeilen
for (const c of WD) {
    process.stdout.write(`Wikidata ${c.name} … `);
    const rows = await sparql(c.where, c.min, c.limit);
    wdRows.set(c.name, rows);
    console.log(rows.length, "Zeilen");
    await sleep(2500);
}
// Zweitnamen für alle Treffer
{
    const ids = [...new Set([...wdRows.values()].flat().map((r) => r.id))];
    process.stdout.write(`Zweitnamen für ${ids.length} Einträge … `);
    const aliasMap = await fetchAliases(ids);
    console.log("fertig,", aliasMap.size, "mit Zweitnamen");
    for (const c of WD) {
        const items = (wdRows.get(c.name) ?? []).map((r) => ({
            label: r.label,
            w: r.sl,
            aliases: (aliasMap.get(r.id) ?? []).filter((a) => a.length >= 3 && a.length <= 40 && /^[A-Za-zÄÖÜäöü0-9]/.test(a)).slice(0, 8),
        }));
        addAll(c.name, c.kind, items);
    }
}
addAll("Rapper", "thing", [...hand(RAPPER, 100), ...hand(RAPPER_EXTRA, 60)]);
addAll("Automarken", "thing", [...plain(AUTOMARKEN, 100), ...hand(AUTOMARKEN_EXTRA, 60)]);
for (const [cat, extra] of Object.entries(ALIASES)) if (out[cat]) addAll(cat, out[cat].kind, [...out[cat].terms, ...plain(extra, 90)]);
addAll("Tiere", "thing", [...plain(TIERE, 100), ...plain(TIERE_EXTRA, 60)]);
addAll("Obst & Gemüse", "thing", [...plain(OBST_GEMUESE, 100), ...plain(OBST_GEMUESE_EXTRA, 60)]);

// Schlüssel berechnen
const result = {};
for (const [name, v] of Object.entries(out)) {
    result[name] = { kind: v.kind, terms: v.terms.map((t) => ({ label: t.label, w: t.w, keys: keysOf(t.label, v.kind, t.aliases) })).filter((t) => t.keys.length) };
}
writeFileSync(resolve(__dirname, "data/word-lists.json"), JSON.stringify(result));
const total = Object.values(result).reduce((a, v) => a + v.terms.length, 0);
console.log("Gesamt:", total, "Begriffe ->", "db/scripts/data/word-lists.json");
