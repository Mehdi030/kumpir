-- Migration 069: falsche Song-Previews entfernt + Playlists aufgefüllt
-- Audit (db/scripts/audit-previews.mjs): bei 16 alten Songs (Deutschrap-Songs, Shisha Club)
-- spielte die Preview einen ANDEREN Titel. Entfernt; beide Playlists mit iTunes-verifizierten,
-- bekannten Titeln wieder auf >= 30 aufgefüllt.
BEGIN;
DELETE FROM public.song_pool WHERE id IN ('1515b6ea-6263-4f3a-bedb-64a55ae169c8','75ed00ee-a115-4281-9cb2-d38e75067259','9c40fb11-d0b2-4b25-8ed0-ea2179c51feb','d359bfac-6064-47fa-abc7-59ba96392e1a','789ce9c7-3ed3-482d-a691-742f402171c7','ef1c4a52-d0c7-4117-81f7-d0f8b3ae6982','32d1822f-d5a9-4b74-a18f-b6ebb1b976a0','23035edd-146e-4e99-ab2d-78d7d27a6f9a','251411b7-753f-4887-ae07-53faa5642ea6','7957f0bf-3b58-4404-a9b8-e3535d420b72','5c1ae52d-8dce-4c01-8f18-d2ad524e3600','2c75d371-5c0d-471e-9afc-b9451f3a5384','1decddaa-7480-4790-9f7a-acc711c6ed62','1454d246-6bff-4132-a0b7-3a188e5b4b07','17b395b0-89b9-4767-8759-b13c331bf3de','9df1a008-253e-404c-bbd4-7e674f9eb742','ae8d9b5f-a491-4e78-a04b-c1a5c43e55b8');

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Deutschrap-Songs', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Deutschrap-Songs');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Deutschrap-Songs', 'Hi Kids', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/97/66/25/976625d2-e1ee-91a3-00e2-caf8a930f0a5/mzaf_15887768229262030255.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Einmal um die Welt', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/12/c6/70/12c6701a-294e-50d1-a490-d2a3bd91ffa9/mzaf_15225202634199766013.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Bye Bye', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/07/19/d6/0719d63e-7b50-10aa-dbda-ffebac3f9b57/mzaf_11760575587449635273.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Melodie', 'Cro', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/5b/1a/4f/5b1a4f4f-b861-b104-f816-deab8cb8c1da/mzaf_7631167956273878838.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Neymar', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/a7/69/de/a769de2c-18d6-064c-04e2-e82d96ea9225/mzaf_5362429075520904707.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Bläulich', 'Apache 207', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f2/27/a6/f227a6ef-b6f2-de0b-8060-e0e5a29ba4fa/mzaf_7106802513914058652.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Electro Ghetto', 'Bushido', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/d7/9f/08/d79f0869-01a5-1db5-d414-8381ce4045ee/mzaf_17757541506833908075.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Welt der Wunder', 'Marteria', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/3f/93/01/3f93014d-a17c-f4a0-046d-cd6802b0187b/mzaf_16721263306747837763.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'XOXO', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ec/88/b2/ec88b2bb-9b5a-a723-4591-1d4841837ae5/mzaf_10971516685321414190.plus.aac.p.m4a'),
    ('Deutschrap-Songs', 'Im Ascheregen', 'Casper', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview125/v4/bc/06/09/bc060979-868b-0cb8-d605-9e298808693f/mzaf_7632267496433031349.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Shisha Club', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Shisha Club');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Shisha Club', 'Kein Plan', 'Loredana', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/94/ce/5b/94ce5be4-d487-19ba-b376-a60d38954fd0/mzaf_17595214646994012332.plus.aac.p.m4a'),
    ('Shisha Club', 'Papaoutai', 'Stromae', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/f5/74/17/f5741739-6e4a-22d1-7d1c-fb1d83cd48fa/mzaf_7090140597883469797.plus.aac.p.m4a'),
    ('Shisha Club', 'Alors on danse', 'Stromae', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/87/84/ae/8784ae2b-8e39-0053-23ad-940bf2f69d87/mzaf_16356168226426243495.plus.aac.p.m4a'),
    ('Shisha Club', 'Djadja', 'Aya Nakamura', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/ff/c1/fa/ffc1faa2-506d-4c5b-3e09-b7067959adf3/mzaf_3563312867774255295.plus.aac.p.m4a'),
    ('Shisha Club', 'Dernière Danse', 'Indila', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/c6/c0/a7/c6c0a7a9-8e64-11d2-1146-5103b1c07004/mzaf_12112688470040263229.plus.aac.p.m4a'),
    ('Shisha Club', 'Despacito', 'Luis Fonsi', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/46/42/db/4642db8f-13f6-457d-bd3e-1d9c22654ace/mzaf_16062777735482664257.plus.aac.p.m4a'),
    ('Shisha Club', 'Mi Gente', 'J Balvin', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/71/1f/14/711f149d-9843-7d00-0092-eac653a1e014/mzaf_2844927362482586540.plus.aac.p.m4a'),
    ('Shisha Club', 'Danza Kuduro', 'Don Omar', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/08/40/df/0840df61-1e6d-c985-1136-500dd9e09cc5/mzaf_13424326045030692319.plus.aac.p.m4a'),
    ('Shisha Club', 'Gasolina', 'Daddy Yankee', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/80/a6/9f/80a69fdc-b334-a648-6efc-6f57a60782c0/mzaf_18210801488139650311.plus.aac.p.m4a'),
    ('Shisha Club', 'Bailando', 'Enrique Iglesias', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/a7/6d/a1/a76da115-ae3f-2d54-0f90-cfd006d8db4e/mzaf_18397821616695221456.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

COMMIT;
