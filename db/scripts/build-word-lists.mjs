#!/usr/bin/env node
/**
 * Baut die Begriffs-Listen für den Modus "Roulette" (Buchstabe + Kategorie) -> db/scripts/data/word-lists.json
 * Quelle: Wikidata (öffentliche SPARQL-Abfrage, deutsche Bezeichnungen). Nur BEKANNTE Begriffe: je Kategorie ein
 * Mindest-Wert an Sprachversionen der Wikipedia-Seite (sitelinks) – damit keine Nonames auftauchen.
 * Dazu handgepflegte Listen (Rapper, Tiere, Obst & Gemüse).
 *
 * Aufruf: node db/scripts/build-word-lists.mjs
 * Danach laden: node db/scripts/load-word-lists.mjs
 */
import { writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** kind: "person" = Vor- ODER Nachname zählt für den Buchstaben; "thing" = nur der Anfang des Namens (ohne Artikel/Vereinskürzel) */
const WD = [
    { name: "Länder", kind: "thing", min: 60, where: "?item wdt:P31 wd:Q3624078. FILTER NOT EXISTS { ?item wdt:P576 ?end }" },
    { name: "Hauptstädte", kind: "thing", min: 60, where: "?c wdt:P31 wd:Q3624078. FILTER NOT EXISTS { ?c wdt:P576 ?e } ?c wdt:P36 ?item." },
    { name: "Städte", kind: "thing", min: 70, where: "?item wdt:P31 wd:Q1549591." },
    { name: "Schauspieler", kind: "person", min: 45, where: "VALUES ?occ { wd:Q33999 wd:Q10800557 wd:Q10798782 } ?item wdt:P106 ?occ. ?item wdt:P31 wd:Q5.", limit: 3500 },
    { name: "Sänger", kind: "person", min: 55, where: "VALUES ?occ { wd:Q177220 wd:Q488205 } ?item wdt:P106 ?occ. ?item wdt:P31 wd:Q5.", limit: 2500 },
    { name: "Bands", kind: "thing", min: 45, where: "?item wdt:P31 wd:Q215380.", limit: 1500 },
    { name: "Fußballspieler", kind: "person", min: 60, where: "?item wdt:P106 wd:Q937857. ?item wdt:P31 wd:Q5.", limit: 2500 },
    { name: "Fußballvereine", kind: "thing", min: 55, where: "?item wdt:P31 wd:Q476028.", limit: 1200 },
    { name: "Flüsse", kind: "thing", min: 45, where: "?item wdt:P31 wd:Q4022.", limit: 600 },
    { name: "Serien", kind: "thing", min: 50, where: "?item wdt:P31 wd:Q5398426.", limit: 800 },
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

/** Schlüssel (Schreibweisen), unter denen ein Begriff gefunden wird */
function keysOf(label, kind) {
    const keys = new Set();
    const n = norm(label);
    if (!n) return [];
    keys.add(n);
    if (kind === "person") {
        const parts = n.split(" ");
        if (parts.length > 1) keys.add(parts[parts.length - 1]); // Nachname
    } else {
        const stripped = n.replace(STOP_PREFIX, "").replace(STOP_PREFIX, "");
        if (stripped && stripped !== n) keys.add(stripped);
    }
    return [...keys].filter((k) => /^[a-z]/.test(k) && k.length >= 2);
}

const out = {};
const addAll = (name, kind, labels) => {
    const seen = new Map();
    for (const l of labels) {
        if (!l || /^Q\d+$/.test(l) || !/[A-Za-zÄÖÜäöü]/.test(l.slice(0, 1))) continue;
        if (l.length > 48) continue;
        const k = norm(l);
        if (!k || seen.has(k)) continue;
        seen.set(k, l);
    }
    out[name] = { kind, terms: [...seen.values()] };
    console.log(`${name}: ${out[name].terms.length} Begriffe`);
};

for (const c of WD) {
    process.stdout.write(`Wikidata ${c.name} … `);
    const rows = await sparql(c.where, c.min, c.limit);
    addAll(c.name, c.kind, rows.map((r) => r.label));
    await sleep(2500);
}
addAll("Rapper", "thing", RAPPER);
addAll("Automarken", "thing", AUTOMARKEN);
for (const [cat, extra] of Object.entries(ALIASES)) if (out[cat]) addAll(cat, out[cat].kind, [...out[cat].terms, ...extra]);
addAll("Tiere", "thing", TIERE);
addAll("Obst & Gemüse", "thing", OBST_GEMUESE);

// Schlüssel berechnen
const result = {};
for (const [name, v] of Object.entries(out)) {
    result[name] = { kind: v.kind, terms: v.terms.map((label) => ({ label, keys: keysOf(label, v.kind) })).filter((t) => t.keys.length) };
}
writeFileSync(resolve(__dirname, "data/word-lists.json"), JSON.stringify(result));
const total = Object.values(result).reduce((a, v) => a + v.terms.length, 0);
console.log("Gesamt:", total, "Begriffe ->", "db/scripts/data/word-lists.json");
