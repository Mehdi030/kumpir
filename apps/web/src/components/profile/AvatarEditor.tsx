"use client";

import { useState } from "react";
import { PlayerAvatar, AVATAR_OPTIONS, GOATEE_OPTION, TOPS_FEMALE, TOPS_HEADWEAR, topValues, type AvatarConfig } from "@/components/game/PlayerAvatar";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { tk, useI18n } from "@/lib/i18n";

type Key = keyof AvatarConfig;
type Opt = { v: string; label: string; color?: string };

/** Drei Reiter statt einer langen Liste (Wunsch Mehdi 2026-10-12: kompakter, alle Möglichkeiten bleiben). */
const TABS: { id: string; icon: string; label: string; keys: Key[] }[] = [
    { id: "head", icon: "🙂", label: tk("Kopf"), keys: ["gender", "skinColor", "eyeColor", "top", "hairColor", "hatColor"] },
    { id: "face", icon: "🕶️", label: tk("Bart & Brille"), keys: ["facialHair", "facialHairColor", "accessories", "accessoriesColor"] },
    { id: "outfit", icon: "👕", label: tk("Outfit"), keys: ["clothing", "clothesColor", "logo"] },
];
/** Diese Felder zeigen jede Wahl als kleine Figur – man sieht sofort, wie es aussieht. */
const VISUAL: Key[] = ["top", "facialHair", "accessories", "clothing"];

/**
 * Eigene Spielfigur einstellen (Profil, Migration 102/103). Die Figur erscheint danach am Tisch, in der Lobby,
 * in den Ergebnissen und bei Freunden. Ohne eigene Wahl wird sie aus dem Namen erzeugt.
 */
