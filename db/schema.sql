-- ============================================================
-- KUMPIR — Echtes Schema (gedumpt aus Supabase)
-- Stand: 2026-05-11
-- ============================================================
-- Quelle: User-Dump via SQL-Editor Query 1 aus db/HOW_TO_DUMP.md
-- Diese Datei ist die WAHRHEIT. db/schema.reconstructed.sql kann gelöscht werden.
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

CREATE TABLE game_state (
    lobby_code text NOT NULL,
    round integer NOT NULL DEFAULT 1,
    state text NOT NULL DEFAULT 'idle'::text,
    current_holder_player_id uuid,
    timer_ends_at timestamp with time zone,
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    created_at timestamp with time zone NOT NULL DEFAULT now()
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
    pass_direction smallint NOT NULL DEFAULT 1
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

CREATE TABLE lobby_players (
    lobby_id uuid NOT NULL,
    player_id uuid NOT NULL,
    name text NOT NULL,
    ready boolean NOT NULL DEFAULT false,
    joined_at timestamp with time zone NOT NULL DEFAULT now()
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
    total_hold_ms bigint NOT NULL DEFAULT 0
);

CREATE TABLE profiles (
    id uuid NOT NULL,
    username text NOT NULL,
    phone text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    email text,
    email_verified_at timestamp with time zone,
    phone_verified_at timestamp with time zone
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
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE topic_votes (
    lobby_id uuid NOT NULL,
    player_id uuid NOT NULL,
    choice integer NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE topics (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);
