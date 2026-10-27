-- Transferroute: weekbekers in de poule. Plak dit in Supabase → SQL Editor → New query → Run.

-- Klassement van je poule (week, totaal en gewonnen weekbekers). Uitslagen van anderen voor vandaag zie je pas als je zelf hebt gespeeld.
drop function if exists public.pool_board(uuid, uuid, int);
create or replace function public.pool_board(p_member uuid, p_secret uuid, p_day int)
returns table (pool_name text, pool_code text, nickname text, is_me boolean, played boolean,
               outcome text, stop int, guesses int, hint boolean, streak int, week_points int, total_points int, cups int)
language plpgsql security definer set search_path = public as $$
declare v_pool uuid; v_i_played boolean; v_week_start int;
begin
  v_pool := tr_check(p_member, p_secret);
  select exists (select 1 from results r where r.member_id = p_member and r.day = p_day) into v_i_played;
  -- week = maandag t/m zondag (Nederlandse tijd)
  v_week_start := p_day - ((extract(isodow from date '2026-10-22' + p_day)::int) - 1);
  return query
    select p.name, p.code, m.nickname, m.id = p_member,
           r.day is not null,
           case when v_i_played or m.id = p_member then r.outcome end,
           case when v_i_played or m.id = p_member then r.stop end,
           case when v_i_played or m.id = p_member then r.guesses end,
           case when v_i_played or m.id = p_member then r.hint end,
           tr_streak(m.id),
           coalesce((select sum(tr_points(w.outcome, w.stop, w.hint))::int from results w
                     where w.member_id = m.id and w.day between v_week_start and p_day), 0),
           coalesce((select sum(tr_points(t.outcome, t.stop, t.hint))::int from results t
                     where t.member_id = m.id and t.day <= p_day), 0),
           coalesce(c.cups, 0)
    from members m
    join pools p on p.id = m.pool_id
    left join results r on r.member_id = m.id and r.day = p_day
    left join (
      -- bekers: per afgelopen week (ma t/m zo) krijgt de hoogste weekscore een beker; gelijk = allebei
      select wp.member_id, count(*)::int as cups
      from (select w.member_id, (w.day + 3) / 7 as wk, sum(tr_points(w.outcome, w.stop, w.hint)) as pts
              from results w join members mm on mm.id = w.member_id
             where mm.pool_id = v_pool and w.day < v_week_start
             group by 1, 2) wp
      join (select wk, max(pts) as best
              from (select w.member_id, (w.day + 3) / 7 as wk, sum(tr_points(w.outcome, w.stop, w.hint)) as pts
                      from results w join members mm on mm.id = w.member_id
                     where mm.pool_id = v_pool and w.day < v_week_start
                     group by 1, 2) x
             group by wk) b on b.wk = wp.wk and wp.pts = b.best and b.best > 0
      group by wp.member_id
    ) c on c.member_id = m.id
    where m.pool_id = v_pool
    order by 11 desc, 10 desc, m.nickname;
end $$;

grant execute on function public.pool_board(uuid, uuid, int) to anon;
