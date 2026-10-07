Eigene Emoji-Schrift für Kumpir
===============================
Ersetzt die System-Emojis überall in der App (Texte, Knöpfe, Avatare, Achievements, Ergebnis-Bild).
Fehlt ein Emoji in der Schrift, nimmt der Browser wie bisher das System-Emoji.

Grafiken: Microsoft Fluent Emoji, Stil "Color" (https://github.com/microsoft/fluentui-emoji) – Lizenz MIT.
Format: COLRv1 (Farbverläufe). Chrome, Edge und Firefox zeigen Fluent; Safari (iPhone/Mac) kann COLRv1
nicht und zeigt automatisch die Apple-Emojis.

Neu bauen (z. B. wenn ein neues Emoji im Code oder in der Datenbank dazukommt)
------------------------------------------------------------------------------
1. node db/scripts/emoji-collect.mjs     -> sammelt alle benutzten Emojis (Code + Datenbank)
2. node db/scripts/emoji-fetch.mjs       -> holt die Fluent-SVGs nach C:/Users/<du>/emoji-build/svg
                                            (Weichzeichner-Filter werden entfernt, sieht fast gleich aus)
3. In C:/Users/<du>/emoji-build (Python-venv mit "nanoemoji", "brotli", "ninja"):
     nanoemoji --color_format glyf_colr_1 --family "Kumpir Emoji" --output_file KumpirEmoji.ttf --build_dir build svg/*.svg
     PYTHONIOENCODING=utf-8 python check.py   (prüft die Abdeckung und schreibt KumpirEmoji.woff2)
4. KumpirEmoji.woff2 hierher als kumpir-emoji-fluent.woff2 kopieren (bei einem neuen Grafik-Stil neuen Dateinamen wählen, sonst behalten Browser bis zu 7 Tage die alte Schrift).
