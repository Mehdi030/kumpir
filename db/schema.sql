-- ============================================================
-- KUMPIR — Echtes Schema (gedumpt aus Supabase)
-- Ursprünglicher Dump: 2026-05-11 — manuell nachgeführt bis inkl.
-- Migration 030 (Stand 2026-09-29). Nach jedem neuen `db/migrations/NNN_*.sql`
-- bitte diese Datei von Hand (oder per neuem Dump) auf den gleichen Stand
-- bringen, sonst driftet sie wieder auseinander wie zwischen 2026-05-11
-- und Migration 001/005/008 (siehe unten).
-- ============================================================
-- Quelle: User-Dump via SQL-Editor Query 1 aus db/HOW_TO_DUMP.md
-- Diese Datei ist die WAHRHEIT (so weit sie aktuell gehalten wird).
-- db/schema.reconstructed.sql kann gelöscht werden.
-- ============================================================

CREATE TABLE game_run_eliminations (
    run_id uuid NOT NULL,
    eliminated_player_id uuid NOT NULL,
    eliminated_at timestamp with time zone NOT NULL DEFAULT now(),
    round_number integer
);

CREATE TABLE game_run_players (
    run_id uuid NOT NULL,
    player_id uuid NOT NULL,
    name text NOT NULL,
    seat_index integer
);

CREATE TABLE game_runs (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    lobby_id uuid NOT NULL,
    started_at timestamp with time zone NOT NULL DEFAULT now(),
    finished_at timestamp with time zone,
    topic_selected text,
    winner_player_id uuid,
    players_count integer
);

CREATE TABLE kv_store_8e1b0e4b (
    key text NOT NULL,
    value jsonb NOT NULL
);

CREATE TABLE lobbies (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    code text NOT NULL,
    host_player_id uuid NOT NULL,
    privacy text NOT NULL DEFAULT 'private'::text,
    max_players integer NOT NULL DEFAULT 8,
    round_seconds integer NOT NULL DEFAULT 30,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    last_activity_at timestamp with time zone DEFAULT now(),
    host_user_id uuid,
    phase text NOT NULL DEFAULT 'waiting'::text,
    holder_player_id uuid,
    explode_at timestamp with time zone,
    round_number integer NOT NULL DEFAULT 0,
    last_loser_player_id uuid,
    round_speed text NOT NULL DEFAULT 'normal'::text,
    run_started_at timestamp with time zone,
    settings_version integer DEFAULT 1,
    locked boolean NOT NULL DEFAULT false,
    status text DEFAULT 'waiting'::text,
    game_mode text NOT NULL DEFAULT 'original'::text,
    topic text,
    topic_a text,
    topic_b text,
    topic_selected text,
    topic_vote_started_at timestamp with time zone,
    topic_vote_ends_at timestamp with time zone,
    countdown_started_at timestamp with time zone,
    countdown_ends_at timestamp with time zone,
    countdown_seconds integer NOT NULL DEFAULT 5,
    topic_tie_choices ARRAY,
    topic_tie_pick integer,
    last_topic text,
    current_run_id uuid,
    safe_until timestamp with time zone,
    round_index integer DEFAULT 0,
    last_round_seconds numeric,
    pass_direction smallint NOT NULL DEFAULT 1,
    topic_filter text[],  -- Migration 026. NULL/leer = alle Kategorien möglich.
    current_song_id uuid REFERENCES song_pool(id),  -- Migration 029.
    used_song_ids uuid[] NOT NULL DEFAULT '{}',      -- Migration 029.
    answer_mode text NOT NULL DEFAULT 'text',        -- Migration 031. 'text' | 'voice'.
    round_bonus_used numeric NOT NULL DEFAULT 0      -- Migration 034. Kumulierter Pass-Bonus der aktuellen Runde.
);

