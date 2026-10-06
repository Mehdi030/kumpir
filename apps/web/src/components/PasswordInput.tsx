"use client";

import { useState, type InputHTMLAttributes } from "react";

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, "type"> & { value: string };

/** Passwortfeld mit "anzeigen/verbergen"-Knopf (weniger Tippfehler am Handy). */
export function PasswordInput({ className, ...rest }: Props) {
    const [show, setShow] = useState(false);
    return (
        <div className="pwWrap">
            <input {...rest} type={show ? "text" : "password"} className={className ?? "input"} />
            <button type="button" className="pwToggle" onClick={() => setShow((v) => !v)} aria-label={show ? "Passwort verbergen" : "Passwort anzeigen"} aria-pressed={show}>
                {show ? "🙈" : "👁️"}
            </button>
            <style>{`
        .pwWrap{ position:relative; width:100%; }
        .pwWrap .input{ padding-right:46px; }
        .pwToggle{ position:absolute; right:6px; top:50%; transform:translateY(-50%); border:0; background:transparent; font-size:18px; cursor:pointer; padding:6px; line-height:1; border-radius:10px; }
        .pwToggle:hover{ background: rgba(255,255,255,.12); }
      `}</style>
        </div>
    );
}
