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
    "Deutschrap aktuell": { title: "Deutschrap aktuell", id: "", icon: "🔥" },
    // Migration 121: aus Spotify-Playlists von Mehdi (db/scripts/build-spotify-playlists.mjs, Hörproben von Spotify)
    "Top 50 Deutschrap": { title: "Top 50 Deutschrap 2026", id: "36BS72kjzt0c8BIkwOvQUB", icon: "🏆" },
    "Deutschrap Asphalt": { title: "Deutschrap Asphalt", id: "37i9dQZF1DXbWS0mKtnghU", icon: "🇩🇪" },
    Nostalgie: { title: "Alte Deutschrap banger", id: "3EIC2YmoiAYlfyCyV9vtHD", icon: "📼" },
    "ICON 5": { title: "ICON 5", id: "4dp1B9ShVkftIC65qV8sne", icon: "🎤" },
};

export const MUSIC_GENRE_KEYS = Object.keys(MUSIC_PLAYLISTS);

/** Akzentfarbe je Playlist (Abstimmung, Countdown). Unbekannte Playlists bekommen Sonnengelb. */
const PLAYLIST_COLORS: Record<string, string> = {
    "Deutschrap aktuell": "#ef4444",
    "Top 50 Deutschrap": "#f59e0b",
    "Deutschrap Asphalt": "#06b6d4",
    Nostalgie: "#8b5cf6",
    "ICON 5": "#ec4899",
};

export function playlistLook(name: string | null | undefined): { icon: string; color: string } {
    const n = name ?? "";
    return { icon: MUSIC_PLAYLISTS[n]?.icon ?? "🎵", color: PLAYLIST_COLORS[n] ?? "#ffd23f" };
}