CREATE TABLE lobby_admin_logs (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    lobby_id uuid NOT NULL,
    user_id uuid NOT NULL,
    action text NOT NULL,
    payload jsonb,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE lobby_admin_sessions (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    lobby_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    activated_at timestamp with time zone NOT NULL DEFAULT now(),
    is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE players (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    lobby_id uuid NOT NULL,
    player_id uuid NOT NULL,
    name text NOT NULL,
    ready boolean NOT NULL DEFAULT false,
    joined_at timestamp with time zone NOT NULL DEFAULT now(),
    last_seen_at timestamp with time zone NOT NULL DEFAULT now(),
    user_id uuid,
    seat_index integer,
    is_alive boolean NOT NULL DEFAULT true,
    kicked_at timestamp with time zone,
    is_online boolean DEFAULT false,
    status text NOT NULL DEFAULT 'active'::text,
    left_at timestamp with time zone,
    last_pass_at timestamp with time zone,
    survival_streak integer DEFAULT 0,
    pass_count integer NOT NULL DEFAULT 0,
    clutch_pass_count integer NOT NULL DEFAULT 0,
    fastest_pass_ms integer,
    total_hold_ms bigint NOT NULL DEFAULT 0,
    is_bot boolean NOT NULL DEFAULT false,
    session_token uuid  -- Migration 023. NICHT per SELECT * lesbar: Column-Grant
                        -- für anon/authenticated schließt sie explizit aus
                        -- (REVOKE/GRANT-Spaltenliste in Migration 023).
);

CREATE TABLE profiles (
    id uuid NOT NULL,
    username text NOT NULL,
    phone text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    email text,
    email_verified_at timestamp with time zone,
    phone_verified_at timestamp with time zone,
    is_platform_admin boolean NOT NULL DEFAULT false  -- Migration 031. Nur per SQL setzbar.
);

CREATE TABLE round_stats (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    lobby_id uuid,
    round_index integer,
    exploded_player_id text,
    holder_time_ms integer,
    pass_count integer,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE staff_roles (
    user_id uuid NOT NULL,
    role text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE topic_pool (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    text text NOT NULL,
    active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    is_song_category boolean NOT NULL DEFAULT false  -- Migration 029.
);

CREATE TABLE topic_votes (
    lobby_id uuid NOT NULL,
    player_id uuid NOT NULL,
    choice integer NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- ============================================================
-- Ab hier: Tabellen aus den Migrationen 001, 005, 008
-- (waren im ursprünglichen Dump von 2026-05-11 noch nicht enthalten,
-- weil er vor diesen Migrationen gezogen wurde).
-- ============================================================

CREATE TABLE pass_attempts (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    lobby_id uuid NOT NULL REFERENCES lobbies(id) ON DELETE CASCADE,
    round_number integer NOT NULL,
    holder_player_id uuid NOT NULL,
    answer text NOT NULL,
    topic text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    accept_count integer NOT NULL DEFAULT 0,
    reject_count integer NOT NULL DEFAULT 0,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    decided_at timestamp with time zone
);

CREATE TABLE pass_attempt_votes (
    attempt_id uuid NOT NULL REFERENCES pass_attempts(id) ON DELETE CASCADE,
    voter_id uuid NOT NULL,
    accept boolean NOT NULL,
    voted_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Migration 027: Referenz-Antworten pro Kategorie. Ein Treffer hier lässt
-- rpc_attempt_pass die Antwort sofort automatisch annehmen (kein Voting
-- nötig); ohne Treffer greift weiterhin das bestehende Mehrheits-Voting.
CREATE TABLE topic_answers (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    topic_pool_id uuid NOT NULL REFERENCES topic_pool(id) ON DELETE CASCADE,
    answer text NOT NULL,
    lower_answer text GENERATED ALWAYS AS (lower(answer)) STORED,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE (topic_pool_id, lower_answer)
);

-- Migration 029: pro Musik-Kategorie ein echter Songtitel. current_song_id
-- auf lobbies zeigt auf den EINEN Song, den der aktuelle Halter gerade
-- "hat" -- der Titel wird im Client nie gerendert, nur als iTunes-Search-
-- Suchbegriff für den 30s-Preview-Clip verwendet.
CREATE TABLE song_pool (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    topic_pool_id uuid NOT NULL REFERENCES topic_pool(id) ON DELETE CASCADE,
    title text NOT NULL,
    artist text,
    lower_title text GENERATED ALWAYS AS (lower(title)) STORED,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    preview_url text,                    -- Migration 036. Gecachte iTunes-Preview.
    preview_checked_at timestamp with time zone,  -- Migration 036.
    UNIQUE (topic_pool_id, lower_title)
);

CREATE TABLE achievements (
    code text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    icon text NOT NULL,
    tier text NOT NULL DEFAULT 'bronze',
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE player_lifetime_stats (
    user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    games_played integer NOT NULL DEFAULT 0,
    wins integer NOT NULL DEFAULT 0,
    total_passes integer NOT NULL DEFAULT 0,
    total_clutch_passes integer NOT NULL DEFAULT 0,
    fastest_pass_ms integer,
    total_hold_ms bigint NOT NULL DEFAULT 0,
    best_survival_streak integer NOT NULL DEFAULT 0,
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE player_achievements (
    user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    achievement_code text NOT NULL REFERENCES achievements(code) ON DELETE CASCADE,
    unlocked_at timestamp with time zone NOT NULL DEFAULT now(),
    lobby_id uuid REFERENCES lobbies(id) ON DELETE SET NULL
);

CREATE TABLE friendships (
    user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    friend_user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'pending',
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    accepted_at timestamp with time zone
);

CREATE TABLE saved_lobbies (
    user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    lobby_code text NOT NULL,
    nickname text NOT NULL,
    last_used timestamp with time zone NOT NULL DEFAULT now(),
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Views (nicht per DROP-Skript entfernbar wie Tabellen, nur der Vollständigkeit halber dokumentiert):
--   leaderboard_view   (Migration 006, security_invoker seit Migration 015) — player_lifetime_stats x profiles.username
--   friends_view       (Migration 008, security_invoker seit Migration 015) — friendships x profiles.username
--   public_lobbies_view existiert NICHT in main (nur im unmerged Branch
--     claude/beautiful-panini-20b290, siehe TESTREPORT.md)
