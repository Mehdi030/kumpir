"""
Findet für jede Hörprobe (iTunes, 30 s) die Stelle, an der der Gesang einsetzt, damit das Spiel
nicht mit einem Instrumental-Intro startet.

Ablauf pro Song: Hörprobe laden (Cache) -> mit ffmpeg dekodieren -> Demucs (htdemucs) trennt die
Gesangsspur ab -> Lautstärke der Gesangsspur in 50-ms-Schritten -> erster Zeitpunkt, ab dem die Stimme
mindestens 0,6 s lang deutlich hörbar ist. Start = 0,25 s davor (nie negativ).

Aufruf (Python-Umgebung mit demucs, z. B. C:\\Users\\mehdi\\vocal-build):
  python db/scripts/vocal-start.py <songs.json> <ergebnis.json> [--limit N]
songs.json: [{id, title, artist, preview_url}, ...]   (Ausgabe von db/scripts/query.mjs)
ergebnis.json: {song_id: {"start_ms": ..., "vocal_share": ..., "len_ms": ...}} – wird fortgeschrieben,
fertige Songs werden beim nächsten Lauf übersprungen.
"""
import json
import os
import subprocess
import sys
import urllib.request

import numpy as np
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model

SR = 44100
FRAME = 0.05  # s


def load(path_in):
    raw = subprocess.run(
        ["ffmpeg", "-v", "quiet", "-i", path_in, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
        check=True, capture_output=True,
    ).stdout
    a = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T.copy()
    return torch.from_numpy(a)


def vocal_onset(vocals, mix):
    v = vocals.mean(0).numpy()
    m = mix.mean(0).numpy()
    n = int(SR * FRAME)
    frames = len(v) // n
    rv = np.sqrt((v[: frames * n].reshape(frames, n) ** 2).mean(1) + 1e-12)
    rm = np.sqrt((m[: frames * n].reshape(frames, n) ** 2).mean(1) + 1e-12)
    ref = np.percentile(rv, 95)
    if ref < 1e-4:
        return 0, 0.0
    # Stimme "da": laut genug im Verhältnis zur lautesten Gesangsstelle UND zum Gesamtsignal
    on = (rv > 0.22 * ref) & (rv > 0.18 * rm)
    share = float(on.mean())
    need = int(0.6 / FRAME)
    run = 0
    for i, x in enumerate(on):
        run = run + 1 if x else 0
        if run >= need:
            start = (i - need + 1) * FRAME - 0.25
            return max(0, int(round(start * 1000))), share
    return 0, share


def main():
    src, out = sys.argv[1], sys.argv[2]
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    songs = json.load(open(src, encoding="utf-8"))
    res = json.load(open(out, encoding="utf-8")) if os.path.exists(out) else {}
    cache = os.path.join(os.path.dirname(os.path.abspath(out)), "previews")
    os.makedirs(cache, exist_ok=True)
    torch.set_num_threads(max(1, (os.cpu_count() or 4) - 2))
    model = get_model("htdemucs")
    model.eval()
    vi = model.sources.index("vocals")
    todo = [s for s in songs if s["id"] not in res][:limit]
    for k, s in enumerate(todo, 1):
        f = os.path.join(cache, s["id"] + ".m4a")
        try:
            if not os.path.exists(f):
                urllib.request.urlretrieve(s["preview_url"], f)
            mix = load(f)
            with torch.no_grad():
                est = apply_model(model, mix[None], split=True, overlap=0.1, progress=False)[0]
            start, share = vocal_onset(est[vi], mix)
            res[s["id"]] = {"start_ms": start, "vocal_share": round(share, 2), "len_ms": int(mix.shape[1] / SR * 1000)}
            print(f"[{k}/{len(todo)}] {start/1000:5.1f} s  Gesang {share:4.0%}  {s['title']} – {s['artist']}", flush=True)
        except Exception as e:  # einzelne kaputte Datei bricht nicht alles ab
            print(f"[{k}/{len(todo)}] FEHLER {s['title']}: {e}", flush=True)
            continue
        if k % 5 == 0:
            json.dump(res, open(out, "w", encoding="utf-8"), indent=1)
    json.dump(res, open(out, "w", encoding="utf-8"), indent=1)
    print("fertig", len(res))


if __name__ == "__main__":
    main()
