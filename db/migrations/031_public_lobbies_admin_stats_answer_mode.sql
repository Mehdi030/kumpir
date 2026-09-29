-- ============================================================
-- Migration 031: Public-Lobbys fertigbauen, Admin-Stats absichern,
-- Antwort-Modus (Schreiben/Sprechen) als Lobby-Einstellung
-- ============================================================
-- Drei unabhängige Ergänzungen, in einer Migration gebündelt:
--
-- 1) Admin-Stats-Zugriffsschutz: `/admin/stats` hatte bisher gar keine
--    Zugriffskontrolle (weder Route noch Backend) -- jeder mit der URL
--    konnte interne Aggregat-Statistiken sehen. Neues `profiles.
--    is_platform_admin` Flag (manuell per SQL gesetzt, kein UI dafür --
--    bewusst, es soll niemand versehentlich sich selbst freischalten
--    können) + eine SECURITY DEFINER Funktion, die die Berechtigung
--    SERVERSEITIG prüft, bevor sie irgendwas zurückgibt. Das Frontend
--    ruft nur noch diese eine Funktion auf statt zehn Rohtabellen
--    direkt abzufragen.
--
-- 2) Public-Lobbys: `rpc_create_lobby` validiert `p_privacy` schon seit
--    Migration 020 korrekt -- die Public-Option war nur im Frontend
--    deaktiviert. Für eine Lobby-Übersicht ("welche Lobbys sind gerade
--    offen") fehlte bisher eine Abfragemöglichkeit + eine Funktion, um
--    die Privatsphäre auch NACH der Erstellung zu ändern (Konsistenz
--    mit set_lobby_mode/set_lobby_topic, die das für andere Einstellungen
--    schon können).
--
-- 3) Antwort-Modus: neue Spalte `lobbies.answer_mode` ('text' | 'voice'),
--    wählbar beim Hosten UND danach änderbar. 'text' bleibt Default --
--    Sprocheingabe ist ein Zusatzmodus, kein Ersatz.
-- ============================================================

BEGIN;

-- --- 1) Admin-Stats -------------------------------------------------

ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS is_platform_admin boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.rpc_get_admin_stats(p_user_id uuid)
    RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
    v_is_admin boolean;
    v_result jsonb;
    v_stuck_cutoff timestamptz := now() - interval '30 seconds';
    v_day_ago timestamptz := now() - interval '24 hours';
begin
    if p_user_id is null then
        raise exception 'not_authorized';
    end if;

    select coalesce(is_platform_admin, false) into v_is_admin
    from public.profiles where id = p_user_id;

    if not coalesce(v_is_admin, false) then
        raise exception 'not_authorized';
    end if;

    select jsonb_build_object(
        'lobbies', jsonb_build_object(
            'totalEver', (select count(*) from public.lobbies),
            'activeNow', (select count(*) from public.lobbies where phase in ('topic_vote','countdown','running','rematch_wait')),
            'last24h', (select count(*) from public.lobbies where created_at >= v_day_ago),
            'byMode', (
                select coalesce(jsonb_object_agg(game_mode, cnt), '{}'::jsonb)
                from (select coalesce(game_mode, 'original') as game_mode, count(*) as cnt from public.lobbies group by 1) s
            ),
            'bySpeed', (
                select coalesce(jsonb_object_agg(round_speed, cnt), '{}'::jsonb)
                from (select coalesce(round_speed, 'normal') as round_speed, count(*) as cnt from public.lobbies group by 1) s
            )
        ),
        'players', jsonb_build_object(
            'totalRows', (select count(*) from public.players),
            'botRows', (select count(*) from public.players where is_bot = true),
            'activeRows', (select count(*) from public.players where status = 'active')
        ),
        'matches', jsonb_build_object(
            'finished', (select count(*) from public.game_runs where finished_at is not null),
            'avgPlayers', (select round(avg(players_count)::numeric, 1) from public.game_runs where finished_at is not null and players_count is not null),
            'avgDurationSec', (select round(avg(extract(epoch from (finished_at - started_at)))::numeric) from public.game_runs where finished_at is not null)
        ),
        'social', jsonb_build_object(
            'registeredUsers', (select count(*) from public.profiles),
            'acceptedFriendships', (select count(*) from public.friendships where status = 'accepted'),
            'savedLobbies', (select count(*) from public.saved_lobbies)
        ),
        'content', jsonb_build_object(
            'activeTopics', (select count(*) from public.topic_pool where active = true)
        ),
        'votes', jsonb_build_object(
            'total', (select count(*) from public.pass_attempts),
            'accepted', (select count(*) from public.pass_attempts where status = 'accepted'),
            'rejected', (select count(*) from public.pass_attempts where status = 'rejected'),
            'pending', (select count(*) from public.pass_attempts where status = 'pending'),
            'stuckPending', (select count(*) from public.pass_attempts where status = 'pending' and created_at < v_stuck_cutoff)
        ),
        'achievements', jsonb_build_object(
            'totalUnlocked', (select count(*) from public.player_achievements)
        ),
        'leaderboard', (
            select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
            from (select username, wins, games_played, win_rate_pct from public.leaderboard_view order by wins desc limit 5) t
        )
    ) into v_result;

    return v_result;
