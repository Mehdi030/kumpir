-- Migration 068: Shisha Club auf 30 Titel aufgefüllt (iTunes-verifiziert)
-- Generiert von db/scripts/build-playlists.mjs (iTunes-verifiziert: Titel+Interpret+Preview)
BEGIN;

INSERT INTO public.topic_pool (text, active, is_song_category)
SELECT 'Shisha Club', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.topic_pool WHERE text = 'Shisha Club');

INSERT INTO public.song_pool (topic_pool_id, title, artist, preview_url, preview_checked_at)
SELECT tp.id, v.title, v.artist, v.url, now()
FROM (VALUES
    ('Shisha Club', 'Cherry Lady', 'Capital Bra', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/58/59/26/5859264e-97ce-0eee-7ee2-0fc252394323/mzaf_6696924934051821960.plus.aac.p.m4a'),
    ('Shisha Club', 'Airwaves', 'Pashanim', 'https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/51/41/f2/5141f286-b3bd-3318-89cf-a6ccb98cccb4/mzaf_7876580721373569987.plus.aac.p.m4a')
) AS v(topic, title, artist, url)
JOIN public.topic_pool tp ON tp.text = v.topic;

COMMIT;
