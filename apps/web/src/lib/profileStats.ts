/** Antwort von public.get_my_profile_stats (Migration 076). */
export type ProfileStats = {
    totals: { matches: number; matchWins: number; rounds: number; roundWins: number; practiceMatches: number };
    music: {
        titles: number;
        artists: number;
        wrong: number;
        avgAnswerMs: number | null;
        fastestTitleMs: number | null;
        bestCombo: number;
    };
    playlists: { playlist: string; rounds: number; titles: number; artists: number; wrong: number; wins: number }[];
    recent: {
        finished_at: string;
        rounds_total: number;
        place: number;
        players_count: number;
        humans_count: number;
        bots_count: number;
        total_points: number;
        round_wins: number;
        playlists: string[] | null;
        title_hits: number;
        artist_hits: number;
        wrong_guesses: number;
        ranked: boolean;
    }[];
    opponents: { username: string; matches: number; wins: number; losses: number }[];
    recap: {
        season: string;
        rank: number | null;
        seasonPoints: number | null;
        matches: number;
        matchWins: number;
        rounds: number;
        titles: number;
        artists: number;
        wrong: number;
        bestRoundPoints: number | null;
        fastestTitleMs: number | null;
        favoritePlaylist: string | null;
        bestPlaylist: string | null;
    };
};

/** Anteil richtiger Antworten an allen Antwortversuchen (Titel + Interpret + falsch), in Prozent. */
export function hitRate(titles: number, artists: number, wrong: number): number | null {
    const all = titles + artists + wrong;
    return all > 0 ? Math.round(((titles + artists) / all) * 100) : null;
}

/** Anteil voller Titel-Treffer an allen Versuchen – Maß für "kenne ich wirklich". */
export function titleRate(titles: number, artists: number, wrong: number): number | null {
    const all = titles + artists + wrong;
    return all > 0 ? Math.round((titles / all) * 100) : null;
}

export function fmtSeconds(ms: number | null | undefined): string {
    if (ms == null) return "–";
    return `${(ms / 1000).toFixed(1).replace(".", ",")} s`;
}

const MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];

/** "2026-10" -> "Oktober 2026" */
export function seasonLabel(season: string): string {
    const [y, m] = season.split("-").map(Number);
    return m >= 1 && m <= 12 ? `${MONTHS[m - 1]} ${y}` : season;
}

export function seasonKey(offsetMonths = 0): string {
    const d = new Date();
    d.setDate(1);
    d.setMonth(d.getMonth() + offsetMonths);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

/** Stärkste Playlist (höchster Titel-Anteil, mind. 5 Antwortversuche). */
export function strongestPlaylist(rows: ProfileStats["playlists"]): string | null {
    let best: { name: string; rate: number } | null = null;
    for (const r of rows) {
        if (r.titles + r.artists + r.wrong < 5) continue;
        const rate = titleRate(r.titles, r.artists, r.wrong) ?? 0;
        if (!best || rate > best.rate) best = { name: r.playlist, rate };
    }
    return best?.name ?? null;
}
