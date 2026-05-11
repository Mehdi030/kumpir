/**
 * Antwort-Pool pro Kategorie für Bot-Spieler im Practice-Mode.
 * Key = topic_pool.text (case-insensitive lookup).
 * Bots picken zufällig aus der Liste — Doppelnennungen werden vom Server abgefangen.
 *
 * Wenn keine Kategorie matcht, fällt der Bot auf BOT_FALLBACK zurück
 * (was wahrscheinlich abgelehnt wird — simuliert „leicht" Schwierigkeit).
 */

export const BOT_FALLBACK = ["Keine Ahnung", "Pizza", "Auto", "Wasser", "Hund", "Mama", "Drei"];

const ANSWERS: Record<string, string[]> = {
    "Automarken":             ["BMW", "Audi", "Mercedes", "VW", "Porsche", "Ferrari", "Toyota", "Ford", "Opel", "Honda", "Tesla", "Mazda"],
    "Tiere in Afrika":        ["Löwe", "Elefant", "Giraffe", "Zebra", "Nashorn", "Gepard", "Hyäne", "Flusspferd", "Krokodil", "Affe", "Strauß", "Antilope"],
    "Haustiere":              ["Hund", "Katze", "Hamster", "Meerschweinchen", "Kaninchen", "Wellensittich", "Goldfisch", "Schildkröte", "Papagei"],
    "Fußball-Vereine":        ["Bayern München", "Dortmund", "Schalke", "Real Madrid", "Barcelona", "Manchester United", "Liverpool", "Arsenal", "PSG", "Juventus", "Inter", "Köln"],
    "Länder in Europa":       ["Deutschland", "Frankreich", "Italien", "Spanien", "Portugal", "Österreich", "Schweiz", "Polen", "Niederlande", "Belgien", "Schweden", "Norwegen"],
    "Hauptstädte":            ["Berlin", "Paris", "Madrid", "Rom", "Wien", "Bern", "Warschau", "Amsterdam", "Brüssel", "Stockholm", "Oslo", "London"],
    "Obst":                   ["Apfel", "Birne", "Banane", "Orange", "Erdbeere", "Kirsche", "Pfirsich", "Mango", "Ananas", "Traube", "Wassermelone", "Kiwi"],
    "Gemüse":                 ["Karotte", "Tomate", "Gurke", "Salat", "Paprika", "Brokkoli", "Spinat", "Zwiebel", "Kartoffel", "Aubergine", "Zucchini", "Kohl"],
    "Farben":                 ["Rot", "Blau", "Grün", "Gelb", "Schwarz", "Weiß", "Orange", "Lila", "Rosa", "Braun", "Grau", "Türkis"],
    "Filme":                  ["Inception", "Titanic", "Avatar", "Matrix", "Joker", "Gladiator", "Interstellar", "Forrest Gump", "Pulp Fiction", "Sieben"],
    "Serien":                 ["Breaking Bad", "Game of Thrones", "Friends", "Stranger Things", "The Office", "Lost", "Money Heist", "Dark", "Witcher", "Vikings"],
    "Musiker/Bands":          ["Coldplay", "Beatles", "Queen", "Eminem", "Drake", "Adele", "Ed Sheeran", "Rammstein", "Metallica", "AC/DC", "Linkin Park"],
    "Schauspieler":           ["Tom Hanks", "Brad Pitt", "Leonardo DiCaprio", "Will Smith", "Morgan Freeman", "Denzel Washington", "Robert De Niro", "Al Pacino"],
    "Berufe":                 ["Arzt", "Lehrer", "Anwalt", "Ingenieur", "Bäcker", "Koch", "Polizist", "Feuerwehrmann", "Pilot", "Friseur", "Mechaniker"],
    "Körperteile":            ["Knie", "Arm", "Bein", "Hand", "Fuß", "Kopf", "Nase", "Auge", "Ohr", "Mund", "Finger", "Ellenbogen"],
    "Dinge in der Küche":     ["Messer", "Gabel", "Löffel", "Teller", "Topf", "Pfanne", "Herd", "Kühlschrank", "Mikrowelle", "Tasse", "Glas"],
    "Dinge im Supermarkt":    ["Brot", "Milch", "Käse", "Butter", "Joghurt", "Eier", "Reis", "Nudeln", "Mehl", "Zucker", "Salz", "Öl"],
    "Getränke":               ["Cola", "Wasser", "Saft", "Tee", "Kaffee", "Limonade", "Eistee", "Smoothie", "Milch", "Bier", "Wein"],
    "Alkoholische Getränke":  ["Bier", "Wein", "Wodka", "Whisky", "Rum", "Gin", "Tequila", "Sekt", "Schnaps", "Likör", "Cocktail"],
    "Fast Food":              ["Pizza", "Burger", "Pommes", "Döner", "Hotdog", "Sandwich", "Wrap", "Nuggets", "Salat", "Sushi"],
    "Schulfächer":            ["Mathe", "Deutsch", "Englisch", "Geschichte", "Geographie", "Biologie", "Chemie", "Physik", "Sport", "Kunst", "Musik"],
    "Sportarten":             ["Tennis", "Fußball", "Basketball", "Volleyball", "Schwimmen", "Boxen", "Golf", "Schach", "Skifahren", "Surfen", "Klettern"],
    "Musikinstrumente":       ["Gitarre", "Klavier", "Geige", "Trommel", "Flöte", "Saxophon", "Trompete", "Bass", "Cello", "Harmonika"],
    "Bundesländer":           ["Bayern", "Berlin", "Hamburg", "Hessen", "Sachsen", "Thüringen", "Bremen", "Saarland", "Brandenburg", "Schleswig-Holstein", "Niedersachsen"],
    "Deutsche Städte":        ["Hamburg", "München", "Köln", "Frankfurt", "Stuttgart", "Düsseldorf", "Leipzig", "Dortmund", "Essen", "Bremen", "Hannover"],
    "Großstädte weltweit":    ["Tokio", "New York", "London", "Paris", "Istanbul", "Moskau", "Dubai", "Sydney", "Rio", "Kairo", "Bangkok", "Mumbai"],
    "Flüsse":                 ["Rhein", "Elbe", "Donau", "Main", "Mosel", "Nil", "Amazonas", "Mississippi", "Themse", "Seine"],
    "Berge":                  ["Mount Everest", "K2", "Matterhorn", "Zugspitze", "Brocken", "Kilimanjaro", "Mont Blanc", "Eiger", "Watzmann"],
    "Meere und Ozeane":       ["Atlantik", "Pazifik", "Mittelmeer", "Nordsee", "Ostsee", "Indischer Ozean", "Karibik", "Rotes Meer", "Schwarzes Meer"],
    "Comic-Helden":           ["Spider-Man", "Batman", "Superman", "Iron Man", "Hulk", "Thor", "Captain America", "Wonder Woman", "Flash", "Aquaman"],
    "Disney-Filme":           ["Frozen", "Bambi", "Aladdin", "Cars", "Findet Nemo", "Mulan", "Moana", "Tarzan", "Pocahontas", "Encanto"],
    "Videospiele":            ["Mario Kart", "FIFA", "Minecraft", "Fortnite", "Tetris", "Pokemon", "GTA", "Zelda", "Call of Duty", "Witcher"],
    "Fast-Food-Ketten":       ["McDonalds", "Burger King", "KFC", "Subway", "Starbucks", "Pizza Hut", "Domino's", "Vapiano", "Nordsee"],
    "Kleidungsstücke":        ["Hose", "Hemd", "T-Shirt", "Jacke", "Pullover", "Rock", "Kleid", "Socken", "Shorts", "Mantel", "Bluse"],
    "Schuh-Arten":            ["Sneaker", "Stiefel", "Sandalen", "Pumps", "Flip-Flops", "Hausschuhe", "Wanderschuhe", "Ballerinas", "High Heels"],
    "Wetter-Phänomene":       ["Regen", "Schnee", "Hagel", "Nebel", "Sturm", "Gewitter", "Sonnenschein", "Wind", "Tornado", "Eis"],
    "Blumen":                 ["Rose", "Tulpe", "Sonnenblume", "Margerite", "Lilie", "Veilchen", "Nelke", "Hyazinthe", "Orchidee", "Krokus"],
    "Bäume":                  ["Eiche", "Buche", "Birke", "Kiefer", "Tanne", "Linde", "Ahorn", "Kastanie", "Esche", "Ulme"],
    "Fahrzeuge":              ["Bus", "Auto", "Fahrrad", "Motorrad", "LKW", "Zug", "U-Bahn", "Straßenbahn", "Flugzeug", "Boot"],
    "Möbelstücke":            ["Sofa", "Stuhl", "Tisch", "Bett", "Schrank", "Regal", "Kommode", "Sessel", "Hocker", "Lampe"],
    "Elektrogeräte":          ["Toaster", "Mixer", "Wasserkocher", "Föhn", "Staubsauger", "Bügeleisen", "Kaffeemaschine", "Mikrowelle"],
    "Smartphone-Hersteller":  ["Samsung", "Apple", "Huawei", "Xiaomi", "Sony", "LG", "OnePlus", "Google", "Motorola"],
    "Soziale Medien":         ["Instagram", "TikTok", "Facebook", "Twitter", "Snapchat", "YouTube", "LinkedIn", "Pinterest", "Reddit"],
    "Bekannte YouTuber":      ["MrBeast", "PewDiePie", "Gronkh", "Bibi", "Julien Bam", "Rezo", "Knossi", "Trymacs", "Inscope21"],
    "Kleidungsmarken":        ["Nike", "Adidas", "Puma", "H&M", "Zara", "Gucci", "Prada", "Levis", "Tommy Hilfiger", "Hugo Boss"],
    "Elektronik-Marken":      ["Apple", "Samsung", "Sony", "LG", "Bose", "Philips", "Bosch", "Siemens", "Panasonic"],
    "Deutsche Rapper":        ["Capital Bra", "Bushido", "Sido", "Kollegah", "Apache", "RAF Camora", "Kontra K", "Shirin David", "Cro"],
    "Kinderspiele":           ["Verstecken", "Fangen", "Mensch ärgere dich nicht", "UNO", "Memory", "Stadt Land Fluss", "Twister", "Mau Mau"],
    "Brettspiele":            ["Monopoly", "Risiko", "Catan", "Scrabble", "Backgammon", "Dame", "Schach", "Trivial Pursuit", "Cluedo"],
    "Handwerks-Berufe":       ["Tischler", "Schreiner", "Maurer", "Elektriker", "Klempner", "Maler", "Schlosser", "Dachdecker", "Friseur"],
};

