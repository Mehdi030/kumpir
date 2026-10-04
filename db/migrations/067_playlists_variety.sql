-- ============================================================
-- Migration 067: 3 neue Playlists (80er Hits, Deutsch-Pop, Rock-Klassiker)
-- + Deutschrap-Songs auf 30+ Titel aufgefüllt
-- ============================================================
-- Auswahl: nur allgemein bekannte Hits (Ziel: mind. 85 % kennen sie),
-- keine Überschneidung zwischen den Playlists (Titel einzigartig, auch
-- gegen die bestehenden 3 Playlists geprüft). Jeder Song wurde per
-- iTunes-Suche verifiziert (Titel + Interpret passen, Preview vorhanden)
-- -- generiert mit db/scripts/build-playlists.mjs.
-- ============================================================
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT '80er Hits', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = '80er Hits');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('80er Hits', 'Billie Jean', 'Michael Jackson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a0/20/1b/a0201bf3-e6a7-f2fc-a836-a536593c3e51/mzaf_3717140176449046337.plus.aac.p.m4a'),
    ('80er Hits', 'Girls Just Want to Have Fun', 'Cyndi Lauper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/17/cf/6a17cffc-3d8f-96cf-9796-3b1894c87081/mzaf_4651252225789153600.plus.aac.p.m4a'),
    ('80er Hits', 'Sweet Dreams (Are Made of This)', 'Eurythmics', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/86/e3/8a/86e38af3-8863-973c-1c55-9f8187125741/mzaf_11175782400808341439.plus.aac.p.m4a'),
    ('80er Hits', 'Don''t You (Forget About Me)', 'Simple Minds', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d2/38/f0/d238f015-847a-6a10-09e4-9f00391a59bb/mzaf_6669203872576217423.plus.aac.p.m4a'),
    ('80er Hits', 'Africa', 'Toto', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/bb/3d/07/bb3d07a3-b3af-2c99-5c9f-eb72796268c2/mzaf_11871467005041854011.plus.aac.p.m4a'),
    ('80er Hits', 'Like a Virgin', 'Madonna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/53/7c/ee/537ceef4-ef8b-f822-2863-e754a404cd0b/mzaf_10337818103101697835.plus.aac.p.m4a'),
    ('80er Hits', 'Material Girl', 'Madonna', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f9/a3/69/f9a369cc-16a4-3064-2c12-56ecf13f18bc/mzaf_2371968126843790037.plus.aac.p.m4a'),
    ('80er Hits', 'Every Breath You Take', 'The Police', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/33/55/ce/3355ceb6-679b-dede-bc9e-20240c173541/mzaf_2582695436913795899.plus.aac.p.m4a'),
    ('80er Hits', 'Beat It', 'Michael Jackson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3a/5d/68/3a5d6822-c66d-a66d-9ff4-b5c202ccb1e6/mzaf_2361657803900731663.plus.aac.p.m4a'),
    ('80er Hits', 'Thriller', 'Michael Jackson', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f0/f5/e3/f0f5e387-ff78-101a-6397-aa3983d47031/mzaf_17965432547060573077.plus.aac.p.m4a'),
    ('80er Hits', 'Wake Me Up Before You Go-Go', 'Wham!', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/35/99/9e/35999e3f-480b-158a-2149-fa8ff249f882/mzaf_10746700119453640305.plus.aac.p.m4a'),
    ('80er Hits', 'Last Christmas', 'Wham!', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e6/77/57/e67757c8-e967-b6c1-87cc-1e0575693d2b/mzaf_6900971918188256614.plus.aac.p.m4a'),
    ('80er Hits', 'Careless Whisper', 'George Michael', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/21/89/59/21895916-e570-019b-1dce-fd19a9e4d6b8/mzaf_253631016813185496.plus.aac.p.m4a'),
    ('80er Hits', 'Karma Chameleon', 'Culture Club', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/7c/de/e5/7cdee5ce-a379-9f68-0602-8cf8c57311ac/mzaf_10937102495873020253.plus.aac.p.m4a'),
    ('80er Hits', 'Tainted Love', 'Soft Cell', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/05/7a/d8/057ad825-8f51-30ab-f830-e12a31ceeb5c/mzaf_15503561629945838399.plus.aac.p.m4a'),
    ('80er Hits', 'Don''t Stop Believin''', 'Journey', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b3/9f/9a/b39f9aff-5420-1499-ad96-4279228fdca4/mzaf_106745718629962303.plus.aac.p.m4a'),
    ('80er Hits', 'Livin'' on a Prayer', 'Bon Jovi', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/75/15/30/75153020-b7c4-7958-8907-4aa1b965dc24/mzaf_2377504467597068152.plus.aac.p.m4a'),
    ('80er Hits', 'Eye of the Tiger', 'Survivor', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d8/8a/b1/d88ab192-8608-562d-7442-d4cd76d7fefe/mzaf_1482115361099733526.plus.aac.p.m4a'),
    ('80er Hits', 'The Final Countdown', 'Europe', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d3/5b/d9/d35bd9a3-d105-95d8-ba29-0f5c6b8e764b/mzaf_7609183394807520180.plus.aac.p.m4a'),
    ('80er Hits', 'Never Gonna Give You Up', 'Rick Astley', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f5/2a/b8/f52ab85e-059c-e466-65f9-a6a2e7a568e7/mzaf_9448240738290206647.plus.aac.p.m4a'),
    ('80er Hits', 'Holding Out for a Hero', 'Bonnie Tyler', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/af/64/9c/af649c31-3655-14e6-7fe5-216a6f78ff67/mzaf_15929190961841576220.plus.aac.p.m4a'),
    ('80er Hits', 'Total Eclipse of the Heart', 'Bonnie Tyler', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/47/3d/35/473d35b3-b379-12d9-8fbf-88299e3cad7e/mzaf_5191559564499798673.plus.aac.p.m4a'),
    ('80er Hits', 'Walking on Sunshine', 'Katrina & The Waves', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a8/ac/35/a8ac356e-a64d-ac5d-16eb-ff62d8105e08/mzaf_6193506445269557291.plus.aac.p.m4a'),
    ('80er Hits', 'Time After Time', 'Cyndi Lauper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/00/b4/ec00b43c-2e21-c931-e452-cacd682f2251/mzaf_16975899866446384890.plus.aac.p.m4a'),
    ('80er Hits', 'I Wanna Dance with Somebody (Who Loves Me)', 'Whitney Houston', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/91/6e/5e/916e5ed8-e73d-3eaa-530e-2b29eba8dbdf/mzaf_12685718320321072710.plus.aac.p.m4a'),
    ('80er Hits', 'Come On Eileen', 'Dexys Midnight Runners', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/99/3f/2f/993f2f79-eff6-8bb6-5620-89297ab82bf9/mzaf_8325234611055133997.plus.aac.p.m4a'),
    ('80er Hits', 'Jump', 'Van Halen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/89/fa/f1/89faf128-b7de-808a-6893-4fc730dcfbe4/mzaf_10903024022773138434.plus.aac.p.m4a'),
    ('80er Hits', 'Footloose', 'Kenny Loggins', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/22/18/68/2218688a-ff36-7277-56de-c6b221d691c8/mzaf_12250270063124855744.plus.aac.p.m4a'),
    ('80er Hits', 'Flashdance... What a Feeling', 'Irene Cara', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ee/f0/fd/eef0fda5-3a77-ba9a-41e1-31e0fe603faa/mzaf_4287430643698303778.plus.aac.p.m4a'),
    ('80er Hits', 'Purple Rain', 'Prince', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/76/17/ba/7617bae9-013f-3e37-cd89-41998f6ed902/mzaf_15080256781020707908.plus.aac.p.m4a'),
    ('80er Hits', 'When Doves Cry', 'Prince', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f0/51/fc/f051fcce-eb4f-f9d5-d7ea-eb137750d9a8/mzaf_15769385331104997195.plus.aac.p.m4a'),
    ('80er Hits', 'Let''s Dance', 'David Bowie', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ea/e1/be/eae1be9d-611b-f67d-864f-1dc8df04726b/mzaf_8018381438157593013.plus.aac.p.m4a'),
    ('80er Hits', 'Down Under', 'Men At Work', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/76/1c/6e/761c6e1d-1b95-e87f-bcec-41afc0836a9a/mzaf_11800999298773408397.plus.aac.p.m4a'),
    ('80er Hits', 'Voyage, Voyage', 'Desireless', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c7/24/06/c7240641-7035-44a8-f2d0-e2ee8f197e2b/mzaf_2041993949195620983.plus.aac.p.m4a'),
    ('80er Hits', '99 Luftballons', 'Nena', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0c/24/c9/0c24c947-6410-77a3-057c-0987d613ad36/mzaf_66170433704112999.plus.aac.p.m4a'),
    ('80er Hits', 'Major Tom (Völlig losgelöst)', 'Peter Schilling', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8d/a2/4a/8da24a3b-1d84-2d5f-3305-14d24c781c33/mzaf_13902943445669410809.plus.aac.p.m4a'),
    ('80er Hits', 'Der Kommissar', 'Falco', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/65/d1/f4/65d1f495-beef-e4b4-17d3-28bca761560f/mzaf_4630646480375616791.plus.aac.p.m4a'),
    ('80er Hits', 'Rock Me Amadeus', 'Falco', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview122/v4/17/a5/26/17a526da-8141-7266-98fc-7f8b21cad289/mzaf_12457553091099431726.plus.aac.p.m4a'),
    ('80er Hits', 'Blue Monday', 'New Order', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0f/43/1c/0f431c1a-119c-6614-2736-3fbc4c8a597c/mzaf_3646998447648845325.plus.aac.p.m4a'),
    ('80er Hits', 'Kids in America', 'Kim Wilde', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3f/6e/cf/3f6ecf1a-8038-0313-36a3-5b2949142155/mzaf_932783320149738969.plus.aac.p.m4a'),
    ('80er Hits', 'Relax', 'Frankie Goes To Hollywood', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6d/b6/48/6db648ab-8b25-648a-420a-15fd086f0947/mzaf_17017095599203750844.plus.aac.p.m4a'),
    ('80er Hits', 'The NeverEnding Story', 'Limahl', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9e/41/2f/9e412f86-f086-bcda-4caf-9aec0da5db73/mzaf_3281567823547002322.plus.aac.p.m4a'),
    ('80er Hits', 'Gloria', 'Laura Branigan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b4/78/be/b478be15-8a37-8cd3-1ec7-a761149fcb21/mzaf_7508608839338770010.plus.aac.p.m4a'),
    ('80er Hits', 'Hungry Like the Wolf', 'Duran Duran', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/3d/89/37/3d8937c0-0af8-8e56-7a05-84eb313bebf1/mzaf_6649517434617225776.plus.aac.p.m4a'),
    ('80er Hits', 'Girls on Film', 'Duran Duran', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b1/73/59/b1735946-02e4-5676-dd28-d3566442141a/mzaf_10211230340607294220.plus.aac.p.m4a'),
    ('80er Hits', 'Dancing in the Dark', 'Bruce Springsteen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ec/c9/91/ecc99192-1c69-6aa0-5b80-35e5545528cb/mzaf_18148738310915598129.plus.aac.p.m4a'),
    ('80er Hits', 'Pump Up the Jam', 'Technotronic', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cd/24/04/cd2404d8-ec33-2d0b-6426-9f4037ddfe1c/mzaf_1717233101104902284.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutsch-Pop', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutsch-Pop');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Deutsch-Pop', 'Atemlos durch die Nacht', 'Helene Fischer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/de/96/b0/de96b0e2-457f-80ab-8deb-483074b3f964/mzaf_13820032290883879872.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Auf uns', 'Andreas Bourani', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ad/3c/61/ad3c61a1-f240-4a25-a33e-57bc71e5add9/mzaf_16275168154031441733.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Das Beste', 'Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b1/24/c7/b124c7ef-837d-cfb1-6cd9-afb61ea03a17/mzaf_691353218883590972.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Haus am See', 'Peter Fox', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dd/73/c8/dd73c864-bd13-5c3c-c684-bc45e7e1b658/mzaf_11804343455496657686.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Alles neu', 'Peter Fox', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/25/3e/0b/253e0bd2-403f-2d77-772b-d57293284597/mzaf_9531020977280373361.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Schwarz zu Blau', 'Peter Fox', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/ca/d1/da/cad1da45-b88b-22f3-9830-17afdde093b3/mzaf_10692662865583289845.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Nur ein Wort', 'Wir sind Helden', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/be/16/18/be16185a-8729-64fb-97a0-5e5eb03c7ca5/mzaf_8894170273939000752.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Denkmal', 'Wir sind Helden', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/69/e4/92/69e492ad-1ca1-f103-140e-8b3afaf9f028/mzaf_15095749718268062153.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Vom selben Stern', 'Ich + Ich', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/27/dc/f5/27dcf5c3-a235-5681-3337-940688185468/mzaf_1006676206739409196.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Geile Zeit', 'Juli', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/13/5d/58/135d587c-207d-1578-6adb-b6830ed0b1b8/mzaf_324307169502288637.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Perfekte Welle', 'Juli', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/22/10/6e/22106eb5-b184-4a39-dadc-86955685361c/mzaf_14611313335791529378.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Wie schön du bist', 'Sarah Connor', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/62/d8/12/62d8124c-6c57-7f17-1209-e3b9f2b8d8c0/mzaf_16701527472761760534.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Au revoir', 'Mark Forster, Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/78/3f/5a/783f5a09-e406-d843-ffa3-3b0f30cd3150/mzaf_12336214171557554920.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Chöre', 'Mark Forster', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/71/f8/59/71f8595f-cf30-44e8-8bf3-021e4fbde75e/mzaf_15526366958179967486.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Flash mich', 'Mark Forster', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/01/0e/b4/010eb4bb-9148-3a30-c64a-ebb7a32ad5d0/mzaf_4659479273206319668.plus.aac.p.m4a'),
    ('Deutsch-Pop', '80 Millionen', 'Max Giesinger', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8c/a3/db/8ca3dbab-22e9-040c-b1d0-6fb0d5c8b4a7/mzaf_10388389663581688460.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Wenn sie tanzt', 'Max Giesinger', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/66/1d/c9/661dc92e-f473-2874-221b-ccd71b0a8de5/mzaf_5638113420182681751.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Tage wie diese', 'Die Toten Hosen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ca/86/95/ca869587-b0c5-c3f5-5200-21c0c682660b/mzaf_6658429541659026420.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Männer', 'Herbert Grönemeyer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/97/72/a5977274-6982-bb64-79db-43578f974163/mzaf_3541195977681608889.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Mensch', 'Herbert Grönemeyer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3c/9a/20/3c9a203a-63e8-89a1-5870-355a06bfb4dd/mzaf_1128187272067325576.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Bochum', 'Herbert Grönemeyer', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a5/22/77/a52277b9-bc63-2352-09af-22694ec4c168/mzaf_15078942190330159748.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Irgendwas bleibt', 'Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/dd/d3/f9/ddd3f9cb-5639-9069-ff7a-f124e7d22cab/mzaf_17833433783132470617.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Symphonie', 'Silbermond', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/d9/59/ad/d959ad82-33be-bd57-dd0f-f28813c7fefc/mzaf_8011789993432230967.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Du hast', 'Rammstein', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5a/75/08/5a7508ee-f167-37aa-3b1a-7c63db8cb450/mzaf_11938743806268466326.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Schrei nach Liebe', 'Die Ärzte', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e5/3f/4d/e53f4dbb-c45a-4669-8c8d-36cd641e550a/mzaf_5250262973873347333.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Junge', 'Die Ärzte', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/b7/55/5c/b7555c03-0a1c-f676-71ed-b5531047b33b/mzaf_3937501780846588412.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Dieser Weg', 'Xavier Naidoo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/ec/09/54/ec095427-a499-1f51-75a9-d8db3491464e/mzaf_5239449848784989632.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Was wir alleine nicht schaffen', 'Xavier Naidoo', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dc/a5/56/dca55673-ad29-8e21-119f-96e22a8daa71/mzaf_10981131678521095176.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Nur noch kurz die Welt retten', 'Tim Bendzko', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9c/eb/d3/9cebd391-04ba-47f5-15dc-dbddc17db196/mzaf_2464837171895883732.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Wie soll ein Mensch das ertragen', 'Philipp Poisel', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/c7/03/62/c7036244-dd57-9e00-d554-6f929cc1a495/mzaf_15557778499790392309.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Die immer lacht', 'Kerstin Ott', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a9/6e/a2/a96ea2ea-3785-72ed-26d5-86d8872adf5c/mzaf_13081333979695466971.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Halt dich an mir fest', 'Revolverheld', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b3/3f/7a/b33f7a0b-43e9-6d6c-fc46-cde65311cc4a/mzaf_9122751001031449853.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Lass uns gehen', 'Revolverheld', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a0/df/7f/a0df7f8e-1260-41d4-6020-a50a68565e9d/mzaf_16393009569438452120.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Verdammt, ich lieb'' dich', 'Matthias Reim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/30/1f/7d/301f7d60-4916-21cd-dbe2-6dd11f9daece/mzaf_12171051327600935346.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Remmidemmi (Yippie Yippie Yeah)', 'Deichkind', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/09/0c/f8/090cf8f9-b476-a65a-bbc6-410b3ea4eb40/mzaf_3066246424451358538.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Ohne Dich', 'Münchener Freiheit', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8f/14/d7/8f14d7bf-2f7c-ebdb-7b88-d3a7a8db98d0/mzaf_13097502796743649801.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Sonne', 'Rammstein', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/5a/74/79/5a7479f4-54f7-62e8-6500-51fd2bc41a1f/mzaf_5614602769858578012.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Millionär', 'Die Prinzen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f5/ba/b3/f5bab310-4b4a-90e7-9709-01aa6d029d40/mzaf_9938191721252823859.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Mein Herz brennt', 'Rammstein', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/07/c4/37/07c437fb-1181-c34f-c12d-1d5bf620f530/mzaf_13566694454359017291.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Ich will Spaß', 'Markus', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/95/53/9d/95539d27-f94f-60d5-5f94-23c4cf9d3091/mzaf_7976054926271081178.plus.aac.p.m4a'),
    ('Deutsch-Pop', 'Ich war noch niemals in New York', 'Udo Jürgens', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e2/c4/5b/e2c45bd5-c0bf-2315-32b3-bc49c4d21b56/mzaf_10457787525492184810.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Rock-Klassiker', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Rock-Klassiker');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Rock-Klassiker', 'Bohemian Rhapsody', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cd/9f/c5/cd9fc5f8-4979-d79e-abf4-883e54f717d1/mzaf_15408639854395137008.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'We Will Rock You', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/0a/a9/f3/0aa9f3af-4672-fb3b-42d8-6d56a9a4c69b/mzaf_16030082968131796908.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Don''t Stop Me Now', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f1/33/52/f1335205-3f9c-d385-4ad1-05e1fdbb4b25/mzaf_12271468743380438228.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Another One Bites the Dust', 'Queen', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/cf/06/67/cf066706-f868-e26b-c8b9-552f51b258f6/mzaf_8129975054693207838.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Stairway to Heaven', 'Led Zeppelin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/fc/3e/cf/fc3ecfde-a878-2d65-5929-cf325bcc234a/mzaf_17376241315973674081.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Whole Lotta Love', 'Led Zeppelin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/8a/15/37/8a1537e5-9d18-7e44-4ca8-3295942263b6/mzaf_2401048427177636441.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Hotel California', 'Eagles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a9/be/ba/a9bebaab-3eb5-d185-a5af-c75d122ba892/mzaf_15660694999198133668.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Smoke on the Water', 'Deep Purple', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/08/3f/1b/083f1b23-decd-8fe6-2bad-0437d1c5d959/mzaf_9991776491763640927.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Sweet Child O'' Mine', 'Guns N'' Roses', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a5/82/2d/a5822d67-2e65-fe95-511e-1f785d23e5cc/mzaf_8619467974951398014.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Paradise City', 'Guns N'' Roses', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0b/2d/ec/0b2dec08-f03d-8a96-93a8-386a7d7b5091/mzaf_12821402190646617663.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Welcome to the Jungle', 'Guns N'' Roses', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1f/70/d6/1f70d6e8-edab-5ea1-4c3b-e51744cc79c7/mzaf_2766266430694093633.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Nothing Else Matters', 'Metallica', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/9b/a1/37/9ba137ed-330d-09e6-7449-e0557dfbe85d/mzaf_14863385354373294620.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Enter Sandman', 'Metallica', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/f9/5b/8d/f95b8d0b-6526-b5a3-b565-e9e07f9ce929/mzaf_1100904155230105156.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Smells Like Teen Spirit', 'Nirvana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/b0/36/9c/b0369c24-5047-1f93-a228-64ecec779cdc/mzaf_17479720470163953122.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Come as You Are', 'Nirvana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6a/f1/9e/6af19e76-a475-2837-db0a-60d29f74ace6/mzaf_9899031328948492518.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Wonderwall', 'Oasis', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ea/e6/de/eae6de59-5000-da21-c882-f52fc2492428/mzaf_12629158787072767220.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Don''t Look Back in Anger', 'Oasis', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/58/62/66/58626600-2593-05b5-9b47-6eacc65ea8d2/mzaf_11697044045943414259.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Creep', 'Radiohead', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1f/18/e2/1f18e22b-264e-88f8-ee89-c196fa9abd7a/mzaf_14184372154331980897.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Under the Bridge', 'Red Hot Chili Peppers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9b/5b/76/9b5b76af-214c-82c9-2dae-5971e3bb25ba/mzaf_12325461313798845398.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Californication', 'Red Hot Chili Peppers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/cb/4a/fc/cb4afcc4-021b-664d-ddb0-3c6fe969b519/mzaf_2631134696080272573.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Basket Case', 'Green Day', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d2/5b/2a/d25b2a88-232a-f454-9df2-670b8115a0e8/mzaf_1677607799407141057.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Seven Nation Army', 'The White Stripes', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/7f/28/22/7f282276-e463-79c2-b770-40c762df0c48/mzaf_3138918352191055941.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Mr. Brightside', 'The Killers', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5b/17/4e/5b174e80-1047-7214-1077-d822ba1f9520/mzaf_5975692497663881329.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Zombie', 'The Cranberries', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/35/bb/65/35bb6532-1abe-59e4-9ced-8bee2742ea24/mzaf_15102830936602294569.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Sweet Home Alabama', 'Lynyrd Skynyrd', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/df/83/05/df830577-1f01-5cd8-0121-be1d211e0fb6/mzaf_6134975832316471112.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Paint It Black', 'The Rolling Stones', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/da/f5/ec/daf5ece2-6853-c6a4-d481-389001453f75/mzaf_3869995397273029315.plus.aac.p.m4a'),
    ('Rock-Klassiker', '(I Can''t Get No) Satisfaction', 'The Rolling Stones', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ee/4d/28/ee4d28cd-a465-1334-2863-efda9ea9669b/mzaf_8440807812349084607.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Born to Be Wild', 'Steppenwolf', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/71/33/6d/71336d1f-e008-d0f8-5dff-25fa0974ef8d/mzaf_13245098132834526016.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Let It Be', 'The Beatles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6d/17/53/6d1753e6-debc-115a-0fd2-11a705795b74/mzaf_10149167119683527545.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'In the End', 'Linkin Park', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0c/ad/c0/0cadc05e-846a-b090-c7e9-6017df2e0ab5/mzaf_1775739195432502696.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Numb', 'Linkin Park', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/93/dc/45/93dc455c-483f-8931-ef2e-cec30e2ed4bb/mzaf_3013383482601094146.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Bring Me to Life', 'Evanescence', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/dd/fe/35/ddfe35a4-491e-cf31-658c-d0a146402b29/mzaf_1325478918326867414.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Chop Suey!', 'System Of A Down', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2c/5e/b8/2c5eb8e9-93d3-b530-d7fd-63774ae21066/mzaf_7290820158982694185.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Iron Man', 'Black Sabbath', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/77/ca/ae/77caae8f-3f9d-db83-a453-b9d2d46c7118/mzaf_17772168214401601614.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Paranoid', 'Black Sabbath', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview124/v4/db/4a/48/db4a48f4-01a3-ab8e-f0ff-b2cff713142f/mzaf_1687608787420965868.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Do I Wanna Know?', 'Arctic Monkeys', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/89/ae/42/89ae4206-048a-7eae-3eaf-c3abd02914fb/mzaf_15551176804491638370.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Use Somebody', 'Kings of Leon', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/23/1d/b3/231db3c5-a99c-3fba-5d3b-f6e9cdbeb841/mzaf_12581310710694950303.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Sex on Fire', 'Kings of Leon', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/9f/e7/52/9fe75225-7a58-47d3-d570-22ae95bb160d/mzaf_1409968636503833590.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Knockin'' on Heaven''s Door', 'Bob Dylan', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/04/65/74/046574c1-e3d3-d94e-6c06-0fc5b283a688/mzaf_4165602350498591047.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Hey Jude', 'The Beatles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/31/47/fe/3147fe89-fb45-bc4a-4c16-dcc82e205aa6/mzaf_11654990763388730424.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Light My Fire', 'The Doors', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/e2/2e/99/e22e9993-9f0c-df04-4aec-133a7045bce5/mzaf_14103368404409074100.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Back in the U.S.S.R.', 'The Beatles', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/14/8d/37/148d379a-2070-8f0a-a542-1a9d57caa91e/mzaf_17277814682471409823.plus.aac.p.m4a'),
    ('Rock-Klassiker', 'Rock You Like a Hurricane', 'Scorpions', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/36/46/fd/3646fd1f-4f9b-2395-2c83-89624fa1447f/mzaf_3391925793740712006.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap-Songs', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap-Songs');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Deutschrap-Songs', 'Easy', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/72/e5/9b/72e59b85-ee9e-9b0e-746d-bc35aee1b0b5/mzaf_7893096664339783467.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Traum', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b0/21/e1/b021e142-6926-8dbe-2619-3ff999a5c770/mzaf_4428899675628945601.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Erfolg ist kein Glück', 'Kontra K', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/29/cc/94/29cc94f7-f243-2f23-4f26-ccfe243bbd7c/mzaf_5704929239630484468.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'NDW 2005', 'Fler', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/93/13/d1/9313d1a3-3c5e-354a-c02e-315fed91473f/mzaf_8694059876417981331.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Mein Block', 'Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/02/dc/9b/02dc9bc1-cce4-8e7f-b6d8-65c55b6b2086/mzaf_468114569001241405.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Für immer jung', 'Bushido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/c4/6c/32/c46c329f-62ce-0a6c-4a32-bddcf5d41e1c/mzaf_8034649478957838891.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Palmen aus Plastik', 'Bonez MC, RAF Camora', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/1e/c4/e1/1ec4e1eb-fe4d-37be-0f0b-3b3776d3e25b/mzaf_8167689886240399456.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Vermissen', 'Juju', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/db/a6/d6/dba6d667-f699-7b95-3109-e949d5e1c089/mzaf_5952168470338838373.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Lila Wolken', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a1/47/4b/a1474b0b-2b24-f330-4345-7fbe8212dba7/mzaf_10836573937865411354.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Hinterland', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/19/4e/f4/194ef4e4-7d3e-5c08-5380-54d487285db5/mzaf_7755148851616662122.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Willst du', 'Alligatoah', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/bf/12/90/bf1290a6-9d84-a854-0015-a17372df44ae/mzaf_14479433487154095514.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Bad Chick', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/50/c5/52/50c55257-c07f-b827-9493-884aaaf0c318/mzaf_17421216701355027386.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Jein', 'Fettes Brot', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/8a/a3/7a/8aa37a84-36e8-8dcd-0b5c-e2532d8b2cf2/mzaf_3867408908518139439.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'MfG', 'Die Fantastischen Vier', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/b7/c2/56/b7c256bd-c38e-2432-5e97-5d412ca36b7a/mzaf_1354000171391241042.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Kids (2 Finger an den Kopf)', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/6b/da/c7/6bdac7aa-ae8d-b89e-d9cf-b066e88996f3/mzaf_3303354876056285465.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Augen auf', 'Sido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview115/v4/c9/9c/cf/c99ccfc1-9bcf-fa2d-eb63-8b6c30487d17/mzaf_11743602834165678944.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

COMMIT;
