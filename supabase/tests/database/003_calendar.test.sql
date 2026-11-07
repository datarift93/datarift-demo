-- Spot checks for public.calendar (filled by the calendar migration).
begin;
create extension if not exists pgtap with schema extensions;

select plan(24);

-- Coverage ------------------------------------------------------------------
select results_eq(
  $$ select min(date), max(date), count(*)::int from public.calendar $$,
  $$ values ('2023-01-01'::date, '2027-12-31'::date, 1826) $$,
  'calendar covers 2023-01-01..2027-12-31 with one row per day'
);

-- Day of week and ISO week ---------------------------------------------------
select is((select day_of_week from public.calendar where date = '2025-11-28'), 5::smallint,
  '2025-11-28 is a Friday (ISO day 5)');
select results_eq(
  $$ select iso_year, iso_week from public.calendar where date = '2024-12-30' $$,
  $$ values (2025::smallint, 1::smallint) $$,
  '2024-12-30 belongs to ISO week 1 of 2025');
select results_eq(
  $$ select iso_year, iso_week from public.calendar where date = '2027-01-01' $$,
  $$ values (2026::smallint, 53::smallint) $$,
  '2027-01-01 belongs to ISO week 53 of 2026');

-- Public holidays -------------------------------------------------------------
select ok((select is_holiday from public.calendar where date = '2025-11-11'),
  '2025-11-11 (Święto Niepodległości) is a holiday');
select ok((select is_holiday from public.calendar where date = '2025-04-21'),
  '2025-04-21 (Poniedziałek Wielkanocny) is a holiday');
select ok((select is_holiday from public.calendar where date = '2025-06-19'),
  '2025-06-19 (Boże Ciało) is a holiday');
select ok(not (select is_holiday from public.calendar where date = '2024-12-24'),
  '2024-12-24 is not a holiday yet');
select ok((select is_holiday from public.calendar where date = '2025-12-24'),
  '2025-12-24 is a holiday (from 2025)');
select ok(not (select is_holiday from public.calendar where date = '2025-11-12'),
  'an ordinary weekday is not a holiday');
select results_eq(
  $$ select date from public.calendar where holiday_name = 'Wielkanoc' order by date $$,
  $$ values ('2023-04-09'::date), ('2024-03-31'), ('2025-04-20'), ('2026-04-05'), ('2027-03-28') $$,
  'Easter Sunday dates 2023-2027');
select results_eq(
  $$ select year, count(*)::int from public.calendar where is_holiday group by year order by year $$,
  $$ values (2023::smallint, 13), (2024::smallint, 13), (2025::smallint, 14), (2026::smallint, 14), (2027::smallint, 14) $$,
  '13 public holidays a year, 14 from 2025');

-- Trading Sundays --------------------------------------------------------------
select ok((select is_trading_sunday from public.calendar where date = '2025-12-14'),
  '2025-12-14 is a trading Sunday');
select ok(not (select is_trading_sunday from public.calendar where date = '2025-11-23'),
  '2025-11-23 is an ordinary (non-trading) Sunday');
select results_eq(
  $$ select year, count(*)::int from public.calendar where is_trading_sunday group by year order by year $$,
  $$ values (2023::smallint, 7), (2024::smallint, 7), (2025::smallint, 8), (2026::smallint, 8), (2027::smallint, 8) $$,
  'trading Sundays per year: 7 until 2024, 8 from 2025');
select is_empty(
  $$ select date from public.calendar where is_trading_sunday and (day_of_week <> 7 or is_holiday) $$,
  'trading Sundays are Sundays and never holidays');
-- The hard-coded list matches the rule: last Sunday of Jan/Apr/Jun/Aug, Sunday before
-- Easter, and the 2 (until 2024) or 3 (from 2025) Sundays before Christmas.
select set_eq(
  $$ select date from public.calendar where is_trading_sunday $$,
  $$ select c.date from public.calendar c
     where c.day_of_week = 7 and (
       (c.month in (1, 4, 6, 8) and extract(month from c.date + 7) <> c.month)
       or c.date + 7 = (select e.date from public.calendar e where e.holiday_name = 'Wielkanoc' and e.year = c.year)
       or (c.date < make_date(c.year, 12, 25)
           and c.date >= make_date(c.year, 12, 25) - case when c.year >= 2025 then 21 else 14 end)
     ) $$,
  'trading Sunday list follows the Sunday trading rules');

-- Store trading days -------------------------------------------------------------
select ok(not (select is_store_trading_day from public.calendar where date = '2025-11-23'),
  'stores are closed on a non-trading Sunday');
select ok((select is_store_trading_day from public.calendar where date = '2025-12-14'),
  'stores are open on a trading Sunday');
select ok(not (select is_store_trading_day from public.calendar where date = '2025-11-11'),
  'stores are closed on a holiday');

-- Black Friday / Cyber Monday ------------------------------------------------------
select ok((select is_black_friday from public.calendar where date = '2025-11-28'),
  '2025-11-28 is Black Friday');
select ok((select is_cyber_monday from public.calendar where date = '2025-12-01'),
  '2025-12-01 is Cyber Monday');
select results_eq(
  $$ select year, count(*) filter (where is_black_friday)::int, count(*) filter (where is_cyber_monday)::int
     from public.calendar group by year order by year $$,
  $$ values (2023::smallint, 1, 1), (2024::smallint, 1, 1), (2025::smallint, 1, 1), (2026::smallint, 1, 1), (2027::smallint, 1, 1) $$,
  'exactly one Black Friday and one Cyber Monday a year');
select is_empty(
  $$ select bf.date from public.calendar bf
     where bf.is_black_friday
       and not exists (select 1 from public.calendar cm where cm.is_cyber_monday and cm.date = bf.date + 3) $$,
  'Cyber Monday is the Monday after Black Friday');

select * from finish();
rollback;