end;
$function$;

-- --- 3) Antwort-Modus (Schreiben/Sprechen) -----------------------------
-- Muss VOR der public_lobbies_view (Abschnitt 2) stehen, die l.answer_mode
-- bereits mit ausliest -- sonst schlägt die View-Erstellung mit
-- "column l.answer_mode does not exist" fehl.

ALTER TABLE public.lobbies
    ADD COLUMN IF NOT EXISTS answer_mode text NOT NULL DEFAULT 'text'
        CHECK (answer_mode IN ('text', 'voice'));

CREATE OR REPLACE FUNCTION public.set_lobby_answer_mode(p_lobby_id uuid, p_me_player_id uuid, p_answer_mode text)
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_mode text;
begin
    if not public._verify_session(p_lobby_id, p_me_player_id) then
        raise exception 'invalid_session';
    end if;

    select host_player_id into v_host from public.lobbies where id = p_lobby_id;
    if v_host is null then raise exception 'lobby_not_found'; end if;
    if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

    v_mode := btrim(coalesce(p_answer_mode, ''));
    if v_mode not in ('text', 'voice') then raise exception 'invalid_answer_mode'; end if;

    update public.lobbies
    set answer_mode = v_mode,
        settings_version = coalesce(settings_version, 0) + 1
    where id = p_lobby_id;
end;
$function$;

-- --- 2) Public-Lobbys -------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_lobby_privacy(p_lobby_id uuid, p_me_player_id uuid, p_privacy text)
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_host uuid; v_privacy text;
begin
    if not public._verify_session(p_lobby_id, p_me_player_id) then
        raise exception 'invalid_session';
    end if;

    select host_player_id into v_host from public.lobbies where id = p_lobby_id;
    if v_host is null then raise exception 'lobby_not_found'; end if;
    if v_host is distinct from p_me_player_id then raise exception 'not_host'; end if;

    v_privacy := btrim(coalesce(p_privacy, ''));
    if v_privacy not in ('private', 'public') then raise exception 'invalid_privacy'; end if;

    update public.lobbies
    set privacy = v_privacy,
        settings_version = coalesce(settings_version, 0) + 1
    where id = p_lobby_id;
end;
$function$;

-- Übersicht offener Public-Lobbys (Warteraum, unversperrt). Die
-- zugrundeliegenden Tabellen erlauben anon SELECT ohnehin schon
-- uneingeschränkt (lobbies_read_all / players_read_all aus Migration
-- 012 -- "privacy" filtert bisher nur, was die UI anzeigt, nicht was
-- die DB rausgibt), eine normale View reicht hier also aus.
CREATE OR REPLACE VIEW public.public_lobbies_view AS
SELECT
    l.code,
    l.game_mode,
    l.round_speed,
    l.max_players,
    l.topic_filter,
    l.answer_mode,
    l.created_at,
    h.name AS host_name,
    (SELECT count(*) FROM public.players p WHERE p.lobby_id = l.id AND p.status = 'active') AS player_count
FROM public.lobbies l
JOIN public.players h ON h.lobby_id = l.id AND h.player_id = l.host_player_id
WHERE l.privacy = 'public' AND l.phase = 'waiting' AND l.locked = false;

COMMIT;
