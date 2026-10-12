-- ============================================================
-- 099: Feature-Partner der Songs (2026-10-12, Daten)
-- ============================================================
-- Beim Playlist-Bau wurde "(feat. X & Y)" aus dem Titel entfernt -> X/Y wurden als Antwort nicht erkannt.
-- Erzeugt von db/scripts/fetch-features.mjs (iTunes, eindeutig über die Hörproben-Adresse zugeordnet).
-- 30 Songs mit Feature-Partnern; die übrigen Mitwirkenden stehen schon im Künstlerfeld.
-- ============================================================
BEGIN;

UPDATE public.song_pool s
SET feat_artists = v.feat
FROM (VALUES
  ('6ddc7b0c-4ad5-45f4-973e-059dee4de8fd'::uuid, ARRAY['Summer Cem']::text[]),
  ('d5e065f9-1a6e-4173-9a33-4d29eea41ba6'::uuid, ARRAY['Capital Bra']::text[]),
  ('f771c79a-f694-4f22-9342-e0194822122d'::uuid, ARRAY['A-SHO']::text[]),
  ('e4469b79-d930-4682-a57c-1bf354921e1b'::uuid, ARRAY['reezy']::text[]),
  ('d97e8ff3-41ce-449e-9c83-93b846e05f05'::uuid, ARRAY['Nimo']::text[]),
  ('f26ef81f-903d-4fa0-ac32-e5e24ddd1db0'::uuid, ARRAY['SSIO']::text[]),
  ('68db1bee-e038-4ae8-ad06-b8402b2ce52f'::uuid, ARRAY['Veysel']::text[]),
  ('404ee4be-8531-40bc-ab2a-7182f09b2974'::uuid, ARRAY['Summer Cem', 'Capital Bra']::text[]),
  ('cb275f6d-b48a-412a-94b5-c3ee8468b569'::uuid, ARRAY['AkssiR']::text[]),
  ('400bf1a8-5964-4f9b-aa46-c4a72e92d88c'::uuid, ARRAY['Capo', 'Ufo361']::text[]),
  ('ede54892-e806-4494-8099-6c8cdba0b717'::uuid, ARRAY['Cro']::text[]),
  ('a4ce1bb6-26dc-45cc-99f0-b8073677a633'::uuid, ARRAY['Loredana']::text[]),
  ('f75bf809-9673-4679-b175-6594c1c44cfb'::uuid, ARRAY['Samra', 'Capital Bra']::text[]),
  ('dabf09a3-0d2b-467c-9c31-e0d2a8afb453'::uuid, ARRAY['XATAR', 'Samy']::text[]),
  ('7ba28e1f-afe4-4db5-bc7b-6ed803d7c003'::uuid, ARRAY['Moé']::text[]),
  ('28f52a29-5d22-4d8c-bcd4-23f4f4a0f848'::uuid, ARRAY['Capital Bra']::text[]),
  ('82b8228e-aaf9-4d92-aa99-991a798bb8c1'::uuid, ARRAY['Lil Lano']::text[]),
  ('a257d585-fb32-4766-8e48-ae2dff580623'::uuid, ARRAY['LINAA']::text[]),
  ('3a31925f-d716-48d9-972a-0256b729b9fb'::uuid, ARRAY['RYCH']::text[]),
  ('89493424-f80c-4e1e-997d-4d3d4cca4555'::uuid, ARRAY['Juju']::text[]),
  ('0f0fb1d7-69b9-4438-afac-c8fbf6f1efd9'::uuid, ARRAY['Celo', 'Abdi']::text[]),
  ('6efa967a-60ed-4666-935c-2dd818ad7e89'::uuid, ARRAY['Sofiane']::text[]),
  ('ce93fbe8-3eca-44bd-9c05-c839540c246a'::uuid, ARRAY['Summer Cem', 'KC Rebell']::text[]),
  ('5c6707b0-e8fb-4145-8832-14235f7296f8'::uuid, ARRAY['Luciano', 'Eno']::text[]),
  ('83e8add9-5efe-4c94-a4da-ebe8477f36c3'::uuid, ARRAY['Capo', 'Rick Ross']::text[]),
  ('dade6a46-f938-4f8a-982e-362a0f3acd40'::uuid, ARRAY['LX']::text[]),
  ('dc9684be-1046-47ee-a603-b3692ee0055e'::uuid, ARRAY['Luciano']::text[]),
  ('931172fb-7078-4dd6-a96c-011573ce3185'::uuid, ARRAY['Hanybal']::text[]),
  ('fde7e590-0619-4f5f-bb08-0d7cce44f3c8'::uuid, ARRAY['Majoe']::text[]),
  ('668ecdb6-93e1-423a-9119-743982b3d3d2'::uuid, ARRAY['Faroon']::text[])
) AS v(id, feat)
WHERE s.id = v.id;

COMMIT;
