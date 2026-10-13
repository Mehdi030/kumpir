-- ============================================================
-- 112: Quiz – Bots buzzern später (Test 2026-10-13: Bots waren fast immer zuerst dran)
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public._quiz_bot_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_seed text; v_delay numeric; v_ok boolean; v_el numeric; s public.quiz_secret%ROWTYPE;
        v_answer text; v_choices jsonb; v_year int; v_range int; v_pick uuid;
BEGIN
  FOR r IN
    SELECT l.id AS lobby_id, l.game_mode, l.quiz_state, l.quiz_seq, l.quiz_index, l.quiz_started_at, l.quiz_picker, l.quiz_options, l.quiz_locked,
           p.player_id, coalesce(p.bot_skill, 2) AS skill
    FROM public.lobbies l JOIN public.players p ON p.lobby_id = l.id AND p.is_bot AND p.status = 'active'
    WHERE l.phase = 'quiz' AND l.quiz_state IN ('pick', 'bet', 'question', 'buzzed')
  LOOP
    BEGIN
      v_seed := r.player_id::text || ':' || r.quiz_seq || ':' || r.quiz_state || ':' || r.quiz_index;
      v_el := extract(epoch FROM now() - r.quiz_started_at);
      v_ok := (abs(hashtext('ok' || v_seed)) % 1000) / 1000.0 < (CASE r.skill WHEN 1 THEN 0.45 WHEN 3 THEN 0.85 ELSE 0.65 END);
      v_delay := CASE r.skill WHEN 1 THEN 6 WHEN 3 THEN 1.5 ELSE 3.5 END + (abs(hashtext('d' || v_seed)) % 1000) / 1000.0 * CASE r.skill WHEN 1 THEN 5 WHEN 3 THEN 2.5 ELSE 4.5 END;
      IF r.game_mode = 'snippet' THEN v_delay := v_delay * 1.6; END IF;
      -- 112: beim Buzzer sollen Menschen eine Chance haben – Bots drücken deutlich später
      IF r.game_mode = 'buzzer' THEN v_delay := v_delay * 2.2 + 2; END IF;

      IF r.quiz_state = 'pick' THEN
        IF r.quiz_picker = r.player_id AND v_el > 2.5 THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          PERFORM public._quiz_do_pick(r.lobby_id, r.player_id, s.pick_options[1 + abs(hashtext(v_seed)) % greatest(array_length(s.pick_options, 1), 1)]);
        END IF;
      ELSIF r.quiz_state = 'bet' THEN
        IF v_el > 2 AND r.player_id::text NOT IN (r.quiz_options ->> 'a', r.quiz_options ->> 'b')
           AND NOT EXISTS (SELECT 1 FROM public.quiz_bets WHERE lobby_id = r.lobby_id AND duel = r.quiz_index AND player_id = r.player_id) THEN
          PERFORM public._quiz_do_bet(r.lobby_id, r.player_id, (CASE WHEN abs(hashtext(v_seed)) % 2 = 0 THEN r.quiz_options ->> 'a' ELSE r.quiz_options ->> 'b' END)::uuid);
        END IF;
      ELSIF r.quiz_state = 'buzzed' THEN
        IF r.quiz_picker = r.player_id AND v_el > 1.5 THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 2 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
            INTO v_answer FROM public.song_pool WHERE id = s.song_id;
          PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
        END IF;
      ELSIF r.quiz_state = 'question' AND v_el >= v_delay THEN
        IF r.player_id = ANY (public._quiz_eligible(r.lobby_id))
           AND NOT EXISTS (SELECT 1 FROM public.quiz_answers WHERE lobby_id = r.lobby_id AND seq = r.quiz_seq AND player_id = r.player_id) THEN
          SELECT * INTO s FROM public.quiz_secret WHERE lobby_id = r.lobby_id;
          IF r.game_mode = 'artist' THEN
            v_choices := r.quiz_options -> 'choices';
            v_answer := CASE WHEN v_ok THEN s.answer ELSE v_choices ->> (abs(hashtext('c' || v_seed)) % greatest(jsonb_array_length(v_choices), 1)) END;
            PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_answer);
          ELSIF r.game_mode = 'year' THEN
            v_range := CASE r.skill WHEN 1 THEN 7 WHEN 3 THEN 2 ELSE 4 END;
            v_year := coalesce(s.year, 2020) + (abs(hashtext('y' || v_seed)) % (2 * v_range + 1)) - v_range;
            PERFORM public._quiz_do_choose(r.lobby_id, r.player_id, v_year::text);
          ELSIF r.game_mode = 'buzzer' THEN
            IF v_ok AND NOT (r.player_id = ANY (r.quiz_locked)) THEN PERFORM public._quiz_do_buzz(r.lobby_id, r.player_id); END IF;
          ELSIF v_ok THEN
            IF r.game_mode = 'gap' THEN v_answer := s.answer;
            ELSE
              SELECT CASE WHEN abs(hashtext('t' || v_seed)) % 3 = 0 THEN title ELSE trim(split_part(split_part(artist, ',', 1), '&', 1)) END
                INTO v_answer FROM public.song_pool WHERE id = s.song_id;
            END IF;
            PERFORM public._quiz_do_answer(r.lobby_id, r.player_id, v_answer);
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END $function$;

COMMIT;
