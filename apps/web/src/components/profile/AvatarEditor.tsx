"use client";

import { useState } from "react";
import { PlayerAvatar, AVATAR_OPTIONS, type AvatarConfig } from "@/components/game/PlayerAvatar";
import { getSupabaseClient } from "@/lib/supabaseClient";

/**
 * Eigene Spielfigur einstellen (Profil, Migration 102). Die Figur erscheint danach am Tisch, in der Lobby,
 * in den Ergebnissen und bei Freunden. Ohne eigene Wahl wird sie aus dem Namen erzeugt.
 */
export function AvatarEditor({ name, initial, onSaved }: { name: string; initial: AvatarConfig | null; onSaved: () => void }) {
    const [cfg, setCfg] = useState<AvatarConfig>(initial ?? {});
    const [busy, setBusy] = useState(false);
    const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
    const dirty = JSON.stringify(cfg) !== JSON.stringify(initial ?? {});

    const randomize = () => {
        const next: AvatarConfig = {};
        for (const o of AVATAR_OPTIONS) next[o.key] = o.values[Math.floor(Math.random() * o.values.length)]!.v;
        setCfg(next);
        setMsg(null);
    };

    const save = async () => {
        setBusy(true);
        const { error } = await getSupabaseClient().rpc("update_my_avatar", { p_config: Object.keys(cfg).length ? cfg : null });
        setBusy(false);
        if (error) return setMsg({ ok: false, text: "Speichern hat nicht geklappt. Bitte nochmal." });
        setMsg({ ok: true, text: "✅ Gespeichert – so siehst du jetzt im Spiel aus." });
        onSaved();
    };

    return (
        <section className="avEd" aria-label="Deine Spielfigur">
            <div className="avEdPreview">
                <PlayerAvatar seed={name} config={cfg} size={150} className="avEdImg" />
                <div className="avEdMoods" aria-hidden>
                    <PlayerAvatar seed={name} config={cfg} mood="panic" size={56} />
                    <PlayerAvatar seed={name} config={cfg} mood="out" size={56} />
                </div>
            </div>
            <div className="avEdBody">
                <h2 className="avEdTitle">🧑 Deine Spielfigur</h2>
                <p className="avEdSub">So sitzt du am Tisch, in der Lobby und in den Ergebnissen.</p>
                <div className="avEdGrid">
                    {AVATAR_OPTIONS.map((o) => (
                        <label key={o.key} className="avEdField">
                            <span>{o.label}</span>
                            {o.values[0]?.color ? (
                                <div className="avEdSwatches" role="radiogroup" aria-label={o.label}>
                                    {o.values.map((v) => (
                                        <button
                                            key={v.v}
                                            type="button"
                                            role="radio"
                                            aria-checked={cfg[o.key] === v.v}
                                            className={`avEdSwatch ${cfg[o.key] === v.v ? "on" : ""}`}
                                            style={{ background: v.color }}
                                            title={v.label}
                                            onClick={() => {
                                                setCfg((c) => ({ ...c, [o.key]: v.v }));
                                                setMsg(null);
                                            }}
                                        />
                                    ))}
                                </div>
                            ) : (
                                <select
                                    className="input avEdSelect"
                                    value={cfg[o.key] ?? ""}
                                    onChange={(e) => {
                                        const val = e.target.value;
                                        setCfg((c) => {
                                            const n = { ...c };
                                            if (val) n[o.key] = val;
                                            else delete n[o.key];
                                            return n;
                                        });
                                        setMsg(null);
                                    }}
                                >
                                    <option value="">Automatisch</option>
                                    {o.values.map((v) => (
                                        <option key={v.v} value={v.v}>
                                            {v.label}
                                        </option>
                                    ))}
                                </select>
                            )}
                        </label>
                    ))}
                </div>
                <div className="avEdActions">
                    <button type="button" className="btn btnSecondary btnSmall" onClick={randomize}>
                        🎲 Zufällig
                    </button>
                    <button
                        type="button"
                        className="btn btnSecondary btnSmall"
                        onClick={() => {
                            setCfg({});
                            setMsg(null);
                        }}
                        title="Figur wieder aus dem Namen erzeugen"
                    >
                        ↺ Zurücksetzen
                    </button>
                    <button type="button" className="btn btnPrimary btnSmall" onClick={() => void save()} disabled={busy || !dirty}>
                        {busy ? "…" : "Speichern"}
                    </button>
                    {msg ? <span className={`avEdMsg ${msg.ok ? "ok" : "err"}`}>{msg.text}</span> : null}
                </div>
            </div>
            <style>{`
        .avEd{ margin-top: 16px; display: grid; grid-template-columns: auto minmax(0,1fr); gap: 18px; align-items: start; padding: 16px; border-radius: 22px; background: rgba(0,0,0,.18); border: 1px solid rgba(255,255,255,.14); }
        .avEdPreview{ display: grid; justify-items: center; gap: 6px; }
        .avEdImg{ width: 150px; height: 150px; border-radius: 50%; background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.45), rgba(255,178,26,.18) 70%); box-shadow: 0 0 0 4px rgba(255,214,10,.3), 0 12px 30px rgba(0,0,0,.3); }
        .avEdMoods{ display: flex; gap: 6px; }
        .avEdMoods img{ width: 56px; height: 56px; border-radius: 50%; background: rgba(255,255,255,.08); }
        .avEdTitle{ margin: 0; font-size: 20px; }
        .avEdSub{ margin: 2px 0 10px; font-size: 13px; opacity: .78; }
        .avEdGrid{ display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
        .avEdField{ display: grid; gap: 4px; font-size: 12px; font-weight: 800; letter-spacing: .4px; text-transform: uppercase; opacity: .95; }
        .avEdSelect{ height: 40px; padding: 0 10px; font-size: 14px; text-transform: none; letter-spacing: 0; font-weight: 700; }
        .avEdSwatches{ display: flex; flex-wrap: wrap; gap: 6px; }
        .avEdSwatch{ width: 26px; height: 26px; border-radius: 50%; border: 2px solid rgba(255,255,255,.35); cursor: pointer; padding: 0; }
        .avEdSwatch.on{ border-color: #ffd23f; box-shadow: 0 0 0 3px rgba(255,210,63,.45); transform: scale(1.1); }
        .avEdActions{ display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
        .avEdMsg{ font-size: 13px; font-weight: 800; }
        .avEdMsg.ok{ color: #a7f3d0; } .avEdMsg.err{ color: #fca5a5; }
        @media (max-width: 600px){ .avEd{ grid-template-columns: 1fr; } .avEdGrid{ grid-template-columns: 1fr 1fr; } }
      `}</style>
        </section>
    );
}
