-- Transferroute: poules en klassement
-- Plak dit volledige script in Supabase → SQL Editor → New query → Run.
-- Het is veilig om het opnieuw te draaien.
--
-- Beveiliging: de tabellen zijn NIET direct leesbaar of schrijfbaar met de publieke (anon) sleutel.
-- Alles loopt via de functies hieronder, die zelf controleren wie je bent (via een geheime code op je telefoon).

-- ---------- Tabellen ----------
create table if not exists public.pools (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null check (char_length(name) between 1 and 40),
  created_at  timestamptz not null default now()
);

create table if not exists public.members (
  id          uuid primary key default gen_random_uuid(),
  pool_id     uuid not null references public.pools(id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 1 and 20),
  secret      uuid not null default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  unique (pool_id, nickname)
);

create table if not exists public.results (
  member_id   uuid not null references public.members(id) on delete cascade,
  day         int  not null,                       -- 0 = 22 okt 2026, net als in het spel
  outcome     text not null check (outcome in ('won','missed','gaveup')),
  stop        int,                                 -- bij welke stop geraden (alleen bij 'won')
  guesses     int  not null default 0,             -- aantal gekleurde vlakjes
  hint        boolean not null default false,
  created_at  timestamptz not null default now(),
  primary key (member_id, day)
);

create index if not exists members_pool_idx on public.members(pool_id);
create index if not exists results_day_idx on public.results(day);

alter table public.pools   enable row level security;
alter table public.members enable row level security;
alter table public.results enable row level security;
revoke all on public.pools, public.members, public.results from anon, authenticated;

-- ---------- Hulpfuncties ----------
-- Speldag volgens de Nederlandse kalender (dag 0 = 22 oktober 2026).
create or replace function public.tr_today() returns int
language sql stable as $$
  select ((now() at time zone 'Europe/Amsterdam')::date - date '2026-10-22')::int
$$;

-- Punten voor de weekstand: je begint met 10; elke stop verder kost 1, de hint kost 1.
-- Herkend levert altijd minstens 1 punt op; niet herkend of opgegeven = 0.
drop function if exists public.tr_points(text, int);
create or replace function public.tr_points(p_outcome text, p_stop int, p_hint boolean) returns int
language sql immutable as $$
  select case when p_outcome = 'won'
              then greatest(1, 11 - coalesce(p_stop, 10) - case when p_hint then 1 else 0 end)
              else 0 end
$$;

-- Reeks: aantal aaneengesloten geraden dagen, eindigend vandaag of gisteren.
create or replace function public.tr_streak(p_member uuid) returns int
language plpgsql stable as $$
declare d int := public.tr_today(); n int := 0;
begin
  if exists (select 1 from public.results where member_id = p_member and day = d and outcome <> 'won') then
    return 0;  -- vandaag gespeeld maar niet geraden: reeks is voorbij
  end if;
  if not exists (select 1 from public.results where member_id = p_member and day = d) then
    d := d - 1;  -- vandaag nog niet gespeeld: reeks telt vanaf gisteren
  end if;
  while exists (select 1 from public.results where member_id = p_member and day = d and outcome = 'won') loop
    n := n + 1; d := d - 1;
  end loop;
  return n;
end $$;

create or replace function public.tr_check(p_member uuid, p_secret uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v_pool uuid;
begin
  select pool_id into v_pool from members where id = p_member and secret = p_secret;
  if v_pool is null then raise exception 'Onbekende speler'; end if;
  return v_pool;
end $$;

-- ---------- Functies voor het spel ----------
-- Nieuwe poule maken. Geeft de code en je eigen spelersgegevens terug.
create or replace function public.create_pool(p_name text, p_nickname text)
returns table (code text, member_id uuid, secret uuid)
language plpgsql security definer set search_path = public as $$
declare v_code text; v_pool uuid;
begin
  loop
    -- 6 tekens zonder verwarrende letters/cijfers (geen O/0, I/1)
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
      into v_code from generate_series(1, 6);
    exit when not exists (select 1 from pools p where p.code = v_code);
  end loop;
  insert into pools(code, name) values (v_code, trim(p_name)) returning id into v_pool;
  return query
    insert into members(pool_id, nickname) values (v_pool, trim(p_nickname))
    returning v_code, members.id, members.secret;
end $$;

-- Meedoen met een bestaande poule.
create or replace function public.join_pool(p_code text, p_nickname text)
returns table (pool_name text, member_id uuid, secret uuid)
language plpgsql security definer set search_path = public as $$
declare v_pool uuid; v_name text;
begin
  select id, name into v_pool, v_name from pools where pools.code = upper(trim(p_code));
  if v_pool is null then raise exception 'Deze poule bestaat niet'; end if;
  if exists (select 1 from members m where m.pool_id = v_pool and lower(m.nickname) = lower(trim(p_nickname))) then
    raise exception 'Deze bijnaam is al bezet in deze poule';
  end if;
  return query
    insert into members(pool_id, nickname) values (v_pool, trim(p_nickname))
    returning v_name, members.id, members.secret;
end $$;

-- Uitslag versturen. Eén uitslag per speler per dag. Eerdere dagen mogen ook (wie later instapt, telt zijn eerder gespeelde dagen mee).
create or replace function public.submit_result(p_member uuid, p_secret uuid, p_day int,
  p_outcome text, p_stop int, p_guesses int, p_hint boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform tr_check(p_member, p_secret);
  if p_day not between 0 and tr_today() then raise exception 'Verkeerde dag'; end if;
  insert into results(member_id, day, outcome, stop, guesses, hint)
  values (p_member, p_day, p_outcome, case when p_outcome = 'won' then p_stop end, greatest(0, p_guesses), coalesce(p_hint, false))
  on conflict (member_id, day) do nothing;
end $$;

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

-- Poule verlaten en al je gegevens wissen.
create or replace function public.leave_pool(p_member uuid, p_secret uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_pool uuid;
begin
  v_pool := tr_check(p_member, p_secret);
  delete from members where id = p_member;
  delete from pools where id = v_pool and not exists (select 1 from members where pool_id = v_pool);
end $$;

-- Alleen deze functies mogen vanuit het spel worden aangeroepen.
revoke all on function public.tr_check(uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_pool(text, text)  to anon;
grant execute on function public.join_pool(text, text)    to anon;
grant execute on function public.submit_result(uuid, uuid, int, text, int, int, boolean) to anon;
grant execute on function public.pool_board(uuid, uuid, int) to anon;
grant execute on function public.leave_pool(uuid, uuid)   to anon;
