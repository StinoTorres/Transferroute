-- Transferroute: eerder gespeelde dagen tellen mee voor wie later in een poule stapt.

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

grant execute on function public.submit_result(uuid, uuid, int, text, int, int, boolean) to anon;
