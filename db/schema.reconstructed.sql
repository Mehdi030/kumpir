-- ============================================================
-- KUMPIR — Rekonstruiertes Schema
-- ============================================================
-- Basis: alle .from(...) und .select(...) Aufrufe im Frontend-Code.
-- Spaltentypen sind GESCHÄTZT — bitte mit `supabase db dump` ersetzen.
-- ============================================================

-- ------------------------------------------------------------
-- ENUMs / Domains (vermutet, ggf. via CHECK constraints umgesetzt)
-- ------------------------------------------------------------

-- lobby.phase wird im Code als String behandelt mit diesen Werten:
--   'waiting' | 'lobby' | 'topic_vote' | 'countdown' | 'running' | 'finished'

-- lobby.game_mode:
--   'original' | 'teleport' | 'reverse' | 'last_clock_standing' | 'topic_shuffle'

-- lobby.round_speed (vermutet, vielleicht als round_seconds INT gespeichert):
--   'fast' | 'normal' | 'calm'

-- lobby.privacy:
--   'private' | 'public'

-- player.status:
--   'active' | 'left' | 'kicked'

-- topic_votes.choice:
--   1 (= topic_a) | 2 (= topic_b) | 3 (= random)


-- ------------------------------------------------------------
-- Tabelle: lobbies
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lobbies (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code                    TEXT NOT NULL UNIQUE,            -- 4-stelliger Lobby-Code, A-Z 0-9
    host_player_id          UUID,                            -- FK → players.player_id
    phase                   TEXT NOT NULL DEFAULT 'lobby',
    privacy                 TEXT NOT NULL DEFAULT 'private',
    locked                  BOOLEAN NOT NULL DEFAULT FALSE,
    max_players             SMALLINT NOT NULL DEFAULT 8,
    game_mode               TEXT NOT NULL DEFAULT 'original',
    round_speed             TEXT,                            -- 'fast' | 'normal' | 'calm'
    round_seconds           SMALLINT,                        -- aus rpc_create_lobby param
    topic                   TEXT,                            -- vom Host gesetzt, optional

    -- Running phase state
    holder_player_id        UUID,                            -- aktueller Halter der Kartoffel
    explode_at              TIMESTAMPTZ,                     -- Zeitpunkt der Explosion
    run_started_at          TIMESTAMPTZ,
    last_activity_at        TIMESTAMPTZ,
    round_number            INTEGER DEFAULT 0,
    last_loser_player_id    UUID,

    -- Topic voting state
    topic_a                 TEXT,
    topic_b                 TEXT,
    topic_selected          TEXT,
    topic_vote_ends_at      TIMESTAMPTZ,
    countdown_started_at    TIMESTAMPTZ,
    countdown_ends_at       TIMESTAMPTZ,
    topic_tie_choices       INTEGER[],                       -- bei Gleichstand: [1,2] o.ä.
    topic_tie_pick          INTEGER,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lobbies_code ON public.lobbies (code);
CREATE INDEX IF NOT EXISTS idx_lobbies_phase ON public.lobbies (phase);


-- ------------------------------------------------------------
-- Tabelle: players
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.players (
    player_id           UUID NOT NULL,                       -- client-generierte UUID
    lobby_id            UUID NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    ready               BOOLEAN NOT NULL DEFAULT FALSE,
    status              TEXT NOT NULL DEFAULT 'active',      -- 'active' | 'left' | 'kicked'
    seat_index          SMALLINT NOT NULL DEFAULT 0,         -- Position im Ring
    is_alive            BOOLEAN NOT NULL DEFAULT TRUE,

    joined_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- via rpc_heartbeat

    -- Stats (akkumuliert über die ganze Partie)
    last_pass_at        TIMESTAMPTZ,
    pass_count          INTEGER NOT NULL DEFAULT 0,
    clutch_pass_count   INTEGER NOT NULL DEFAULT 0,          -- "knapp gepasst" — < 1s vor explode_at
    fastest_pass_ms     INTEGER,
    total_hold_ms       INTEGER NOT NULL DEFAULT 0,
    survival_streak     INTEGER NOT NULL DEFAULT 0,

    PRIMARY KEY (lobby_id, player_id)
);

CREATE INDEX IF NOT EXISTS idx_players_lobby ON public.players (lobby_id);
CREATE INDEX IF NOT EXISTS idx_players_lobby_status ON public.players (lobby_id, status);


-- ------------------------------------------------------------
-- Tabelle: topic_votes
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.topic_votes (
    lobby_id    UUID NOT NULL REFERENCES public.lobbies(id) ON DELETE CASCADE,
    player_id   UUID NOT NULL,
    choice      SMALLINT NOT NULL CHECK (choice IN (1, 2, 3)),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (lobby_id, player_id),
    FOREIGN KEY (lobby_id, player_id) REFERENCES public.players(lobby_id, player_id) ON DELETE CASCADE
);


-- ------------------------------------------------------------
-- Tabelle: profiles  (für authentifizierte User, optional)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username    TEXT NOT NULL UNIQUE,                       -- gleichnamiges UNIQUE Index
    email       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS profiles_username_unique ON public.profiles (LOWER(username));


-- ============================================================
-- Foreign Keys, die wir nachträglich ergänzen
-- ============================================================
-- (lobbies.host_player_id verweist auf players, aber die Tabelle muss erst existieren)

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.referential_constraints
        WHERE constraint_name = 'lobbies_host_player_id_fk'
    ) THEN
        ALTER TABLE public.lobbies
            ADD CONSTRAINT lobbies_host_player_id_fk
            FOREIGN KEY (host_player_id, id)
            REFERENCES public.players(player_id, lobby_id)
            DEFERRABLE INITIALLY DEFERRED;
    END IF;
END $$;
