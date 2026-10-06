"use client";

import { useEffect, useRef, useState } from "react";
import type { Profile } from "@/components/ProfileProvider";
import { PasswordInput } from "@/components/PasswordInput";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useI18n } from "@/lib/i18n";
import { getMuted, getVolume, setMuted, setVolume } from "@/lib/gameFx";
import {
    AVATAR_COLORS,
    AVATAR_EMOJIS,
    DEFAULT_AVATAR,
    SOLO_SKILL_LABEL,
    sanitizeDisplayName,
    settingsErrorText,
    validateDisplayName,
    validateUsername,
    type Preferences,
} from "@/lib/accountSettings";

/** Alles, was die Einstellungen am Server ändern – austauschbar für Tests/Vorschau. */
export type AccountApi = {
    setUsername: (u: string) => Promise<{ error?: string }>;
    updateProfile: (displayName: string | null, emoji: string | null, color: string | null) => Promise<{ error?: string }>;
    isUsernameAvailable: (u: string) => Promise<boolean | null>;
    changeEmail: (email: string) => Promise<{ error?: string }>;
    changePassword: (pw: string) => Promise<{ error?: string }>;
    deleteAccount: () => Promise<{ error?: string }>;
    logout: () => Promise<void>;
};

export function supabaseAccountApi(): AccountApi {
    const sb = getSupabaseClient();
    return {
        async setUsername(u) {
            const { error } = await sb.rpc("set_my_username", { p_username: u });
            return { error: error?.message };
        },
        async updateProfile(displayName, emoji, color) {
            const { error } = await sb.rpc("update_my_profile", { p_display_name: displayName, p_avatar_emoji: emoji, p_avatar_color: color });
            return { error: error?.message };
        },
        async isUsernameAvailable(u) {
            const { data, error } = await sb.rpc("is_username_available", { p_username: u });
            return error ? null : !!data;
        },
        async changeEmail(email) {
            const { error } = await sb.auth.updateUser({ email }, { emailRedirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent("/profile")}` });
            return { error: error?.message };
        },
        async changePassword(pw) {
            const { error } = await sb.auth.updateUser({ password: pw });
            return { error: error?.message };
        },
        async deleteAccount() {
            const { error } = await sb.rpc("delete_my_account");
            if (!error) await sb.auth.signOut();
            return { error: error?.message };
        },
        async logout() {
            await sb.auth.signOut();
        },
    };
}

type Props = {
    profile: Profile;
    api: AccountApi;
    onRefresh: () => Promise<void>;
    onSavePreferences: (p: Preferences) => Promise<{ ok: boolean; error?: string }>;
};

type Tab = "profil" | "spiel" | "konto";
type Msg = { ok: boolean; text: string } | null;

/** Avatar-Kreis: Emoji auf Farbe, sonst Anfangsbuchstabe. */
export function AvatarBadge({ emoji, color, name, size = 68 }: { emoji?: string | null; color?: string | null; name: string; size?: number }) {
    return (
        <div
            className="avBadge"
            aria-hidden
            style={{ width: size, height: size, fontSize: size * 0.46, background: color || DEFAULT_AVATAR.color }}
        >
            {emoji || name.slice(0, 1).toUpperCase()}
            <style>{`.avBadge{ border-radius:50%; display:grid; place-items:center; font-weight:800; color:#2b0f04; box-shadow: 0 0 0 4px rgba(255,255,255,.2), 0 10px 24px rgba(0,0,0,.3); flex:none; font-family: var(--font-display); line-height:1; }`}</style>
        </div>
    );
}

function Note({ msg }: { msg: Msg }) {
    if (!msg) return null;
    return (
        <div className={`fieldHelp ${msg.ok ? "setOk" : "fieldHelpError"}`} role={msg.ok ? "status" : "alert"}>
            {msg.text}
        </div>
    );
}

export function AccountSettings({ profile, api, onRefresh, onSavePreferences }: Props) {
    const [tab, setTab] = useState<Tab>("profil");

    return (
        <section className="setBox" aria-labelledby="setTitle">
            <div className="setHead">
                <h2 id="setTitle" className="setH2">
                    ⚙️ Einstellungen
                </h2>
                <div className="setTabs" role="tablist" aria-label="Einstellungen">
                    {(
                        [
                            ["profil", "👤 Profil"],
                            ["spiel", "🎮 Spiel"],
                            ["konto", "🔐 Konto"],
                        ] as [Tab, string][]
                    ).map(([key, label]) => (
                        <button key={key} type="button" role="tab" aria-selected={tab === key} className={tab === key ? "on" : ""} onClick={() => setTab(key)}>
                            {label}
                        </button>
                    ))}
                </div>
            </div>

            {!profile.username ? (
                <div className="setWarn">⚠️ Dein Konto hat noch keinen Benutzernamen. Wähle unten einen – damit kannst du dich auch ohne E-Mail anmelden.</div>
            ) : null}

            {tab === "profil" ? <ProfileTab profile={profile} api={api} onRefresh={onRefresh} /> : null}
            {tab === "spiel" ? <GameTab profile={profile} onSavePreferences={onSavePreferences} /> : null}
            {tab === "konto" ? <AccountTab profile={profile} api={api} /> : null}

            <style>{`
        .setBox{ margin-top:18px; padding:16px; border-radius:18px; background: rgba(0,0,0,.18); border:1px solid rgba(255,255,255,.12); display:grid; gap:14px; }
        .setHead{ display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap; }
        .setH2{ margin:0; font-size:18px; }
        .setTabs{ display:inline-flex; border-radius:999px; border:1px solid rgba(255,255,255,.28); overflow:hidden; }
        .setTabs button{ border:0; background:transparent; color:#fff; font-weight:700; font-size:13px; padding:7px 12px; cursor:pointer; }
        .setTabs button.on{ background: rgba(255,255,255,.9); color:#2b0f04; }
        .setWarn{ padding:10px 12px; border-radius:12px; background: rgba(255,210,63,.16); border:1px solid rgba(255,210,63,.4); font-size:14px; font-weight:600; }
        .setGroup{ display:grid; gap:10px; padding:14px; border-radius:16px; background: rgba(255,255,255,.06); border:1px solid rgba(255,255,255,.1); }
        .setGroup h3{ margin:0; font-size:15px; }
        .setHint{ font-size:12px; opacity:.78; line-height:1.4; }
        .setRow{ display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
        .setRow .input{ flex:1 1 200px; min-width:0; }
        .setOk{ color:#8df0a6 !important; }
        .setEmojis{ display:grid; grid-template-columns: repeat(auto-fill, minmax(42px, 1fr)); gap:6px; }
        .setEmojis button{ height:42px; border-radius:12px; border:2px solid transparent; background: rgba(255,255,255,.08); font-size:22px; cursor:pointer; }
        .setEmojis button.on{ border-color:#ffd23f; background: rgba(255,210,63,.18); }
        .setColors{ display:flex; gap:8px; flex-wrap:wrap; }
        .setColors button{ width:32px; height:32px; border-radius:50%; border:3px solid rgba(255,255,255,.25); cursor:pointer; }
        .setColors button.on{ border-color:#fff; box-shadow: 0 0 0 2px #2b0f04; }
        .setSeg{ display:inline-flex; flex-wrap:wrap; gap:6px; }
        .setSeg button{ border:1px solid rgba(255,255,255,.25); background: rgba(255,255,255,.06); color:#fff; border-radius:999px; padding:6px 12px; font-weight:700; font-size:13px; cursor:pointer; }
        .setSeg button.on{ background:#ffd23f; color:#2b0f04; border-color:#ffd23f; }
        .setStep{ display:inline-flex; align-items:center; gap:8px; font-weight:800; }
        .setStep button{ width:34px; height:34px; border-radius:50%; border:1px solid rgba(255,255,255,.3); background: rgba(255,255,255,.08); color:#fff; font-size:18px; cursor:pointer; }
        .setLabel{ font-size:13px; font-weight:700; min-width:120px; }
        .setDanger{ border-color: rgba(248,113,113,.5); background: rgba(248,113,113,.08); }
        .btnDanger{ background:#e63946 !important; color:#fff !important; border-color:#e63946 !important; }
      `}</style>
        </section>
    );
}

// ------------------------------------------------------------------ Profil
function ProfileTab({ profile, api, onRefresh }: { profile: Profile; api: AccountApi; onRefresh: () => Promise<void> }) {
    const [displayName, setDisplayName] = useState(profile.displayName ?? "");
    const [emoji, setEmoji] = useState(profile.avatarEmoji ?? "");
    const [color, setColor] = useState(profile.avatarColor ?? DEFAULT_AVATAR.color);
    const [msg, setMsg] = useState<Msg>(null);
    const [busy, setBusy] = useState(false);

    const [username, setUsername] = useState(profile.username ?? "");
    const [uStatus, setUStatus] = useState<"idle" | "checking" | "free" | "taken" | "error">("idle");
    const [uMsg, setUMsg] = useState<Msg>(null);
    const [uBusy, setUBusy] = useState(false);
    const checkSeq = useRef(0);

    const uCheck = validateUsername(username);
    const uChanged = uCheck.ok && uCheck.value !== (profile.username ?? "");

    // Verfügbarkeit prüfen, kurz nachdem man aufhört zu tippen
    useEffect(() => {
        if (!uChanged || !uCheck.ok) return;
        const seq = ++checkSeq.current;
        const value = uCheck.value;
        const t = window.setTimeout(async () => {
            setUStatus("checking");
            const free = await api.isUsernameAvailable(value);
            if (seq !== checkSeq.current) return;
            setUStatus(free == null ? "error" : free ? "free" : "taken");
        }, 400);
        return () => window.clearTimeout(t);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [username]);

    const saveProfile = async () => {
        const v = validateDisplayName(displayName);
        if (!v.ok) return setMsg({ ok: false, text: v.message });
        setBusy(true);
        setMsg(null);
        const res = await api.updateProfile(v.value, emoji || null, color || null);
        setBusy(false);
        if (res.error) return setMsg({ ok: false, text: settingsErrorText(res.error) });
        await onRefresh();
        setMsg({ ok: true, text: "✅ Gespeichert" });
    };

    const saveUsername = async () => {
        if (!uCheck.ok) return setUMsg({ ok: false, text: uCheck.message });
        if (uStatus === "taken") return setUMsg({ ok: false, text: "Dieser Benutzername ist schon vergeben." });
        setUBusy(true);
        setUMsg(null);
        const res = await api.setUsername(uCheck.value);
        setUBusy(false);
        if (res.error) return setUMsg({ ok: false, text: settingsErrorText(res.error) });
        await onRefresh();
        setUStatus("idle");
        setUMsg({ ok: true, text: `✅ Benutzername geändert. Anmelden geht jetzt mit „${uCheck.value}“.` });
    };

    const previewName = displayName || profile.username || "?";

    return (
        <>
            <div className="setGroup">
                <h3>Avatar & Spielername</h3>
                <div className="setRow" style={{ gap: 14 }}>
                    <AvatarBadge emoji={emoji} color={color} name={previewName} size={64} />
                    <div className="setHint">So sehen dich andere in der Bestenliste und du dich oben in der Kopfzeile.</div>
                </div>
                <div className="setEmojis" role="group" aria-label="Avatar-Symbol">
                    <button type="button" className={!emoji ? "on" : ""} onClick={() => setEmoji("")} aria-pressed={!emoji} title="Anfangsbuchstabe" style={{ fontSize: 16, fontWeight: 800, color: "#fff" }}>
                        Aa
                    </button>
                    {AVATAR_EMOJIS.map((e) => (
                        <button key={e} type="button" className={emoji === e ? "on" : ""} onClick={() => setEmoji(e)} aria-pressed={emoji === e} aria-label={`Avatar ${e}`}>
                            {e}
                        </button>
                    ))}
                </div>
                <div className="setColors" role="group" aria-label="Avatar-Farbe">
                    {AVATAR_COLORS.map((c) => (
                        <button key={c} type="button" className={color === c ? "on" : ""} style={{ background: c }} onClick={() => setColor(c)} aria-pressed={color === c} aria-label={`Farbe ${c}`} />
                    ))}
                </div>
                <label className="setLabel" htmlFor="setDisplayName">
                    Spielername
                </label>
                <div className="setRow">
                    <input
                        id="setDisplayName"
                        className="input"
                        value={displayName}
                        onChange={(e) => setDisplayName(sanitizeDisplayName(e.target.value))}
                        placeholder={profile.username ? `leer = ${profile.username}` : "z. B. Medo"}
                        maxLength={12}
                        autoComplete="nickname"
                    />
                </div>
                <div className="setHint">Wird beim Hosten, Beitreten und im Solo-Modus automatisch eingetragen. 2–12 Buchstaben.</div>
                <div className="setRow">
                    <button type="button" className="btn btnPrimary btnSmall" onClick={() => void saveProfile()} disabled={busy}>
                        {busy ? "…" : "Speichern"}
                    </button>
                    <Note msg={msg} />
                </div>
            </div>

            <div className="setGroup">
                <h3>Benutzername (zum Anmelden)</h3>
                <div className="setRow">
                    <input
                        className="input"
                        value={username}
                        onChange={(e) => {
                            setUsername(e.target.value.toLowerCase().replace(/\s/g, ""));
                            setUStatus("idle");
                            setUMsg(null);
                        }}
                        maxLength={20}
                        autoCapitalize="none"
                        autoCorrect="off"
                        spellCheck={false}
                        aria-label="Benutzername"
                        placeholder="z. B. medo"
                    />
                    <button type="button" className="btn btnSecondary btnSmall" onClick={() => void saveUsername()} disabled={uBusy || !uChanged || uStatus === "taken" || uStatus === "checking"}>
                        {uBusy ? "…" : "Ändern"}
                    </button>
                </div>
                <div className="setHint">
                    {!uCheck.ok && username
                        ? uCheck.message
                        : !uChanged
                          ? "3–20 Zeichen: a–z, 0–9, Punkt, Unterstrich, Minus."
                          : uStatus === "checking"
                            ? "Prüfe…"
                            : uStatus === "free"
                              ? "✅ frei"
                              : uStatus === "taken"
                                ? "❌ schon vergeben"
                                : uStatus === "error"
                                  ? "⚠️ Konnte nicht prüfen"
                                  : ""}
                </div>
                <Note msg={uMsg} />
            </div>
        </>
    );
}

// ------------------------------------------------------------------ Spiel
function GameTab({ profile, onSavePreferences }: { profile: Profile; onSavePreferences: Props["onSavePreferences"] }) {
    const { locale, setLocale } = useI18n();
    const p = profile.preferences;
    const [muted, setMutedState] = useState(() => getMuted());
    const [volume, setVolumeState] = useState(() => Math.round(getVolume() * 100));
    const [bots, setBots] = useState(p.solo?.bots ?? 3);
    const [skill, setSkill] = useState<NonNullable<NonNullable<Preferences["solo"]>["skill"]>>(p.solo?.skill ?? "mixed");
    const [maxPlayers, setMaxPlayers] = useState(p.host?.maxPlayers ?? 8);
    const [speed, setSpeed] = useState<"fast" | "normal" | "calm">(p.host?.speed ?? "normal");
    const [rounds, setRounds] = useState<1 | 3 | 5>(p.host?.rounds ?? 1);
    const [answerMode, setAnswerMode] = useState<"text" | "voice">(p.host?.answerMode ?? "text");
    const [msg, setMsg] = useState<Msg>(null);
    const [busy, setBusy] = useState(false);

    const save = async () => {
        setBusy(true);
        setMsg(null);
        const res = await onSavePreferences({ solo: { bots, skill }, host: { maxPlayers, speed, rounds, answerMode } });
        setBusy(false);
        setMsg(res.ok ? { ok: true, text: "✅ Gespeichert – gilt ab dem nächsten Spiel" } : { ok: false, text: settingsErrorText(res.error) });
    };

    return (
        <>
            <div className="setGroup">
                <h3>Sprache & Ton</h3>
                <div className="setHint">Wird sofort übernommen und gilt auf allen Geräten, auf denen du angemeldet bist.</div>
                <div className="setRow">
                    <span className="setLabel">Sprache</span>
                    <div className="setSeg" role="group" aria-label="Sprache">
                        {(["de", "en"] as const).map((l) => (
                            <button key={l} type="button" className={locale === l ? "on" : ""} aria-pressed={locale === l} onClick={() => setLocale(l)}>
                                {l === "de" ? "Deutsch" : "English"}
                            </button>
                        ))}
                    </div>
                </div>
                <div className="setRow">
                    <span className="setLabel">Ton</span>
                    <div className="setSeg" role="group" aria-label="Ton">
                        <button type="button" className={!muted ? "on" : ""} aria-pressed={!muted} onClick={() => (setMuted(false), setMutedState(false))}>
                            🔊 An
                        </button>
                        <button type="button" className={muted ? "on" : ""} aria-pressed={muted} onClick={() => (setMuted(true), setMutedState(true))}>
                            🔇 Aus
                        </button>
                    </div>
                </div>
                <div className="setRow">
                    <label className="setLabel" htmlFor="setVolume">
                        Lautstärke {volume} %
                    </label>
                    <input
                        id="setVolume"
                        type="range"
                        className="slider"
                        min={0}
                        max={100}
                        step={5}
                        value={volume}
                        onChange={(e) => {
                            const v = Number(e.target.value);
                            setVolumeState(v);
                            setVolume(v / 100);
                        }}
                        style={{ flex: "1 1 160px" }}
                    />
                </div>
            </div>

            <div className="setGroup">
                <h3>🤖 Solo-Gegner</h3>
                <div className="setRow">
                    <span className="setLabel">Anzahl Bots</span>
                    <div className="setStep">
                        <button type="button" onClick={() => setBots((b) => Math.max(1, b - 1))} aria-label="Weniger Bots">
                            −
                        </button>
                        <span aria-live="polite">{bots}</span>
                        <button type="button" onClick={() => setBots((b) => Math.min(5, b + 1))} aria-label="Mehr Bots">
                            +
                        </button>
                    </div>
                </div>
                <div className="setRow">
                    <span className="setLabel">Stärke</span>
                    <div className="setSeg" role="group" aria-label="Bot-Stärke">
                        {(Object.keys(SOLO_SKILL_LABEL) as (keyof typeof SOLO_SKILL_LABEL)[]).map((k) => (
                            <button key={k} type="button" className={skill === k ? "on" : ""} aria-pressed={skill === k} onClick={() => setSkill(k)}>
                                {SOLO_SKILL_LABEL[k]}
                            </button>
                        ))}
                    </div>
                </div>
            </div>

            <div className="setGroup">
                <h3>🚀 Standard beim Hosten</h3>
                <div className="setHint">Diese Werte sind auf „Lobby hosten“ schon vorausgewählt (dort weiterhin änderbar).</div>
                <div className="setRow">
                    <span className="setLabel">Max. Spieler</span>
                    <div className="setStep">
                        <button type="button" onClick={() => setMaxPlayers((n) => Math.max(2, n - 1))} aria-label="Weniger Spieler">
                            −
                        </button>
                        <span aria-live="polite">{maxPlayers}</span>
                        <button type="button" onClick={() => setMaxPlayers((n) => Math.min(12, n + 1))} aria-label="Mehr Spieler">
                            +
                        </button>
                    </div>
                </div>
                <div className="setRow">
                    <span className="setLabel">Tempo</span>
                    <div className="setSeg" role="group" aria-label="Tempo">
                        {(
                            [
                                ["fast", "⚡ Blitz"],
                                ["normal", "🎯 Standard"],
                                ["calm", "🧊 Casual"],
                            ] as const
                        ).map(([k, label]) => (
                            <button key={k} type="button" className={speed === k ? "on" : ""} aria-pressed={speed === k} onClick={() => setSpeed(k)}>
                                {label}
                            </button>
                        ))}
                    </div>
                </div>
                <div className="setRow">
                    <span className="setLabel">Runden pro Match</span>
                    <div className="setSeg" role="group" aria-label="Runden pro Match">
                        {([1, 3, 5] as const).map((r) => (
                            <button key={r} type="button" className={rounds === r ? "on" : ""} aria-pressed={rounds === r} onClick={() => setRounds(r)}>
                                {r} {r === 1 ? "Runde" : "Runden"}
                            </button>
                        ))}
                    </div>
                </div>
                <div className="setRow">
                    <span className="setLabel">Antwort</span>
                    <div className="setSeg" role="group" aria-label="Antwort-Modus">
                        <button type="button" className={answerMode === "text" ? "on" : ""} aria-pressed={answerMode === "text"} onClick={() => setAnswerMode("text")}>
                            ⌨️ Schreiben
                        </button>
                        <button type="button" className={answerMode === "voice" ? "on" : ""} aria-pressed={answerMode === "voice"} onClick={() => setAnswerMode("voice")}>
                            🎤 Mündlich
                        </button>
                    </div>
                </div>
            </div>

            <div className="setRow">
                <button type="button" className="btn btnPrimary btnSmall" onClick={() => void save()} disabled={busy}>
                    {busy ? "…" : "Solo- & Host-Einstellungen speichern"}
                </button>
                <Note msg={msg} />
            </div>
        </>
    );
}

// ------------------------------------------------------------------ Konto
function AccountTab({ profile, api }: { profile: Profile; api: AccountApi }) {
    const [email, setEmail] = useState("");
    const [eMsg, setEMsg] = useState<Msg>(null);
    const [eBusy, setEBusy] = useState(false);
    const [pw, setPw] = useState("");
    const [pw2, setPw2] = useState("");
    const [pMsg, setPMsg] = useState<Msg>(null);
    const [pBusy, setPBusy] = useState(false);
    const [delOpen, setDelOpen] = useState(false);
    const [delText, setDelText] = useState("");
    const [dMsg, setDMsg] = useState<Msg>(null);
    const [dBusy, setDBusy] = useState(false);

    const changeEmail = async () => {
        const e = email.trim().toLowerCase();
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) return setEMsg({ ok: false, text: "Bitte eine gültige E-Mail-Adresse eingeben." });
        if (e === (profile.email ?? "").toLowerCase()) return setEMsg({ ok: false, text: "Das ist schon deine Adresse." });
        setEBusy(true);
        setEMsg(null);
        const res = await api.changeEmail(e);
        setEBusy(false);
        if (res.error) {
            const m = res.error.toLowerCase();
            return setEMsg({
                ok: false,
                text: m.includes("already") ? "Diese E-Mail gehört schon zu einem anderen Konto." : m.includes("rate") || m.includes("seconds") ? "Bitte kurz warten und erneut versuchen." : res.error,
            });
        }
        setEmail("");
        setEMsg({ ok: true, text: `📨 Fast fertig: Bestätige die Änderung über den Link in der Mail an ${e}. Bis dahin gilt die alte Adresse.` });
    };

    const changePassword = async () => {
        if (pw.length < 8) return setPMsg({ ok: false, text: "Das Passwort braucht mindestens 8 Zeichen." });
        if (pw !== pw2) return setPMsg({ ok: false, text: "Die beiden Passwörter sind nicht gleich." });
        setPBusy(true);
        setPMsg(null);
        const res = await api.changePassword(pw);
        setPBusy(false);
        if (res.error) {
            return setPMsg({ ok: false, text: /different from the old|same password/i.test(res.error) ? "Das neue Passwort muss sich vom alten unterscheiden." : res.error });
        }
        setPw("");
        setPw2("");
        setPMsg({ ok: true, text: "✅ Passwort geändert." });
    };

    const deleteAccount = async () => {
        if (delText.trim().toUpperCase() !== "LÖSCHEN") return setDMsg({ ok: false, text: "Bitte zur Bestätigung LÖSCHEN eintippen." });
        setDBusy(true);
        setDMsg(null);
        const res = await api.deleteAccount();
        setDBusy(false);
        if (res.error) return setDMsg({ ok: false, text: settingsErrorText(res.error) });
        window.location.assign("/login?m=account_deleted");
    };

    return (
        <>
            <div className="setGroup">
                <h3>E-Mail-Adresse</h3>
                <div className="setHint">
                    Aktuell: <b>{profile.email}</b> {profile.emailVerified ? "✓ bestätigt" : "(noch nicht bestätigt)"}
                </div>
                <div className="setRow">
                    <input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="neue@adresse.de" autoComplete="email" aria-label="Neue E-Mail-Adresse" />
                    <button type="button" className="btn btnSecondary btnSmall" onClick={() => void changeEmail()} disabled={eBusy || !email}>
                        {eBusy ? "…" : "Ändern"}
                    </button>
                </div>
                <Note msg={eMsg} />
            </div>

            <div className="setGroup">
                <h3>Passwort ändern</h3>
                <PasswordInput value={pw} onChange={(e) => setPw(e.target.value)} placeholder="Neues Passwort (mind. 8 Zeichen)" autoComplete="new-password" aria-label="Neues Passwort" />
                <PasswordInput
                    value={pw2}
                    onChange={(e) => setPw2(e.target.value)}
                    onKeyDown={(e) => {
                        if (e.key === "Enter") void changePassword();
                    }}
                    placeholder="Nochmal eingeben"
                    autoComplete="new-password"
                    aria-label="Neues Passwort wiederholen"
                />
                <div className="setRow">
                    <button type="button" className="btn btnSecondary btnSmall" onClick={() => void changePassword()} disabled={pBusy || !pw}>
                        {pBusy ? "…" : "Passwort speichern"}
                    </button>
                    <Note msg={pMsg} />
                </div>
            </div>

            <div className="setGroup">
                <h3>Abmelden</h3>
                <div className="setRow">
                    <button
                        type="button"
                        className="btn btnSecondary btnSmall"
                        onClick={async () => {
                            await api.logout();
                            window.location.assign("/");
                        }}
                    >
                        Auf diesem Gerät abmelden
                    </button>
                </div>
            </div>

            <div className="setGroup setDanger">
                <h3>Konto löschen</h3>
                {!delOpen ? (
                    <div className="setRow">
                        <button type="button" className="btn btnSecondary btnSmall" onClick={() => setDelOpen(true)}>
                            Konto löschen …
                        </button>
                    </div>
                ) : (
                    <>
                        <div className="setHint">
                            Löscht dein Konto mit Verlauf, Achievements, Saison-Punkten und Freunden. Das lässt sich <b>nicht rückgängig</b> machen. Zum Bestätigen <b>LÖSCHEN</b> eintippen:
                        </div>
                        <div className="setRow">
                            <input className="input" value={delText} onChange={(e) => setDelText(e.target.value)} placeholder="LÖSCHEN" aria-label="Zur Bestätigung LÖSCHEN eintippen" />
                            <button type="button" className="btn btnSmall btnDanger" onClick={() => void deleteAccount()} disabled={dBusy}>
                                {dBusy ? "…" : "Endgültig löschen"}
                            </button>
                            <button type="button" className="btn btnSecondary btnSmall" onClick={() => (setDelOpen(false), setDelText(""), setDMsg(null))}>
                                Abbrechen
                            </button>
                        </div>
                        <Note msg={dMsg} />
                    </>
                )}
            </div>
        </>
    );
}
