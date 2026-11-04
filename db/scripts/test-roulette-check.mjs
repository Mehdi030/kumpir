#!/usr/bin/env node
// Prüft die Roulette-Prüfung (Migration 141) gegen bekannte Begriffe:
//   1) Bekannte Begriffe jeder Kategorie werden erkannt (zum eigenen Anfangsbuchstaben)
//   2) Typische Tippfehler werden verziehen, aber nur wo erlaubt
//   3) Falsche Wörter und Wörter aus anderen Kategorien werden abgelehnt
// Aufruf: node db/scripts/test-roulette-check.mjs   (zeigt zusätzlich, welche Begriffe fehlen)
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.trim().startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]),
);
const db = new pg.Client({
    host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false },
});
await db.connect();
const q = async (sql, a = []) => (await db.query(sql, a)).rows;
let failed = 0;
const check = (name, ok, detail = "") => {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
};

const KNOWN = {
    "Länder": "Afghanistan Ägypten Albanien Algerien Argentinien Australien Belgien Bolivien Brasilien Bulgarien Chile China Dänemark Deutschland Ecuador Estland Finnland Frankreich Georgien Ghana Griechenland Indien Indonesien Irak Iran Irland Island Israel Italien Japan Jordanien Kanada Kenia Kolumbien Kroatien Kuba Lettland Libanon Litauen Luxemburg Malta Marokko Mexiko Neuseeland Niederlande Nigeria Norwegen Österreich Pakistan Peru Polen Portugal Rumänien Russland Schweden Schweiz Serbien Slowakei Slowenien Spanien Südafrika Syrien Thailand Tschechien Tunesien Türkei Ukraine Ungarn Uruguay USA Venezuela Vietnam Zypern Holland England Schottland Südkorea Nordkorea Katar Senegal Kamerun Äthiopien Panama Jamaika Mongolei Nepal Philippinen Singapur Malaysia Kasachstan Armenien Belarus Monaco Madagaskar Angola Uganda Tansania Somalia Libyen Weißrussland Wales".split(" "),
    "Städte": "Aachen Augsburg Berlin Bielefeld Bochum Bonn Bremen Dortmund Dresden Duisburg Düsseldorf Erfurt Essen Frankfurt Freiburg Gelsenkirchen Göttingen Hamburg Hannover Heidelberg Kassel Kiel Köln Leipzig Lübeck Magdeburg Mainz Mannheim München Münster Nürnberg Oldenburg Osnabrück Paderborn Potsdam Regensburg Rostock Saarbrücken Stuttgart Trier Ulm Wiesbaden Wolfsburg Würzburg Wien Zürich Paris London Rom Madrid Barcelona Amsterdam Brüssel Prag Warschau Budapest Istanbul Ankara Athen Lissabon Moskau Tokio Peking Shanghai Chicago Miami Sydney Kairo Dubai Venedig Mailand Neapel Florenz Salzburg Innsbruck Graz Linz Genf Basel Bern Kopenhagen Oslo Stockholm Helsinki Dublin Edinburgh Manchester Liverpool Marseille Lyon Nizza Toronto Vancouver Delhi Mumbai Bangkok Seoul Hongkong Zagreb Belgrad Sofia Bukarest Kiew Minsk Riga Tallinn Vilnius Rotterdam Antwerpen Gent Brügge Turin Bologna Genua Verona Sevilla Valencia Bilbao Porto Dortmund Kaiserslautern Karlsruhe Jena Weimar Cottbus".split(" "),
    "Tiere": "Affe Adler Ameise Bär Biene Büffel Delfin Dachs Elefant Ente Esel Eule Eichhörnchen Fisch Fuchs Frosch Flamingo Giraffe Gans Gorilla Hase Hund Hirsch Huhn Hai Igel Jaguar Känguru Katze Kuh Krokodil Kamel Kaninchen Löwe Libelle Leopard Lama Maus Möwe Marder Nashorn Nilpferd Otter Ochse Papagei Pferd Pinguin Panda Pfau Qualle Rabe Reh Ratte Robbe Schaf Schlange Schwein Schmetterling Spinne Storch Tiger Taube Truthahn Uhu Vogel Wolf Wal Wespe Wurm Ziege Zebra Zecke Hamster Hirsch Hyäne Ratte Seehund Seepferdchen Specht Schildkröte Wildschwein Waschbär Walross Yak Gepard Gazelle Eisbär Dromedar Chamäleon".split(" "),
    "Obst & Gemüse": "Apfel Aprikose Ananas Avocado Banane Birne Brombeere Blumenkohl Brokkoli Bohne Erdbeere Erbse Gurke Grapefruit Himbeere Heidelbeere Honigmelone Ingwer Johannisbeere Kirsche Kiwi Kartoffel Karotte Kürbis Knoblauch Kohl Limette Litschi Mango Mandarine Melone Möhre Mais Nektarine Orange Olive Paprika Pfirsich Pflaume Petersilie Radieschen Rosenkohl Rhabarber Spinat Salat Sellerie Spargel Tomate Traube Weintraube Wassermelone Zitrone Zucchini Zwiebel Zwetschge Lauch Fenchel Aubergine Feige Granatapfel Dattel Maracuja Papaya Quitte Rote_Bete Süßkartoffel Champignon".split(" ").map((x) => x.replace("_", " ")),
    "Fußballspieler": "Messi Ronaldo Neymar Mbappé Haaland Lewandowski Müller Neuer Kroos Özil Götze Klose Schweinsteiger Beckenbauer Maradona Pelé Zidane Henry Ibrahimović Kane Modrić Salah De_Bruyne Benzema Ramos Iniesta Xavi Buffon Pirlo Totti Baggio Cruyff Rooney Beckham Gerrard Lampard Drogba Son Musiala Wirtz Havertz Gnabry Sané Kimmich Gündogan Rüdiger Reus Hummels Boateng Podolski Ballack Matthäus Rummenigge Völler Brehme Effenberg Kahn Lahm Khedira Ribéry Robben Bellingham Griezmann Pogba Kanté Lukaku Hazard Courtois Casillas Torres Villa Raúl Puyol Busquets Suárez Cavani Aubameyang Mané Yamal Pedri Gavi Osimhen Vinícius Rodri Foden Saka Rice Alaba Coman Kovac Sommer Ter_Stegen Trapp Füllkrug Undav Can Schlotterbeck Tah Raum Mittelstädt Andrich Wirtz Goretzka Šeško Gyökeres Mount Salah Alisson Ederson Dybala Lautaro Di_María Agüero Higuaín Tevez Riquelme Batistuta Crespo Zanetti Cambiasso".split(" ").map((x) => x.replace("_", " ")),
};
// Beispiele, die abgelehnt werden müssen: [Kategorie, Wort, Buchstabe]
const WRONG = [
    ["Tiere", "Hose", "h"], ["Tiere", "Haus", "h"], ["Tiere", "Tisch", "t"], ["Tiere", "Berlin", "b"], ["Tiere", "Apfel", "a"], ["Tiere", "Auto", "a"],
    ["Länder", "Berlin", "b"], ["Länder", "Paris", "p"], ["Länder", "Hund", "h"], ["Länder", "Iraq", "i"], ["Länder", "Maly", "m"],
    ["Städte", "Deutschland", "d"], ["Städte", "Apfel", "a"], ["Städte", "Hund", "h"],
    ["Obst & Gemüse", "Hund", "h"], ["Obst & Gemüse", "Berlin", "b"], ["Obst & Gemüse", "Tisch", "t"], 
    ["Fußballspieler", "Berlin", "b"], ["Fußballspieler", "Hund", "h"], ["Fußballspieler", "Apfel", "a"], ["Fußballspieler", "Tennis", "t"],
];
try {
    const cats = Object.fromEntries((await q("select id, name from public.word_categories where owner_lobby is null and active")).map((r) => [r.name, r.id]));
    let missingAll = 0;
    for (const [cat, words] of Object.entries(KNOWN)) {
        const id = cats[cat];
        const missing = [];
        for (const w of words) {
            const [{ n }] = await q("select public._ans_norm($1) n", [w]);
            const letter = n[0];
            const [{ m }] = await q("select public._letters_match($1, $2, $3) m", [id, letter, n]);
            if (!m) missing.push(w);
        }
        missingAll += missing.length;
        check(`${cat}: ${words.length - missing.length}/${words.length} bekannte Begriffe erkannt`, missing.length <= Math.ceil(words.length * 0.03), missing.length ? "fehlen: " + missing.join(", ") : "");
    }
    // Vollständige Namen von Fußballern: beim Buchstaben des Vor- UND des Nachnamens
    for (const [full, l1, l2] of [["Lionel Messi", "l", "m"], ["Cristiano Ronaldo", "c", "r"], ["Manuel Neuer", "m", "n"], ["Thomas Müller", "t", "m"]]) {
        const [{ n }] = await q("select public._ans_norm($1) n", [full]);
        const a = (await q("select public._letters_match($1, $2, $3) m", [cats["Fußballspieler"], l1, n]))[0].m;
        const b = (await q("select public._letters_match($1, $2, $3) m", [cats["Fußballspieler"], l2, n]))[0].m;
        check(`„${full}“ zählt bei ${l1.toUpperCase()} und bei ${l2.toUpperCase()}`, !!a && !!b, `${a} / ${b}`);
    }
    // Tippfehler
    const typo = [["Städte", "Hamburk", "h", true], ["Städte", "Berlni", "b", true], ["Städte", "Muenchen", "m", true], ["Länder", "Deutschlnad", "d", true], ["Länder", "Frankreih", "f", true],
        ["Tiere", "Tigre", "t", true], ["Tiere", "Elefnat", "e", true], ["Tiere", "Hund", "h", true], ["Tiere", "Hunt", "h", false], ["Tiere", "Hunde", "h", true], ["Tiere", "Löwen", "l", true], ["Obst & Gemüse", "Bananne", "b", true], ["Städte", "Essen", "e", true], ["Städte", "Esse", "e", false], ["Tiere", "Hose", "h", false], ["Tiere", "Hasen", "h", true]];
    for (const [cat, w, l, expect] of typo) {
        const [{ n }] = await q("select public._ans_norm($1) n", [w]);
        const m = (await q("select public._letters_match($1, $2, $3) m", [cats[cat], l, n]))[0].m;
        check(`Tippfehler „${w}“ (${cat}) ${expect ? "wird verziehen" : "zählt nicht"}`, expect ? !!m : !m, String(m));
    }
    for (const [cat, w, l] of WRONG) {
        const [{ n }] = await q("select public._ans_norm($1) n", [w]);
        const m = (await q("select public._letters_match($1, $2, $3) m", [cats[cat], l, n]))[0].m;
        check(`Falsch: „${w}“ ist kein Begriff in ${cat}`, !m, String(m));
    }
    // Buchstabe muss passen
    const [{ n: bn }] = await q("select public._ans_norm('Berlin') n");
    const wrongLetter = (await q("select public._letters_match($1, 'h', $2) m", [cats["Städte"], bn]))[0].m;
    check("Berlin zählt nicht beim Buchstaben H", !wrongLetter);
    console.log(`\nFehlende Begriffe insgesamt: ${missingAll}`);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
