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
};

export const MUSIC_GENRE_KEYS = Object.keys(MUSIC_PLAYLISTS);
