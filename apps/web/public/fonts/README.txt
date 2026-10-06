kumpir-emoji.woff2
==================
Eigene Emoji-Schrift für Kumpir. Sie ersetzt die System-Emojis überall in der App
(Texte, Knöpfe, Avatare, Achievements, Ergebnis-Bild). Fehlt ein Emoji in der Schrift,
nimmt der Browser wie bisher das System-Emoji.

Grafiken: OpenMoji (https://openmoji.org) – Lizenz CC BY-SA 4.0
          (https://creativecommons.org/licenses/by-sa/4.0/)
Die Schrift ist ein Bearbeitung dieser Grafiken (nur die in der App benutzten Emojis,
in eine Farb-Schrift umgewandelt). Sie steht daher ebenfalls unter CC BY-SA 4.0.
Der Hinweis steht im Footer der Startseite.

Neu bauen (z. B. wenn ein neues Emoji im Code oder in der Datenbank dazukommt)
------------------------------------------------------------------------------
1. node db/scripts/emoji-collect.mjs     -> sammelt alle benutzten Emojis (Code + Datenbank)
2. node db/scripts/emoji-fetch.mjs       -> lädt die passenden OpenMoji-SVGs nach C:/Users/<du>/emoji-build/svg
3. In C:/Users/<du>/emoji-build (Python-venv mit "nanoemoji", "brotli", "ninja"):
     nanoemoji --color_format glyf_colr_0 --family "Kumpir Emoji" --output_file KumpirEmoji.ttf --build_dir build svg/*.svg
     python <repo>/db/scripts/emoji-check.py   (prüft die Abdeckung und schreibt KumpirEmoji.woff2)
4. KumpirEmoji.woff2 hierher als kumpir-emoji.woff2 kopieren.