const BOT_NAMES = [
    "Bot Anna", "Bot Ben", "Bot Cleo", "Bot Dino",
    "Bot Echo", "Bot Fips", "Bot Gala", "Bot Hugo",
    "Bot Iris", "Bot Jay",
];

let nextBotIdx = 0;
const usedBotNames = new Set<string>();

export function pickBotName(takenNames: Set<string>): string {
    // Round-robin durch BOT_NAMES, skip taken
    for (let i = 0; i < BOT_NAMES.length; i++) {
        const candidate = BOT_NAMES[(nextBotIdx + i) % BOT_NAMES.length]!;
        if (!takenNames.has(candidate) && !usedBotNames.has(candidate)) {
            nextBotIdx = (nextBotIdx + i + 1) % BOT_NAMES.length;
            usedBotNames.add(candidate);
            return candidate;
        }
    }
    // Alle Namen vergeben → mit Suffix
    return `Bot ${Math.floor(Math.random() * 999)}`;
}

export function resetBotNamePool() {
    usedBotNames.clear();
    nextBotIdx = 0;
}

export function getAnswersForTopic(topicLabel: string | null | undefined): string[] {
    if (!topicLabel) return BOT_FALLBACK;
    const key = Object.keys(ANSWERS).find((k) => k.toLowerCase() === topicLabel.toLowerCase());
    if (!key) return BOT_FALLBACK;
    return ANSWERS[key]!;
}

export function pickBotAnswer(topicLabel: string | null, usedAnswers: string[]): string {
    const pool = getAnswersForTopic(topicLabel);
    const usedLower = new Set(usedAnswers.map((a) => a.toLowerCase()));
    const fresh = pool.filter((a) => !usedLower.has(a.toLowerCase()));
    if (fresh.length === 0) {
        // Pool ist „leer" — Bot gibt eine ungültige Antwort ab (wird abgelehnt)
        return BOT_FALLBACK[Math.floor(Math.random() * BOT_FALLBACK.length)]!;
    }
    return fresh[Math.floor(Math.random() * fresh.length)]!;
}
