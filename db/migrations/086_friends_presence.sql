-- ============================================================
-- 086: Freunde mit Online-Status
-- ============================================================
--   user_presence        – wann war ein Konto zuletzt auf der Seite (nur über Funktionen les-/schreibbar)
--   touch_presence()     – "ich bin da" (Browser meldet sich ca. jede Minute)
--   get_friends_status() – meine Freunde mit Avatar, Online-Status und (falls in einer offenen Lobby) Lobby-Code
-- Online = in den letzten 150 s gemeldet ODER gerade in einer Lobby verbunden. Nur Freunde sehen das voneinander.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_presence (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_presence ENABLE ROW LEVEL SECURITY;  -- keine Policies: nur über Funktionen
REVOKE ALL ON public.user_presence FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.touch_presence()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then return; end if;
  insert into public.user_presence (user_id, last_seen_at) values (auth.uid(), now())
  on conflict (user_id) do update set last_seen_at = now()
  where public.user_presence.last_seen_at < now() - interval '20 seconds';
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_friends_status()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_me uuid := auth.uid();
begin
  if v_me is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by (x."online") desc, lower(x.username))
    from (
      select pr.id as "userId", pr.username, pr.display_name as "displayName",
             pr.avatar_emoji as "avatarEmoji", pr.avatar_color as "avatarColor",
             coalesce(up.last_seen_at > now() - interval '150 seconds', false) or lob.code is not null as "online",
             greatest(up.last_seen_at, lob.seen) as "lastSeen",
             lob.code as "lobbyCode", lob.phase as "lobbyPhase",
             coalesce(lob.phase = 'waiting' and not coalesce(lob.locked, false) and coalesce(lob.active_players, 0) < coalesce(lob.max_players, 0), false) as "joinable"
      from public.friendships f
      join public.profiles pr on pr.id = f.friend_user_id
      left join public.user_presence up on up.user_id = pr.id
      left join lateral (
        select l.code, l.phase, l.locked, l.max_players, p.last_seen_at as seen,
               (select count(*) from public.players q where q.lobby_id = l.id and q.status = 'active') as active_players
        from public.players p join public.lobbies l on l.id = p.lobby_id
        where p.user_id = pr.id and p.status = 'active' and p.last_seen_at > now() - interval '90 seconds'
        order by p.last_seen_at desc limit 1
      ) lob on true
      where f.user_id = v_me and f.status = 'accepted' and pr.status = 'active'
    ) x
  ), '[]'::jsonb);
end;
$function$;

REVOKE ALL ON FUNCTION public.touch_presence() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_presence() TO authenticated;
REVOKE ALL ON FUNCTION public.get_friends_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_friends_status() TO authenticated;

COMMIT;
