/**
 * Musik-Genres = normale topic_pool-Kategorien (Migration 025/026), die
 * beim Runden-Thema als Spotify-Playlist eingebettet werden. Jede ID ist
 * eine echte, öffentliche Playlist -- per oEmbed verifiziert
 * (curl https://open.spotify.com/oembed?url=...), kein API-Key nötig.
 *
 * Reihenfolge hier = Reihenfolge im Host-/Settings-UI.
 */
export const MUSIC_PLAYLISTS: Record<string, { title: string; id: string; icon: string }> = {
    // Migration 079: aktuelle Deutschrap-Hits der letzten 4 Jahre (Deezer-Beliebtheit + iTunes-Vorschau,
    // gebaut mit db/scripts/build-deutschrap.mjs aus db/scripts/data/deutschrap-rapper.json)
    "Deutschrap aktuell": {
        title: "Deutschrap aktuell",
        id: "",
        icon: "🔥",
    },
    "Deutschrap-Songs": {
        title: "German Hip Hop Mix",
        id: "37i9dQZF1EIhtg5PfzSFt2",
        icon: "🇩🇪",
    },
    "2000er Old School": {
        title: "2000s Hip Hop R&B",
        id: "5pk7cWIp56YkrwyWU7eMTr",
        icon: "📼",
    },
    "Shisha Club": {
        title: "Shisha Club",
        id: "37i9dQZF1DX2lUf1uE6Mre",
        icon: "💨",
    },
    // Playlists 4-6 (Migration 067): Songs liegen in song_pool (iTunes-Previews),
    // die Spotify-ID ist rein informativ.
    "80er Hits": {
        title: "All Out 80s",
        id: "37i9dQZF1DX4UtSsGT1Sbe",
        icon: "🕺",
    },
    "Deutsch-Pop": {
        title: "Deutsch-Pop Hits",
        id: "",
        icon: "🎤",
    },
    "Rock-Klassiker": {
        title: "Rock Classics",
        id: "37i9dQZF1DWXRqgorJj26U",
        icon: "🎸",
    },
};

export const MUSIC_GENRE_KEYS = Object.keys(MUSIC_PLAYLISTS);

/** Akzentfarbe je Playlist (Abstimmung, Countdown). Unbekannte Playlists bekommen Sonnengelb. */
const PLAYLIST_COLORS: Record<string, string> = {
    "Deutschrap aktuell": "#ef4444",
    "Deutschrap-Songs": "#f59e0b",
    "2000er Old School": "#8b5cf6",
    "Shisha Club": "#06b6d4",
    "80er Hits": "#ec4899",
    "Deutsch-Pop": "#22c55e",
    "Rock-Klassiker": "#3b82f6",
};

export function playlistLook(name: string | null | undefined): { icon: string; color: string } {
    const n = name ?? "";
    return { icon: MUSIC_PLAYLISTS[n]?.icon ?? "🎵", color: PLAYLIST_COLORS[n] ?? "#ffd23f" };
}
