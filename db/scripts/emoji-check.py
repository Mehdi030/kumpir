import json, sys
from fontTools.ttLib import TTFont

f = TTFont("build/KumpirEmoji.ttf")
print("Tabellen:", sorted(f.keys()))
cmap = f.getBestCmap()
used = json.load(open("C:/Users/mehdi/WebstormProjects/kumpir/db/scripts/data/emoji-used.json", encoding="utf-8"))
missing = []
for u in used:
    cps = [int(c, 16) for c in u["cps"] if c != "FE0F"]
    if len(cps) == 1:
        if cps[0] not in cmap:
            missing.append(u["emoji"])
    else:
        # Folgen: jedes Einzelzeichen soll im cmap sein ODER ein GSUB-Ligatur-Ziel
        name = "_".join("%04x" % c for c in cps)
        gnames = [g for g in f.getGlyphOrder() if g.lower().replace("uni", "").replace("u", "").replace("_", "") == name.replace("_", "")]
        if not gnames and not all(c in cmap for c in cps):
            missing.append(u["emoji"] + " (Folge)")
print("Glyphen:", len(f.getGlyphOrder()), "cmap:", len(cmap))
print("fehlen im Font:", missing)
f.flavor = "woff2"
f.save("KumpirEmoji.woff2")
import os
print("woff2 Größe:", os.path.getsize("KumpirEmoji.woff2"), "Bytes")
print("FE0F im cmap:", 0xFE0F in cmap)
