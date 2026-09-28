/**
 * Musik-Genres = normale topic_pool-Kategorien (Migration 025/026), die
 * beim Runden-Thema als Spotify-Playlist eingebettet werden. Jede ID ist
 * eine echte, öffentliche Playlist -- per oEmbed verifiziert
 * (curl https://open.spotify.com/oembed?url=...), kein API-Key nötig.
 *
 * Reihenfolge hier = Reihenfolge im Host-/Settings-UI.
 */
export const MUSIC_PLAYLISTS: Record<string, { title: string; id: string; icon: string }> = {
    "Deutschrap-Songs": {
        title: "Deutschrap Charts 2026",
        id: "5lJ1Ko6KMm9lTfdcngqNdA",
        icon: "🇩🇪",
    },
    "Deutschrap Klassiker": {
        title: "Deutschrap: Die Klassiker",
        id: "37i9dQZF1DWSzguhfGl55y",
        icon: "🏆",
    },
    "Englische All-Time-Hits": {
        title: "Hit Rewind",
        id: "37i9dQZF1DX0s5kDXi1oC5",
        icon: "🎸",
    },
    "Internationale Pop-Charts": {
        title: "Today's Top Hits",
        id: "37i9dQZF1DXcBWIGoYBM5M",
        icon: "🌍",
    },
};

export const MUSIC_GENRE_KEYS = Object.keys(MUSIC_PLAYLISTS);
