"use client";

import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { MUSIC_GENRE_KEYS, MUSIC_PLAYLISTS } from "@/lib/musicGenres";

export type PlaylistInfo = { name: string; songs: number };

let cache: Promise<PlaylistInfo[]> | null = null;

/** Alle Musik-Playlists mit Songanzahl (einmal pro Seite geladen). */
export function loadPlaylists(): Promise<PlaylistInfo[]> {
    if (!cache) {
        cache = (async () => {
            const { data, error } = await getSupabaseClient().rpc("get_song_playlists");
            if (error || !Array.isArray(data)) {
                cache = null;
                return MUSIC_GENRE_KEYS.map((name) => ({ name, songs: 0 }));
            }
            const list = data as PlaylistInfo[];
            // Reihenfolge wie in lib/musicGenres.ts, unbekannte (neue) hinten
            const order = (n: string) => {
                const i = MUSIC_GENRE_KEYS.indexOf(n);
                return i < 0 ? 999 : i;
            };
            return [...list].sort((a, b) => order(a.name) - order(b.name) || a.name.localeCompare(b.name));
        })();
    }
    return cache;
}

export function usePlaylists(): PlaylistInfo[] | null {
    const [list, setList] = useState<PlaylistInfo[] | null>(null);
    useEffect(() => {
        let alive = true;
        void loadPlaylists().then((l) => {
            if (alive) setList(l);
        });
        return () => {
            alive = false;
        };
    }, []);
    return list;
}

type Props = {
    /** Ausgewählte Playlists (Namen). */
    selected: string[];
    onChange: (next: string[]) => void;
    disabled?: boolean;
};

/**
 * Playlist-Auswahl: Standard = alle an. Antippen nimmt eine Playlist raus bzw. wieder rein,
 * mindestens eine bleibt immer drin.
 */
export function PlaylistPicker({ selected, onChange, disabled = false }: Props) {
    const list = usePlaylists();
    const [hint, setHint] = useState("");
    if (!list) return <div className="fieldHelp">Lade Playlists…</div>;

    const allNames = list.map((p) => p.name);
    const sel = selected.filter((n) => allNames.includes(n));
    const songs = list.filter((p) => sel.includes(p.name)).reduce((n, p) => n + p.songs, 0);

    const toggle = (name: string) => {
        if (sel.includes(name)) {
            if (sel.length <= 1) {
                setHint("Mindestens eine Playlist muss drin bleiben.");
                window.setTimeout(() => setHint(""), 2200);
                return;
            }
            onChange(sel.filter((n) => n !== name));
        } else {
            onChange([...sel, name]);
        }
    };

    return (
        <div className="plPick">
            <div className="plChips" role="group" aria-label="Playlists">
                {list.map((p) => {
                    const on = sel.includes(p.name);
                    return (
                        <button
                            key={p.name}
                            type="button"
                            className={`plChip ${on ? "on" : ""}`}
                            aria-pressed={on}
                            onClick={() => toggle(p.name)}
                            disabled={disabled}
                            title={on ? "Antippen zum Rausnehmen" : "Antippen zum Hinzufügen"}
                        >
                            <span aria-hidden>{MUSIC_PLAYLISTS[p.name]?.icon ?? "🎵"}</span>
                            <span className="plName">{p.name}</span>
                            {p.songs ? <span className="plCount">{p.songs}</span> : null}
                        </button>
                    );
                })}
            </div>
            <div className="plFoot">
                <span>
                    {sel.length === allNames.length ? "Alle Playlists" : `${sel.length} von ${allNames.length} Playlists`}
                    {songs ? ` · ${songs} Songs` : ""}
                </span>
                {sel.length !== allNames.length ? (
                    <button type="button" className="plAll" onClick={() => onChange(allNames)} disabled={disabled}>
                        Alle wieder rein
                    </button>
                ) : null}
            </div>
            {hint ? (
                <div className="fieldHelp fieldHelpError" role="status">
                    {hint}
                </div>
            ) : null}
            <style>{`
        .plPick{ display:grid; gap:8px; }
        .plChips{ display:flex; flex-wrap:wrap; gap:8px; }
        .plChip{ display:inline-flex; align-items:center; gap:6px; border-radius:999px; padding:7px 12px; font-weight:800; font-size:13px; cursor:pointer;
          border:1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.05); color: rgba(255,255,255,.55); text-decoration: line-through; transition: background .15s ease; }
        .plChip.on{ background: rgba(255,210,63,.2); border-color: rgba(255,210,63,.75); color:#fff; text-decoration:none; }
        .plChip:disabled{ opacity:.6; cursor:default; }
        .plCount{ font-size:11px; font-weight:800; padding:1px 7px; border-radius:999px; background: rgba(0,0,0,.25); }
        .plFoot{ display:flex; gap:10px; align-items:center; flex-wrap:wrap; font-size:12px; opacity:.85; }
        .plAll{ border:0; background:none; color:#fff; font-weight:800; text-decoration:underline; text-underline-offset:3px; cursor:pointer; font-size:12px; }
      `}</style>
        </div>
    );
}

/** Ausgewählte Playlists aus "rausgenommenen" (Vorlieben) berechnen; leer -> alle. */
export function selectedFromExcluded(all: string[], excluded: string[] | undefined): string[] {
    const sel = all.filter((n) => !(excluded ?? []).includes(n));
    return sel.length ? sel : all;
}
