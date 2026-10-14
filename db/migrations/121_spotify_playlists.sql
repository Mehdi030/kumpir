-- Generiert von db/scripts/build-spotify-playlists.mjs (2026-10-14)
-- Playlists aus Spotify-Vorlagen (Hörproben von Spotify, Erscheinungsjahr von Deezer)
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Top 50 Deutschrap', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Top 50 Deutschrap');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at, release_year)
SELECT tp.id, v.title, v.artist, v.url, now(), v.year
FROM (VALUES
    ('ISSA', 'Sido', 'https://p.scdn.co/mp3-preview/9d0e162ac88feae4530528afdd8bbaee609e0932', 2026),
    ('panzerknacker.wav', 'LENNSKO', 'https://p.scdn.co/mp3-preview/80ba1f17f3fa1a072a0e18b76edc4ee70440e63d', 2026),
    ('MO'' MONEY MO'' HATERS', 'Summer Cem & Shirin David', 'https://p.scdn.co/mp3-preview/fe262f750827c48f515c8c9e12c2652b535b5b6a', 2026),
    ('AKON', 'Jazeek', 'https://p.scdn.co/mp3-preview/89ed6cd2c762e2f82fec1affabfd4535f5920330', 2025),
    ('MNG', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/66cdd21bed79c8e6333938d14cad7dc358f6a04e', 2025),
    ('Count your blessings', 'Sa4 & Gzuz', 'https://p.scdn.co/mp3-preview/ca8caa0bb26e02f09b7c3f494614c0a2ada6e766', 2026),
    ('Andere Niveau', 'Bobby Vandamme, 3robi & Chahid', 'https://p.scdn.co/mp3-preview/e266fb3d70a12aa120f38c97b51c8375d284f664', 2025),
    ('KILLY MANJARO', 'Summer Cem & BILLA JOE', 'https://p.scdn.co/mp3-preview/c59e2a48027d56f68e486ede3eb66dff9bd862f8', 2026),
    ('Amo aller Amos', 'Amo', 'https://p.scdn.co/mp3-preview/cac94fc3811e694975b9df2993bbccb057507314', 2024),
    ('Hin und Her', 'AK AUSSERKONTROLLE', 'https://p.scdn.co/mp3-preview/b3014838b5ad708fd0e77bedc701df05bd32e987', 2026),
    ('ABC', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/6f3cb6335bc396423f995fe9e50f396da23ecab6', 2026),
    ('Sonne über Berlin', 'Capital Bra & Samra', 'https://p.scdn.co/mp3-preview/da36d6a227ab150d06f339cf17b0fe0a52040c37', 2026),
    ('Capri Sun', 'Aymen & Amo', 'https://p.scdn.co/mp3-preview/45497f1d12f4f081e7b1af331aef6a8026cb3cd9', 2025),
    ('BLOCKKIDS', 'THIZZY52', 'https://p.scdn.co/mp3-preview/e561597991bd9c357d5e74ae270b9cd9aba936ba', 2026),
    ('Rapstar', 'Amo & Nimo', 'https://p.scdn.co/mp3-preview/14c2e9142bc77c26eb6a6e74bbf3935d18bef50a', 2024),
    ('Ghetto Superstars', 'Samra & Capital Bra', 'https://p.scdn.co/mp3-preview/908222af4ec9c8fba1a5a5a446c7671eaf2d214a', 2026),
    ('Vermisse', 'Dardan & Azet', 'https://p.scdn.co/mp3-preview/a1b80b26aecde496d7b9c971c20bd5ff9b71b118', 2026),
    ('Böse Jungs', 'Capital Bra, Samra & LACAZETTE', 'https://p.scdn.co/mp3-preview/e9b663f5740b3c922267f83f02d1ec2e1a2d7157', 2026),
    ('Shabab(e)s im VIP', 'Pashanim & Ceren', 'https://p.scdn.co/mp3-preview/532ddc11846d363d2a32fd580c55db4c66f6b151', 2025),
    ('LID', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/9357d1709a1ef5926625abe31b6b20a1ec3ccf1b', 2024),
    ('G Wagon', 'Gzuz', 'https://p.scdn.co/mp3-preview/a7a2f66513bdbc5b8450df57da65c74d4936ba7f', 2024),
    ('CONNECTED', 'RAF Camora & reezy', 'https://p.scdn.co/mp3-preview/030f097eec3f5320339a4d0c92476297f5749e22', 2025),
    ('CDY', 'LACAZETTE & Jazeek', 'https://p.scdn.co/mp3-preview/eb8374db988196d2fb3986889675c3a58033340a', 2026),
    ('CASA CUBA', 'Cave & Amo', 'https://p.scdn.co/mp3-preview/db00d4e7b3d7435d03b4d6e88500f2e7b2b55aed', 2026),
    ('FTW', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/6c6b2c21a6d7f5010b67877229c9efca37d552e6', 2024),
    ('30 mal am Tag', 'Aymen & SIRA', 'https://p.scdn.co/mp3-preview/dd47e253da04d89f26e7ba7fcbab24a3329448e3', 2025),
    ('Eurosport', 'Dardan & Azet', 'https://p.scdn.co/mp3-preview/efcad5871ef5d6537e4c7c60a56d140c7e28ffe8', 2024),
    ('Mittelmeer', 'Pashanim', 'https://p.scdn.co/mp3-preview/96778f6e162075057e3aa2455b70b82a3f0cf0af', 2024),
    ('H&K', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/4e22ed6fde7e10e032cbd11832585f104b6585b8', 2024),
    ('Uff Yaa', 'ZAH1DE', 'https://p.scdn.co/mp3-preview/12383a1f091ee8bacd7afe4628ebf5c3ae8e73c6', 2025),
    ('HDL', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/921226900d05e029a43351285735f500f63c496a', 2024),
    ('Ombre Nomade', 'SadiQ, Dú Maroc, KC Rebell & Kolja Goldstein', 'https://p.scdn.co/mp3-preview/ecc31a5cd8104b8154ebf9f917b1077d3bbbeaa1', 2025),
    ('PARFUM', 'Jazeek & Shindy', 'https://p.scdn.co/mp3-preview/4f207f5524c94f99af6f5a8eeae8648b441e20a5', 2025),
    ('Bleib stark', 'Aymo, Aymen & Amo', 'https://p.scdn.co/mp3-preview/6968449029d143b5352dd105380ac137a3bf4cc0', 2025),
    ('XOX', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/9b31c4df75b3fc9e2baf51c6b5d9bd0b615469a8', 2025),
    ('In a minute', 'Luciano', 'https://p.scdn.co/mp3-preview/8319cd0e856c5b2273907f03736562bf694cf121', 2024),
    ('TMAX', 'DANO', 'https://p.scdn.co/mp3-preview/1537e345cdb268ba12b5ce1031d9fc622a0f483f', 2023),
    ('CUP', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/ff4d83c7b91ece12cd59d957e22fe2b324346c72', 2024),
    ('Gib uns niemals auf', 'Hava & Dardan', 'https://p.scdn.co/mp3-preview/f261a6975264f3c0420f98f445f7680d20f28285', 2025),
    ('Dunya', 'Amo', 'https://p.scdn.co/mp3-preview/46794984077e56bf25774e682d191a8e4796ecef', 2022),
    ('2 Germans', 'Luciano & Gzuz', 'https://p.scdn.co/mp3-preview/41ee5c855949d08d54b88b938a031ce1a699f191', 2023),
    ('REDE', 'ZAH1DE & benno!', 'https://p.scdn.co/mp3-preview/3ef45512a0d08f159818b03cd8835799ddc61ef8', 2025),
    ('mhm...', 'Azet', 'https://p.scdn.co/mp3-preview/19476a9428807b98e80063ca50469ded43b0a08f', 2024),
    ('Papa', 'Aymen', 'https://p.scdn.co/mp3-preview/fe1d4619bbb8a86e457dd661fe9f088aa589eb7e', 2024),
    ('Starboy', 'Luciano & Jazeek', 'https://p.scdn.co/mp3-preview/5f4134d83defe3aeeb9fd0b337a8c8ed23e5d547', 2024),
    ('AMA DOREN', 'Bobby Vandamme', 'https://p.scdn.co/mp3-preview/d2927ab8fa6a9a1dda7c4958f2cc71902911dd36', 2024),
    ('Weiß nicht', 'EMES', 'https://p.scdn.co/mp3-preview/f9bad191651f9f4f217695a1ab46b4352cc2f053', 2023),
    ('Buscape', 'Azet & Bobby Vandamme', 'https://p.scdn.co/mp3-preview/1f8c3cb59b20ba55b77b8cda9a225d02b7a98576', 2025),
    ('Bengel', 'Gzuz', 'https://p.scdn.co/mp3-preview/f8dbc0aa134cd9e86b8ef3494a2e92c894fc05b0', 2025),
    ('Syt', 'Azet, Dhurata Dora & Dardan', 'https://p.scdn.co/mp3-preview/7095b767e872483e9556a845e0591223bd9ccd05', 2025)
) AS v(title, artist, url, year)
JOIN public.topic_pool tp ON tp.text = 'Top 50 Deutschrap'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap Asphalt', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap Asphalt');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at, release_year)
SELECT tp.id, v.title, v.artist, v.url, now(), v.year
FROM (VALUES
    ('BLOCKKIDS', 'THIZZY52', 'https://p.scdn.co/mp3-preview/e561597991bd9c357d5e74ae270b9cd9aba936ba', 2026),
    ('Hin und Her', 'AK AUSSERKONTROLLE', 'https://p.scdn.co/mp3-preview/b3014838b5ad708fd0e77bedc701df05bd32e987', 2026),
    ('ABC', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/6f3cb6335bc396423f995fe9e50f396da23ecab6', 2026),
    ('069', 'Haftbefehl & Bazzazian', 'https://p.scdn.co/mp3-preview/1249078edbe5d17fd116622144ae2ba0e1453e3f', 2015),
    ('panzerknacker.wav', 'LENNSKO', 'https://p.scdn.co/mp3-preview/80ba1f17f3fa1a072a0e18b76edc4ee70440e63d', 2026),
    ('BALOTELLI', 'THIZZY52', 'https://p.scdn.co/mp3-preview/da2a798cab31a02109d6139702c204f8a77e6377', 2026),
    ('Off', 'Sosa La M', 'https://p.scdn.co/mp3-preview/09ca90f7b7d6667b08d81a9e789ea21bc9ee89c9', 2026),
    ('64B', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/3a942c032861aaf94f3b5600facc6347103f413b', 2026),
    ('Jim Beam & Voddi', 'AK AUSSERKONTROLLE & Bonez MC', 'https://p.scdn.co/mp3-preview/1ecb14f94d0a138db850ff1c4b546e0504a6a261', 2017),
    ('Böse Jungs', 'Capital Bra, Samra & LACAZETTE', 'https://p.scdn.co/mp3-preview/e9b663f5740b3c922267f83f02d1ec2e1a2d7157', 2026),
    ('1999 Pt. 6 (Gabriel vs. Luzifer)', 'Haftbefehl & Bazzazian', 'https://p.scdn.co/mp3-preview/fd2c1ba94373df292d6517fb6d5e999c67cc3359', 2020),
    ('Back outside', 'Sosa La M', 'https://p.scdn.co/mp3-preview/b23e17e6fa44ab86159220dfe4ebbca2d3588190', 2025),
    ('MNG', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/66cdd21bed79c8e6333938d14cad7dc358f6a04e', 2025),
    ('Paper', 'AK AUSSERKONTROLLE', 'https://p.scdn.co/mp3-preview/2f69a0c35e4e3e1ebe7c0358592e6cf7166cb518', 2026),
    ('Doppelpack', 'Toujour', 'https://p.scdn.co/mp3-preview/f9898442b6962d3e42f6ea9fb6197b0d7c8a04aa', 2026),
    ('Wie Mach Ich Para', 'Ghost61 & VOLO', 'https://p.scdn.co/mp3-preview/fdcdd8c09e40a1028b797ccfd2b602debb1468ea', 2025),
    ('Northside', 'Sosa La M', 'https://p.scdn.co/mp3-preview/52beab9af6b2b31632ea37c393c690fcc207c753', 2025),
    ('TTT', 'LACAZETTE', 'https://p.scdn.co/mp3-preview/71de8817421f20c351ce42f5b07e5aedd9dcadcb', 2026),
    ('LDNB', 'AK AUSSERKONTROLLE & Shirin David', 'https://p.scdn.co/mp3-preview/007d68ddef1eeade2f008b9108494542fc80c6ce', 2026),
    ('Ballon d''Or', 'Sosa La M', 'https://p.scdn.co/mp3-preview/fa2a41f7af9580989bf2fc1e70317138c5f72f94', 2026),
    ('Ombre Nomade', 'SadiQ, Dú Maroc, KC Rebell & Kolja Goldstein', 'https://p.scdn.co/mp3-preview/ecc31a5cd8104b8154ebf9f917b1077d3bbbeaa1', 2025),
    ('Ghetto Superstars', 'Samra & Capital Bra', 'https://p.scdn.co/mp3-preview/908222af4ec9c8fba1a5a5a446c7671eaf2d214a', 2026),
    ('+49', 'LACAZETTE, Nizi19, Lucio101 & Yuyu19', 'https://p.scdn.co/mp3-preview/02772772072d8c8a49d01a5095bd2ffaf63bcdd4', NULL::int),
    ('1999 Pt. 5 (Mainpark Baby)', 'Haftbefehl & Bazzazian', 'https://p.scdn.co/mp3-preview/c4f1d7fb75b79204f8cd116616a24ce4f25ecf2c', 2020),
    ('Black Afgano', 'SadiQ & KALIM', 'https://p.scdn.co/mp3-preview/52713e8fb68d6fa9eac22a2c9e3ac1ef9bacadfb', 2026),
    ('Superstar', 'Sosa La M', 'https://p.scdn.co/mp3-preview/d0a572850d0654f4d3e257e54dc3781b63b5127d', 2023),
    ('G Wagon', 'Gzuz', 'https://p.scdn.co/mp3-preview/a7a2f66513bdbc5b8450df57da65c74d4936ba7f', 2024),
    ('SELEÇÃO', 'THIZZY52', 'https://p.scdn.co/mp3-preview/73ea5315ee7c5bcb02d94cb2f0b8cefed334976d', 2025),
    ('RADW', 'Haftbefehl & Bazzazian', 'https://p.scdn.co/mp3-preview/f10e6e9de381baf1b4f4a95f19f7c6ab3bef1db5', 2020),
    ('STRASSE', 'Cave, Amo & Soufian', 'https://p.scdn.co/mp3-preview/b8e563334d906da1180f4bdb1f440701317c3fed', 2026),
    ('Blonde Amber', 'SadiQ, Kolja Goldstein, CAPO & Eno', 'https://p.scdn.co/mp3-preview/9e47d52cef4bdda1a14fbc80f91d1e9e35e2891a', 2026),
    ('QUALITÄT', 'Sonus030 & AK AUSSERKONTROLLE', 'https://p.scdn.co/mp3-preview/6760dea55a8b5b12f63abdf47a88fb35387ddfdb', 2025),
    ('CRASHOUT FREESTYLE', 'Juju', 'https://p.scdn.co/mp3-preview/94aac68005d763609286b64b7bfd5cd34bf43fb5', 2026),
    ('PUSH PUSH', 'Mucco', 'https://p.scdn.co/mp3-preview/2c5bb2ea489e8cb4ec1dc047199343295e24d244', 2025),
    ('63', 'BOJAN & Mucco', 'https://p.scdn.co/mp3-preview/f59d0724ab10b0c9ed942ce78b502a70dd0540e6', 2026),
    ('Schwarzfahren', 'HWZ & SOTT', 'https://p.scdn.co/mp3-preview/f83de4c03abb56b48fc5ff336f2e79a961740e8b', 2026),
    ('MON FRÈRE', 'THIZZY52', 'https://p.scdn.co/mp3-preview/e9fb557dbf766b983c0d86c39d16610b638cd7b9', 2026),
    ('Rücken an Rücken', 'Aymo, Aymen & Amo', 'https://p.scdn.co/mp3-preview/78df512b87edda3c3ebcf390d765d5484448f9b9', 2025),
    ('Hmm Hmm', 'Dardan & Azet', 'https://p.scdn.co/mp3-preview/8321b825894c910802750ed3ec11c8d46ae2eca4', 2026),
    ('Gsg9', 'Ghost61', 'https://p.scdn.co/mp3-preview/f07693f8a23075e4ec1f475fbee1573a18b2901c', 2024),
    ('Substanzen', 'Rap La Rue, Jiyo, ILO 7ARAGA & Aymen', 'https://p.scdn.co/mp3-preview/b90038b2b00c330f8deb8121b5d74b66f9178dea', 2024),
    ('FUXWAVE', 'Eno & KARDO', 'https://p.scdn.co/mp3-preview/81b8a99abf86b99e07644c0fd178d53db6fccc55', 2025),
    ('Project X', 'Aymen, KIARABABA, CANEY030, Ché Salah, Amo & Ego', 'https://p.scdn.co/mp3-preview/d86c93622ea1e45a8433245da06a80311705c0b6', 2026),
    ('BABY BOY (2026)', 'KARDO & X WAVE', 'https://p.scdn.co/mp3-preview/0dc8c603c4089c1aa3a5615a1d44556f131df24a', 2026),
    ('Leben', 'Ghost61 & Kolja Goldstein', 'https://p.scdn.co/mp3-preview/fd38ab83640b0795605a6b68f3ae84af07be9c51', 2026),
    ('syndrom stockholm', 'oddworld & Haftbefehl', 'https://p.scdn.co/mp3-preview/5d6799d7140d129f1e88741d1871a26544174531', 2026),
    ('BLN', 'AK AUSSERKONTROLLE & Pashanim', 'https://p.scdn.co/mp3-preview/3d7023be549e13c9bb88ddce43cfd159f902202c', 2026),
    ('Niemand', 'Veysel', 'https://p.scdn.co/mp3-preview/220f5364f3c6e17281efc9d7ed2ca7c524dc6d99', 2025),
    ('todestrakt.wav', 'LENNSKO', 'https://p.scdn.co/mp3-preview/23ffd822a300858bde824849f2c7c51100cccb0e', 2026),
    ('Unterm Anorak', 'Soufian & SOTT', 'https://p.scdn.co/mp3-preview/7833f840e208ccfa086f8dbd4bda8020e1f0c64f', 2024),
    ('10er', 'Mucco', 'https://p.scdn.co/mp3-preview/8a6f59f6ce884c517e51afef0f9e3a48de5b0e05', 2025),
    ('M-PAKET', 'CANEY030 & LIYAN', 'https://p.scdn.co/mp3-preview/ab8305c7f56b0abc311ff77b8d4d04e4c1f5f2c6', 2026),
    ('lean back', 'BOJAN', 'https://p.scdn.co/mp3-preview/0bbf21c8b7c4a07b496281350601b4ea032c0493', 2026),
    ('ZEITPUNKT', 'RAF Camora & Kontra K', 'https://p.scdn.co/mp3-preview/a4631842a51f1aa569d9a0bb01d809378e20cdbd', 2026),
    ('PIRATE FR€€$T¥L£', 'Bonez MC, DJ MAC & CrashDummy', 'https://p.scdn.co/mp3-preview/307c42598ddb7fa72f1a7f843e041332369d1612', 2026),
    ('2Ms', 'Mucco', 'https://p.scdn.co/mp3-preview/664f3206726e87041535623103993bef891ad903', 2026),
    ('Juana auf Snapchat', 'Bobby Vandamme', 'https://p.scdn.co/mp3-preview/297becf9d9a637ebab10010ee76f667c1305b8f0', 2025),
    ('was krieg?', 'BOJAN & Kolja Goldstein', 'https://p.scdn.co/mp3-preview/7181102d152bf08ae6d809eb2b49b398b6f89361', 2026),
    ('Kreidebleich', 'Gzuz', 'https://p.scdn.co/mp3-preview/aa3714d3d2213fa55ed66dc771dfaecbc7ca6c74', 2025),
    ('Kopfsache', 'Hoti', 'https://p.scdn.co/mp3-preview/558d8d43a4110891e92823f7dd84bcdfff8eaa5b', 2026),
    ('1999', 'Mucco', 'https://p.scdn.co/mp3-preview/1d77308f1fe830f21194850a3b1b735328c9576b', 2024),
    ('Millieu 26', 'Kolja Goldstein & Eno', 'https://p.scdn.co/mp3-preview/97a674e3255376aa2941771f91a12e0e18154979', 2026),
    ('Sure Shots', 'Luciano & THIZZY52', 'https://p.scdn.co/mp3-preview/d828cc2e46ac28c03d6d2373d02f34686d51cf91', 2025),
    ('Run Run', 'Aymen', 'https://p.scdn.co/mp3-preview/4658ebebf1162ffc4269a06b5d259e93928d8230', 2025),
    ('FACECARD', 'Azu', 'https://p.scdn.co/mp3-preview/019e2f326a50f0035cca12dd8ecf3e3e14782ab9', 2025),
    ('AKRAPOVIC', 'Kurdo & MERO', 'https://p.scdn.co/mp3-preview/cdeffcfb0dc504ef4261d2b67cc6f14d86dc16a9', 2025),
    ('BIG STEPPER', 'KALIM & Shindy', 'https://p.scdn.co/mp3-preview/febc0b19bc534efeaa66a3ab0ee9c7a65ccd2e43', 2024),
    ('OUTZIDE', 'Bonez MC', 'https://p.scdn.co/mp3-preview/8008df437c3e9344b107e483e1ddaa071b26b963', 2024),
    ('XWAVE (FÜR IMMER)', 'X WAVE, BANGWHITE, GOTTI & KARDO', 'https://p.scdn.co/mp3-preview/6c1e49afcde11025a919ed5951cb738b9e31afa9', 2024)
) AS v(title, artist, url, year)
JOIN public.topic_pool tp ON tp.text = 'Deutschrap Asphalt'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Nostalgie', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Nostalgie');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at, release_year)
SELECT tp.id, v.title, v.artist, v.url, now(), v.year
FROM (VALUES
    ('Neymar', 'Capital Bra & Ufo361', 'https://p.scdn.co/mp3-preview/bdc9b235c557675826f0688127338b9328538146', 2019),
    ('Mörder', 'Bonez MC, RAF Camora & Gzuz', 'https://p.scdn.co/mp3-preview/6857cf03bf7cf35a70e928a61534f020f8f82c5d', 2016),
    ('Heute mit mir', 'Nimo', 'https://p.scdn.co/mp3-preview/e32fbe94a156a3db1e58c34673311660c8a10238', 2017),
    ('Palmen aus Plastik', 'Bonez MC & RAF Camora', 'https://p.scdn.co/mp3-preview/890301dbc94f7d04096bd1e81830a94a53bc2219', 2016),
    ('Ohne mein Team', 'Bonez MC, RAF Camora & Maxwell', 'https://p.scdn.co/mp3-preview/8af37c32e0701141167afd5d834d2372cc7569a7', 2016),
    ('Dior 2001', 'RIN', 'https://p.scdn.co/mp3-preview/eaef1a7fec7565f53723ae081ab7b4330b5c9853', 2018),
    ('Nice Girl 2.0', 'Ufo361', 'https://p.scdn.co/mp3-preview/c44c228b274ce094adeaa83c4a7226e548db56b9', 2017),
    ('Casanova', 'Summer Cem & Bausa', 'https://p.scdn.co/mp3-preview/a35f80d08005e2efcd39c40c725214cbb91d56e4', 2018),
    ('500 PS', 'Bonez MC & RAF Camora', 'https://p.scdn.co/mp3-preview/71bea24a593ebdac5e2e23cd65adbf0fcfc68bb0', 2018),
    ('Bon Voyage', 'Miami Yacine', 'https://p.scdn.co/mp3-preview/caea0ef9eca269fc87bb5acc6d10cb2d13a70ec0', 2017),
    ('Sex ohne Grund', 'Ali Bumaye & Shindy', 'https://p.scdn.co/mp3-preview/bd77d68cf5ab1e15a8e956ec34f623f0f895de71', 2016),
    ('Kokaina', 'Miami Yacine', 'https://p.scdn.co/mp3-preview/4a3978a8655a434b4150ee9fd3426e6281849da9', 2017),
    ('Murcielago', 'KC Rebell & Summer Cem', 'https://p.scdn.co/mp3-preview/dc2d27c663f61580541412675413fcab034cd3c8', 2017),
    ('Nummer 1', 'Zuna, Azet & Noizy', 'https://p.scdn.co/mp3-preview/161bd748a860d225075ea8a8d7ef367a6c0ff783', 2017),
    ('Millionär', '187 Strassenbande, Bonez MC & Gzuz', 'https://p.scdn.co/mp3-preview/7e5cc5c23f577cb81a5076091b7f3400bfcea4cd', 2017),
    ('Von Party zu Party', 'SXTN', 'https://p.scdn.co/mp3-preview/014c0f030d9cfbee5e18c63b347dea02aef938b7', 2017),
    ('Bongzimmer', 'SXTN', 'https://p.scdn.co/mp3-preview/5b93180a0e160cffa72ce734b642856fcd397806', 2017),
    ('An ihnen vorbei', 'Bonez MC & RAF Camora', 'https://p.scdn.co/mp3-preview/8cfec5b336031ff181179c0c5e3604f7066409d5', 2016),
    ('Kontrollieren', 'RAF Camora, Bonez MC, Gzuz & Maxwell', 'https://p.scdn.co/mp3-preview/4b4c384137f054555ce2b0ae7ed4d33661174a87', 2017),
    ('Monsta', 'Culcha Candela', 'https://p.scdn.co/mp3-preview/7c6ea0eedecbc4188c5cf42fdf573202969abce7', 2019),
    ('Berlin City Girl', 'Culcha Candela', 'https://p.scdn.co/mp3-preview/4b3c8779a5602a2bef6ef899bca7904bb94f1a6b', 2010),
    ('Wildes Ding', 'Culcha Candela', 'https://p.scdn.co/mp3-preview/fbc3d804a06932b9bff0fd232ea45049ecc57949', 2021),
    ('Jim Beam & Voddi', 'AK AUSSERKONTROLLE & Bonez MC', 'https://p.scdn.co/mp3-preview/1ecb14f94d0a138db850ff1c4b546e0504a6a261', 2017),
    ('Leck Sibbi', 'Nimo', 'https://p.scdn.co/mp3-preview/87b1ba56bc508f8a8852968f9310bfb4e6fb326f', 2024),
    ('Fotzen im Club', 'SXTN', 'https://p.scdn.co/mp3-preview/2e9bf5b3ba213ee617fc9b7d7eb965b6c0c0793a', 2016),
    ('Was du Liebe nennst', 'Bausa', 'https://p.scdn.co/mp3-preview/c3b919311e8866f2a8f5ed0fb03b953ca13a1583', 2017),
    ('Magisch', 'Olexesh & Edin', 'https://p.scdn.co/mp3-preview/45b0328720765b9a8ba29bee06781d3aecca02f3', 2018),
    ('Lambo Diablo GT', 'CAPO & Nimo', 'https://p.scdn.co/mp3-preview/9b9297c6f42b5571153f5508659ae301e766f23d', 2017),
    ('Besser als 50 Cent', 'Veysel', 'https://p.scdn.co/mp3-preview/26387e8bf7b19612fc83a4372467fcbac0872385', 2018),
    ('Telefon', 'Dardan & Nimo', 'https://p.scdn.co/mp3-preview/5afb7efaa2040ec67e7f3354249a0357a6435c93', 2018),
    ('5 Songs in einer Nacht', 'Capital Bra', 'https://p.scdn.co/mp3-preview/04c916786442bf68b06eb9684320335cbbd4c466', 2019),
    ('One Night Stand', 'Capital Bra', 'https://p.scdn.co/mp3-preview/778056de839c4089f3e4b85db994f90858344215', 2019),
    ('Melodien', 'Capital Bra & Juju', 'https://p.scdn.co/mp3-preview/9536b8a950ca324e519fe1d623e68e51e820418e', 2018),
    ('BONNIE & CLYDE', 'Loredana & Mozzik', 'https://p.scdn.co/mp3-preview/722325b3a156402bedd58cad616f632455acd88d', 2018),
    ('Ich liebe es', 'Capital Bra, XATAR & SAMY', 'https://p.scdn.co/mp3-preview/a7b793684fab53c6b494da926ef8a0ba919062fc', 2019),
    ('Benzema', 'Capital Bra', 'https://p.scdn.co/mp3-preview/81bfbbc19bec22d3f40514a99b4f450d7bb5754a', 2018),
    ('DNA', 'KC Rebell, Summer Cem & Capital Bra', 'https://p.scdn.co/mp3-preview/77e112ef5b4d78b0b7128b9fd00a8e6300b04ba7', 2019),
    ('Alleen', 'KC Rebell', 'https://p.scdn.co/mp3-preview/fe8d6fff3c9fb935e573b5641a99a271a99d53de', 2019),
    ('Rolex', 'Capital Bra, Summer Cem & KC Rebell', 'https://p.scdn.co/mp3-preview/3230e8da363f78601e2274b192c9163e2c7d5a2e', 2019),
    ('Wieder Lila', 'Samra & Capital Bra', 'https://p.scdn.co/mp3-preview/5113390dbba06fee92545b5173bda19f785f1d62', 2019),
    ('Tilidin', 'Capital Bra & Samra', 'https://p.scdn.co/mp3-preview/9c8d6104a771711ca20a59293cf292969ad6e752', 2019),
    ('La Haine', 'Luciano', 'https://p.scdn.co/mp3-preview/4c41beaeba7f73f9176b9d95c6cf334a555d865d', 2019),
    ('Barrio', 'Olexesh', 'https://p.scdn.co/mp3-preview/0618dcd8483048c525e1f3465571870dde65fc33', 2019),
    ('Cataleya', 'Samra', 'https://p.scdn.co/mp3-preview/4c7d16761491a9611f865bc46b55fd07e851fccc', 2018),
    ('Allein', 'Capital Bra', 'https://p.scdn.co/mp3-preview/284867c3417ba95ac20a6ab924d6236e0e925709', 2019),
    ('Ewigkeit', 'Majoe', 'https://p.scdn.co/mp3-preview/5beeca02e6b00f3b47f4df2cefe036bcc8fa45b5', 2018),
    ('Ein Teil von mir', 'MC Bilal', 'https://p.scdn.co/mp3-preview/68288ba98719262217cdea2c9862337f1dfff1b3', 2019),
    ('Liebe tut weh', 'MC Bilal', 'https://p.scdn.co/mp3-preview/a2dab95ff90aed53d19472378c6c2fbc8de3cd86', 2019),
    ('Prinzessa', 'Capital Bra', 'https://p.scdn.co/mp3-preview/0658081238fb9b6e17c3b7bf861c3cc382475375', 2019),
    ('Standard', 'KITSCHKRIEG, SFR, Trettmann, Gzuz, GRiNGO & Ufo361', 'https://p.scdn.co/mp3-preview/0f4b40a394ab7feb275c19ef64857a1b72b68dab', 2026),
    ('Nummer unterdrückt', 'Bonez MC & RAF Camora', 'https://p.scdn.co/mp3-preview/efe9a4f22bd3fa1148131b871630089dab73a282', 2018),
    ('Kokain', 'Bonez MC, RAF Camora & Gzuz', 'https://p.scdn.co/mp3-preview/2355bf5500b4216d7da962312e2e9bddd917111c', 2018),
    ('UFF', 'Veysel & Gzuz', 'https://p.scdn.co/mp3-preview/6326394de6fd9a4e945ef3be36a3c54513332fac', 2018),
    ('Perfekt', 'RAF Camora, AriBeatz & Sofiane', 'https://p.scdn.co/mp3-preview/6950c199123274d118c13d18e31c6b75736f62a2', 2012),
    ('Vagabund', 'Bausa', 'https://p.scdn.co/mp3-preview/a291e6525deeda5fa10db8f6356fcea05117d52e', 2018),
    ('Alien', 'Bonez MC & RAF Camora', 'https://p.scdn.co/mp3-preview/87ef1346eded9d701828fbb572e9bad79b537d39', 2018),
    ('Habibo', 'Veysel', 'https://p.scdn.co/mp3-preview/0d6d3ee47e24cc33a238d4db1023e81ec389fc27', 2018),
    ('Ballin', 'Luciano', 'https://p.scdn.co/mp3-preview/4a2c7579434ebf3715dfc250a5db17c75e9a439a', 2018),
    ('Toto', 'Noizy & RAF Camora', 'https://p.scdn.co/mp3-preview/9defae6945dc62806a6f15220d98f0eb6b533ff1', 2018),
    ('Kleiner Cabrón', 'Veysel', 'https://p.scdn.co/mp3-preview/0ae93c4bab1264cf5ba3d959caa0f557d9c2db94', 2018),
    ('iPhone 17', 'KC Rebell & Moe Phoenix', 'https://p.scdn.co/mp3-preview/569c6c778a6357b6143e2f33a81b921bef7df55c', 2016),
    ('Ti amo', 'Veysel & Mozzik', 'https://p.scdn.co/mp3-preview/0a6b94d97215098369fe81dd3de183e90dc5cd78', 2018),
    ('Bist Du real', 'KC Rebell & Moe Phoenix', 'https://p.scdn.co/mp3-preview/d562adc2bb41466999ba5422c5a5d5f9321e70f0', 2015),
    ('Augenblick', 'KC Rebell & Summer Cem', 'https://p.scdn.co/mp3-preview/f6d858748c304d81760c0f52315e1fd83e3cfd33', 2015),
    ('Blaues Licht', 'RAF Camora & Bonez MC', 'https://p.scdn.co/mp3-preview/b08ce978d1e52efcd2f62d0c5737a6685b1db875', 2021),
    ('Du liebst mich nicht', 'Ado Kojo & Shirin David', 'https://p.scdn.co/mp3-preview/e28e568a544b69a1546bed39c0992ef0cb47f620', 2015),
    ('Kartell', 'Zuna, Azet & Nash', 'https://p.scdn.co/mp3-preview/3b461ff8fbedb7f7a8c11c06a565f45e3dd20f1c', 2016),
    ('In meinem Benz', 'AK AUSSERKONTROLLE & Bonez MC', 'https://p.scdn.co/mp3-preview/1a994917cc78731ed688e1a0e75664ce9d77deba', 2020),
    ('Monica Bellucci', 'RIN', 'https://p.scdn.co/mp3-preview/aee8682f603dcf54124cbb200e0323f619881683', 2018),
    ('KEIN SCHLAF', 'Nimo & Hava', 'https://p.scdn.co/mp3-preview/bd24e1dae3cf4d5ed760b9be220f6111265952d9', 2019),
    ('Trippin’', 'Luciano', 'https://p.scdn.co/mp3-preview/405abbd20e25f433040095c2908733c294a18c9c', 2020),
    ('So wie du bist', 'MoTrip & Lary', 'https://p.scdn.co/mp3-preview/7a8d0f24bd8b2c9a5f7b4ccafda4e2faa5ebd3ec', 2015),
    ('Immer wieder', 'Rooz & MoTrip', 'https://p.scdn.co/mp3-preview/c0ffaa6f09d8c72831fe09ab8e7a36418b58733c', 2018),
    ('Trance', 'QZENG', 'https://p.scdn.co/mp3-preview/900d86619135757b760d74fc9f1703838daa4eb5', 2020),
    ('Meer', 'Luciano', 'https://p.scdn.co/mp3-preview/4053925c4ef54f6ba11f6c2574381f071862ce57', 2018),
    ('Heroin', 'Ali As & Juju', 'https://p.scdn.co/mp3-preview/530de8d9b3354996507d751726c1cebd6ab24d87', 2018),
    ('HIGHWAY', 'Edo Saiya', 'https://p.scdn.co/mp3-preview/412319043d3f2c30be43c01f179d9b89af543d8d', 2019),
    ('Da für dich', 'Eddin', 'https://p.scdn.co/mp3-preview/8cd070684d659d3b2ad935d76a320db2335d910f', 2019),
    ('Purple Rain', 'Capital Bra, Samra & SANTOS', 'https://p.scdn.co/mp3-preview/8388f2d55a1c83422571df9a4b986fb82bce2477', 2019),
    ('04:30', 'Ufo361', 'https://p.scdn.co/mp3-preview/12b8096b24e4d6d8bad6c807b5d3b0a7210d389e', 2019),
    ('Adriana', 'RAF Camora', 'https://p.scdn.co/mp3-preview/baa0045018cf8c8a1b4cc77106cab9e8444537a6', 2019),
    ('Ich müsste lügen', 'Juju', 'https://p.scdn.co/mp3-preview/6bd068f882408d7b7d9fc71ca921e8e0700bd895', 2019),
    ('Lieber Gott', 'Capital Bra & Samra', 'https://p.scdn.co/mp3-preview/dc25f0437c210948bdc0c2b0abe3ab6e0a95e23e', 2019),
    ('Hi Babe', 'Juju', 'https://p.scdn.co/mp3-preview/75a915af41a820ff26c6e104b1492217d439d354', 2019),
    ('Keine Liebe', 'RIN & Bausa', 'https://p.scdn.co/mp3-preview/b06aea2233019cce112de6591200420c9df18bf8', 2019),
    ('Vermissen', 'Juju & Henning May', 'https://p.scdn.co/mp3-preview/ee1e7c06a9984fe0c13235afbbe7ffcc6ac3b36c', 2019),
    ('KARMA', 'Nimo', 'https://p.scdn.co/mp3-preview/07a64372737468d24b5d283fbbfaf4cf37765b73', 2019),
    ('110', 'Capital Bra, Samra & LEA', 'https://p.scdn.co/mp3-preview/03961f905c0d800d5e9b0ced4ffffe61d62b891f', 2019),
    ('Seele', 'Azet', 'https://p.scdn.co/mp3-preview/c8d5c90956e2142df12a499096385c656e7c8144', 2019)
) AS v(title, artist, url, year)
JOIN public.topic_pool tp ON tp.text = 'Nostalgie'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'ICON 5', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'ICON 5');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at, release_year)
SELECT tp.id, v.title, v.artist, v.url, now(), v.year
FROM (VALUES
    ('Generation', 'MADE, BARÉ, SHABAB, Azu, Bayor, Biggie68 & Skandal', 'https://p.scdn.co/mp3-preview/b38a7c69103fb2d826eb9bddabbae2a74bd3ae33', 2023),
    ('Koka Shem', 'MADE, Bayor, Rasa, Skandal, SHABAB & BARÉ', 'https://p.scdn.co/mp3-preview/77ab4ffba7e1155479d25831fdc824a98ae9a359', 2023),
    ('Toto', 'MADE, Hassuna, Biggie68 & VITO', 'https://p.scdn.co/mp3-preview/a43f8bde9294bc29aae0219337fc6ce1005e8de3', 2023),
    ('Interpol', 'MADE & Kenan', 'https://p.scdn.co/mp3-preview/d9575cbc5495250caa4847086bdc77138b359a2b', 2023),
    ('Maradonna', 'MADE, Skandal & Kenan', 'https://p.scdn.co/mp3-preview/1607f68f80b0172fbdb58c015d66408682d0950a', 2023),
    ('Pelé', 'MADE & Hassuna', 'https://p.scdn.co/mp3-preview/183da7ae9264aa76653ddcda9c6666498b6ff9a8', 2023),
    ('PROZENTE', 'Hassuna', 'https://p.scdn.co/mp3-preview/cf009d34a446f0e42233855d3c45415420932669', 2024),
    ('Amiga', 'MADE, VITO, Kenan & SHABAB', 'https://p.scdn.co/mp3-preview/a82699b3c1efb771f5a836d9861e87aa9dc21900', 2023),
    ('RS Coupé', 'MADE & SHABAB', 'https://p.scdn.co/mp3-preview/09d12c035a7ce76b95417949964d829891505701', 2023),
    ('Sonnentanz', 'MADE, BARÉ, SHABAB & Bayor', 'https://p.scdn.co/mp3-preview/853563cdd11a3ee33faf4d5dcac90137c084ba30', 2023),
    ('Mi Amor', 'MADE, SHABAB & Azu', 'https://p.scdn.co/mp3-preview/7bf7ee79b8284b706cfa7cdb13287db400aab9c2', 2023),
    ('À la Carte', 'MADE, SHABAB & Rasa', 'https://p.scdn.co/mp3-preview/75ba41ab3923b2ef125f1312e9b69928ffcf93ad', 2023),
    ('Niagara', 'MADE & SHABAB', 'https://p.scdn.co/mp3-preview/3bbcf83cf38a8918bd3830c8aa8e98d358bddec4', 2023),
    ('Bandolero', 'MADE, Azu & Bayor', 'https://p.scdn.co/mp3-preview/f3ebdf2abd7c1eddeb4ce2f60c9a93aafe6273c8', 2023),
    ('Skandal', 'MADE & Skandal', 'https://p.scdn.co/mp3-preview/2a3e71ae02a6f3116bf7e334293a59e098b33f0a', 2024),
    ('C''est la vie', 'MADE & Mufasa069', 'https://p.scdn.co/mp3-preview/f68af0cb5ab8b8220638f8968798fdc9eaf79d97', 2023),
    ('Favela', 'MADE, Hassuna, Azu, Biggie68, VITO & SHABAB', 'https://p.scdn.co/mp3-preview/f3df26b97654e0a364be77cfa3f0753d6b34c92d', 2023),
    ('NuR Du :/', 'Lune & SHABAB', 'https://p.scdn.co/mp3-preview/c7490d780ba6d48d7849b3c538800801eedba48b', 2024),
    ('Brazil Funk Freestyle 🇧🇷', 'Bobby Vandamme', 'https://p.scdn.co/mp3-preview/9bd79871122b8a7d1bdd4e04bcf787760d180a51', 2023),
    ('Beluga', 'MADE, Bayor, BARÉ & Kenan', 'https://p.scdn.co/mp3-preview/7fa5e3ba3f6d8513a8aaf5aaa6759a5498b5df7a', 2023),
    ('PITAYA', 'SHABAB', 'https://p.scdn.co/mp3-preview/4e95cff6d3eeb2c0c6f045a1fb45598d9261ac20', 2024),
    ('Wesh Bira Freestyle', 'MADE & OZAN BRA', 'https://p.scdn.co/mp3-preview/9dd1d3be0030befb82809a56dbb22cf0171a342c', 2024)
) AS v(title, artist, url, year)
JOIN public.topic_pool tp ON tp.text = 'ICON 5'
WHERE NOT EXISTS (
  SELECT 1 FROM public.song_pool s WHERE s.topic_pool_id = tp.id AND lower(s.title) = lower(v.title)
);

COMMIT;