export function AvatarEditor({
    name,
    initial,
    onSaved,
    allowGoatee = false,
}: {
    name: string;
    initial: AvatarConfig | null;
    onSaved: () => void;
    /** Ziegenbart ist für Achi reserviert (Migration 103) */
    allowGoatee?: boolean;
}) {
    const { tr } = useI18n();
    const [cfg, setCfg] = useState<AvatarConfig>(initial ?? {});
    const [tab, setTab] = useState(TABS[0]!.id);
    const [busy, setBusy] = useState(false);
    const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
    const dirty = JSON.stringify(cfg) !== JSON.stringify(initial ?? {});

    const valuesFor = (key: Key, base: Opt[]): Opt[] =>
        key === "top" ? topValues(cfg.gender) : key === "facialHair" && allowGoatee ? [...base, GOATEE_OPTION] : base;

    const set = (key: Key, val: string | null) => {
        setCfg((c) => {
            const n = { ...c };
            if (val) n[key] = val;
            else delete n[key];
            // Typ gewechselt: unpassende Frisur und Bart weg
            if (key === "gender" && val === "f") {
                delete n.facialHair;
                delete n.facialHairColor;
                if (n.top && !TOPS_FEMALE.includes(n.top) && !TOPS_HEADWEAR.includes(n.top)) delete n.top;
            }
            if (key === "gender" && val === "m" && n.top && !topValues("m").some((t) => t.v === n.top)) delete n.top;
            return n;
        });
        setMsg(null);
    };

    const randomize = () => {
        const next: AvatarConfig = {};
        const pick = <T,>(a: T[]) => a[Math.floor(Math.random() * a.length)]!;
        next.gender = cfg.gender ?? pick(["m", "f"]);
        for (const o of AVATAR_OPTIONS) {
            if (o.key === "gender") continue;
            const vals = o.key === "top" ? topValues(next.gender) : o.values;
            if (!vals.length || (o.when && !o.when(next))) continue;
            next[o.key] = pick(vals).v;
        }
        if (cfg.facialHair === "goatee") next.facialHair = "goatee";
        setCfg(next);
        setMsg(null);
    };

    const save = async () => {
        setBusy(true);
        const { error } = await getSupabaseClient().rpc("update_my_avatar", { p_config: Object.keys(cfg).length ? cfg : null });
        setBusy(false);
        if (error)
            return setMsg({ ok: false, text: error.message.includes("avatar_reserved") ? tr("Der Ziegenbart ist für Achi reserviert.") : tr("Speichern hat nicht geklappt. Bitte nochmal.") });
        setMsg({ ok: true, text: tr("✅ Gespeichert – so siehst du jetzt im Spiel aus.") });
        onSaved();
    };

    const activeTab = TABS.find((t) => t.id === tab) ?? TABS[0]!;
    const fields = activeTab.keys
        .map((k) => AVATAR_OPTIONS.find((o) => o.key === k))
        .filter((o): o is (typeof AVATAR_OPTIONS)[number] => !!o && (!o.when || o.when(cfg)));

    return (
        <section className="avEd" aria-label={tr("Deine Spielfigur")}>
            <div className="avEdPreview">
                <PlayerAvatar seed={name} config={cfg} size={124} className="avEdImg" />
                <div className="avEdMoods" aria-hidden>
                    <PlayerAvatar seed={name} config={cfg} mood="panic" size={40} />
                    <PlayerAvatar seed={name} config={cfg} mood="out" size={40} />
                </div>
            </div>

            <div className="avEdBody">
                <div className="avEdTop">
                    <h2 className="avEdTitle">{tr("Deine Spielfigur")}</h2>
                    <div className="avEdTabs" role="tablist" aria-label={tr("Bereiche")}>
                        {TABS.map((t) => (
                            <button key={t.id} type="button" role="tab" aria-selected={tab === t.id} className={`avEdTab ${tab === t.id ? "on" : ""}`} onClick={() => setTab(t.id)}>
                                <span aria-hidden>{t.icon}</span> {tr(t.label)}
                            </button>
                        ))}
                    </div>
                </div>

                <div className="avEdPanel" key={tab} role="tabpanel">
                    {fields.map((o) => {
                        const values = valuesFor(o.key, o.values);
                        const cur = cfg[o.key];
                        const isColor = !!values[0]?.color;
                        const visual = VISUAL.includes(o.key);
                        return (
                            <div key={o.key} className="avEdField">
                                <span className="avEdLabel">{tr(o.label)}</span>
                                <div className={`avEdChoices ${visual ? "thumbs" : isColor ? "swatches" : "pills"}`} role="radiogroup" aria-label={tr(o.label)}>
                                    {o.key !== "gender" ? (
                                        <button
                                            type="button"
                                            role="radio"
                                            aria-checked={!cur}
                                            className={`avEdAuto ${!cur ? "on" : ""}`}
                                            title={tr("Automatisch (aus dem Namen)")}
                                            onClick={() => set(o.key, null)}
                                        >
                                            {isColor ? "" : tr("Auto")}
                                        </button>
                                    ) : null}
                                    {values.map((v) =>
                                        visual ? (
                                            <button
                                                key={v.v}
                                                type="button"
                                                role="radio"
                                                aria-checked={cur === v.v}
                                                className={`avEdThumb ${cur === v.v ? "on" : ""}`}
                                                title={tr(v.label)}
                                                onClick={() => set(o.key, v.v)}
                                            >
                                                <PlayerAvatar seed={name} config={{ ...cfg, [o.key]: v.v }} size={46} />
                                            </button>
                                        ) : isColor ? (
                                            <button
                                                key={v.v}
                                                type="button"
                                                role="radio"
                                                aria-checked={cur === v.v}
                                                className={`avEdSwatch ${cur === v.v ? "on" : ""}`}
                                                style={{ background: v.color }}
                                                title={tr(v.label)}
                                                onClick={() => set(o.key, v.v)}
                                            />
                                        ) : (
                                            <button
                                                key={v.v}
                                                type="button"
                                                role="radio"
                                                aria-checked={cur === v.v}
                                                className={`avEdPill ${cur === v.v ? "on" : ""}`}
                                                onClick={() => set(o.key, v.v)}
                                            >
                                                {tr(v.label)}
                                            </button>
                                        )
                                    )}
                                </div>
                            </div>
                        );
                    })}
                </div>

                <div className="avEdActions">
                    <button type="button" className="btn btnSecondary btnSmall" onClick={randomize}>
                        🎲 {tr("Zufällig")}
                    </button>
                    <button
                        type="button"
                        className="btn btnSecondary btnSmall"
                        onClick={() => {
                            setCfg({});
                            setMsg(null);
                        }}
                        title={tr("Figur wieder aus dem Namen erzeugen")}
                    >
                        ↺ {tr("Zurücksetzen")}
                    </button>
                    <button type="button" className="btn btnPrimary btnSmall" onClick={() => void save()} disabled={busy || !dirty}>
                        {busy ? "…" : tr("Speichern")}
                    </button>
                    {msg ? <span className={`avEdMsg ${msg.ok ? "ok" : "err"}`}>{msg.text}</span> : null}
                </div>
            </div>
            <style>{`
        .avEd{ margin-top: 14px; display: grid; grid-template-columns: auto minmax(0,1fr); gap: 16px; align-items: start; padding: 14px; border-radius: 22px; background: rgba(0,0,0,.18); border: 1px solid rgba(255,255,255,.14); }
        .avEdPreview{ display: grid; justify-items: center; gap: 6px; position: sticky; top: 10px; }
        .avEdImg{ width: 124px; height: 124px; border-radius: 50%; background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.45), rgba(255,178,26,.18) 70%); box-shadow: 0 0 0 4px rgba(255,214,10,.3), 0 12px 30px rgba(0,0,0,.3); transition: transform .25s cubic-bezier(.22,1,.36,1); }
        .avEdImg:hover{ transform: scale(1.04) rotate(-2deg); }
        .avEdMoods{ display: flex; gap: 6px; }
        .avEdMoods img{ width: 40px; height: 40px; border-radius: 50%; background: rgba(255,255,255,.08); }
        .avEdTop{ display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; }
        .avEdTitle{ margin: 0; font-size: 19px; }
        .avEdTabs{ display: inline-flex; gap: 4px; padding: 3px; border-radius: 999px; background: rgba(0,0,0,.25); border: 1px solid rgba(255,255,255,.12); }
        .avEdTab{ border: 0; background: transparent; color: #fff; font: inherit; font-size: 13px; font-weight: 800; padding: 6px 12px; border-radius: 999px; cursor: pointer; opacity: .75; transition: background .2s ease, opacity .2s ease; white-space: nowrap; }
        .avEdTab:hover{ opacity: 1; }
        .avEdTab.on{ background: rgba(255,210,63,.95); color: #2b1600; opacity: 1; }
        .avEdPanel{ display: grid; gap: 8px; margin-top: 10px; animation: avTabIn .32s cubic-bezier(.22,1,.36,1); }
        @keyframes avTabIn{ from{ opacity: 0; transform: translateY(6px); } }
        .avEdField{ display: grid; grid-template-columns: 112px minmax(0,1fr); align-items: center; gap: 10px; }
        .avEdLabel{ font-size: 11.5px; font-weight: 800; letter-spacing: .4px; text-transform: uppercase; opacity: .8; line-height: 1.2; }
        .avEdChoices{ display: flex; gap: 6px; min-width: 0; }
        .avEdChoices.swatches, .avEdChoices.pills{ flex-wrap: wrap; }
        .avEdChoices.thumbs{ overflow-x: auto; padding: 2px 2px 6px; scroll-snap-type: x proximity; scrollbar-width: thin; }
        .avEdSwatch{ width: 24px; height: 24px; flex: none; border-radius: 50%; border: 2px solid rgba(255,255,255,.35); cursor: pointer; padding: 0; transition: transform .15s ease; }
        .avEdSwatch:hover{ transform: scale(1.12); }
        .avEdSwatch.on{ border-color: #ffd23f; box-shadow: 0 0 0 3px rgba(255,210,63,.45); transform: scale(1.12); }
        .avEdThumb{ flex: none; width: 52px; height: 52px; padding: 2px; border-radius: 14px; border: 2px solid rgba(255,255,255,.14); background: rgba(255,255,255,.07); cursor: pointer; scroll-snap-align: start; transition: transform .15s ease, border-color .15s ease; }
        .avEdThumb img{ width: 44px; height: 44px; display: block; }
        .avEdThumb:hover{ transform: translateY(-2px); border-color: rgba(255,255,255,.4); }
        .avEdThumb.on{ border-color: #ffd23f; background: rgba(255,210,63,.18); }
        .avEdPill{ border: 1px solid rgba(255,255,255,.22); background: rgba(255,255,255,.07); color: #fff; font: inherit; font-size: 12.5px; font-weight: 800; padding: 5px 11px; border-radius: 999px; cursor: pointer; }
        .avEdPill.on{ background: rgba(255,210,63,.95); border-color: transparent; color: #2b1600; }
        .avEdAuto{ flex: none; border: 1px dashed rgba(255,255,255,.4); background: transparent; color: #fff; font: inherit; font-size: 11.5px; font-weight: 800; padding: 0 10px; border-radius: 999px; cursor: pointer; opacity: .8; min-height: 24px; }
        .avEdChoices.swatches .avEdAuto{ width: 24px; height: 24px; padding: 0; border-radius: 50%; background: repeating-linear-gradient(45deg, rgba(255,255,255,.25) 0 3px, transparent 3px 6px); }
        .avEdChoices.thumbs .avEdAuto{ width: 52px; height: 52px; border-radius: 14px; }
        .avEdAuto.on{ border-style: solid; border-color: #ffd23f; opacity: 1; box-shadow: 0 0 0 2px rgba(255,210,63,.35); }
        .avEdActions{ display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
        .avEdMsg{ font-size: 13px; font-weight: 800; }
        .avEdMsg.ok{ color: #a7f3d0; } .avEdMsg.err{ color: #fca5a5; }
        @media (max-width: 640px){
          .avEd{ grid-template-columns: 1fr; }
          .avEdPreview{ position: static; grid-auto-flow: column; justify-content: center; align-items: end; }
          .avEdImg{ width: 96px; height: 96px; }
          .avEdField{ grid-template-columns: 1fr; gap: 4px; }
          .avEdTabs{ width: 100%; justify-content: space-between; }
          .avEdTab{ flex: 1; padding: 6px 6px; font-size: 12px; }
        }
        @media (prefers-reduced-motion: reduce){ .avEdPanel{ animation: none; } }
      `}</style>
        </section>
    );
}
