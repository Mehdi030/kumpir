-- ============================================================
-- KUMPIR — RLS-Policies (REKONSTRUIERT)
-- ============================================================
-- Diese Policies sind GERATEN — basierend darauf, dass das Spiel
-- aktuell mit anon-Key vom Browser aus liest und schreibt.
-- Bitte mit den echten Policies aus Supabase überschreiben.
-- ============================================================

-- ------------------------------------------------------------
-- lobbies — Lesen offen, Schreiben nur via SECURITY DEFINER RPCs
-- ------------------------------------------------------------
ALTER TABLE public.lobbies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lobbies_read_all"
    ON public.lobbies
    FOR SELECT
    USING (true);

-- Schreiben über die Tabelle ist gesperrt — alle Writes müssen über RPCs laufen,
-- die SECURITY DEFINER definiert sind und ihre eigene Auth-Logik haben.


-- ------------------------------------------------------------
-- players — Lesen offen, Update auf eigene Row erlaubt
-- ------------------------------------------------------------
ALTER TABLE public.players ENABLE ROW LEVEL SECURITY;

CREATE POLICY "players_read_all"
    ON public.players
    FOR SELECT
    USING (true);

-- Update auf eigene Row (z.B. status = 'left' aus dem leaveLobby-Handler)
CREATE POLICY "players_update_self_leave"
    ON public.players
    FOR UPDATE
    USING (true)
    WITH CHECK (true);
-- ⚠️ Diese Policy ist sehr offen. In Etappe 3 (mit echtem Auth) ersetzen durch:
--     USING (auth.uid()::text = player_id::text)


-- ------------------------------------------------------------
-- topic_votes — Lesen offen, Schreiben über rpc_vote_topic
-- ------------------------------------------------------------
ALTER TABLE public.topic_votes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "topic_votes_read_all"
    ON public.topic_votes
    FOR SELECT
    USING (true);


-- ------------------------------------------------------------
-- profiles — Lesen für Username-Check, Schreiben nur eigene Row
-- ------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles_read_all"
    ON public.profiles
    FOR SELECT
    USING (true);

CREATE POLICY "profiles_insert_self"
    ON public.profiles
    FOR INSERT
    WITH CHECK (auth.uid() = id);

CREATE POLICY "profiles_update_self"
    ON public.profiles
    FOR UPDATE
    USING (auth.uid() = id);
