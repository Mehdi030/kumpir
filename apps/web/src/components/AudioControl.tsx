"use client";

import React, { useState } from "react";
import { getMuted, getVolume, setMuted, setVolume, unlockGameFx } from "@/lib/gameFx";

/**
 * Compact audio control: mute toggle + volume slider on hover/focus.
 * Designed to live in the top-right of the game HUD.
 */
export function AudioControl() {
    // Lazy init reads localStorage once on first render — no setState in effect.
    const [muted, setMutedState] = useState<boolean>(() => (typeof window === "undefined" ? false : getMuted()));
    const [volume, setVolumeState] = useState<number>(() => (typeof window === "undefined" ? 0.7 : getVolume()));
    const [open, setOpen] = useState(false);

    const toggleMute = () => {
        setMutedState((prev) => {
            const next = !prev;
            setMuted(next);
            if (!next) unlockGameFx();
            return next;
        });
    };

    const onVolumeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const v = Number(e.target.value);
        setVolumeState(v);
        setVolume(v);
        if (muted && v > 0) {
            setMuted(false);
            setMutedState(false);
        }
        unlockGameFx();
    };

    return (
        <div
            className="audioCtrl"
            onMouseEnter={() => setOpen(true)}
            onMouseLeave={() => setOpen(false)}
            onFocus={() => setOpen(true)}
            onBlur={(e) => {
                // close only when focus leaves the whole group
                if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setOpen(false);
            }}
        >
            <button
                type="button"
                onClick={toggleMute}
                className="audioBtn"
                title={muted ? "Sound an (M)" : "Sound aus (M)"}
                aria-label={muted ? "Sound einschalten" : "Sound ausschalten"}
                aria-pressed={!muted}
            >
                {muted || volume === 0 ? "🔇" : volume < 0.4 ? "🔈" : volume < 0.75 ? "🔉" : "🔊"}
            </button>

            <input
                type="range"
                min={0}
                max={1}
                step={0.05}
                value={muted ? 0 : volume}
                onChange={onVolumeChange}
                aria-label="Lautstärke"
                className="audioSlider"
                style={{ width: open ? 96 : 0, opacity: open ? 1 : 0 }}
            />

            <style jsx global>{`
        .audioCtrl {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 4px 6px;
          background: rgba(0, 0, 0, 0.42);
          border: 1px solid rgba(255, 255, 255, 0.16);
          border-radius: 999px;
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
        }
        .audioBtn {
          width: 30px;
          height: 30px;
          padding: 0;
          border-radius: 999px;
          background: transparent;
          border: none;
          color: white;
          font-size: 15px;
          cursor: pointer;
          display: grid;
          place-items: center;
          transition: filter 0.14s ease;
        }
        .audioBtn:hover { filter: brightness(1.15); }
        .audioSlider {
          appearance: none;
          background: transparent;
          height: 18px;
          transition: width 0.18s ease, opacity 0.18s ease;
          cursor: pointer;
        }
        .audioSlider::-webkit-slider-runnable-track {
          height: 4px;
          border-radius: 999px;
          background: rgba(255, 255, 255, 0.22);
        }
        .audioSlider::-moz-range-track {
          height: 4px;
          border-radius: 999px;
          background: rgba(255, 255, 255, 0.22);
        }
        .audioSlider::-webkit-slider-thumb {
          appearance: none;
          width: 14px;
          height: 14px;
          border-radius: 999px;
          background: white;
          border: none;
          margin-top: -5px;
          box-shadow: 0 2px 6px rgba(0, 0, 0, 0.32);
        }
        .audioSlider::-moz-range-thumb {
          width: 14px;
          height: 14px;
          border-radius: 999px;
          background: white;
          border: none;
          box-shadow: 0 2px 6px rgba(0, 0, 0, 0.32);
        }
      `}</style>
        </div>
    );
}
