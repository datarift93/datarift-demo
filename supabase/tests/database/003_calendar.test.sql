-- Spot checks for public.calendar (filled by the calendar migration).
begin;
create extension if not exists pgtap with schema extensions;

select plan(31);

-- Coverage ------------------------------------------------------------------
select results_eq(
  $$ select min(date), max(date), count(*)::int from public.calendar $$,
  $$ values ('2022-01-01'::date, '2030-12-31'::date, 3287) $$,
  'calendar covers 2022-01-01..2030-12-31 with one row per day'
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
  $$ values ('2022-04-17'::date), ('2023-04-09'), ('2024-03-31'), ('2025-04-20'), ('2026-04-05'),
            ('2027-03-28'), ('2028-04-16'), ('2029-04-01'), ('2030-04-21') $$,
  'Easter Sunday dates 2022-2030');
select results_eq(
  $$ select year, count(*)::int from public.calendar where is_holiday group by year order by year $$,
  $$ select y::smallint, case when y < 2025 then 13 else 14 end from generate_series(2022, 2030) y $$,
  '13 public holidays a year, 14 from 2025');

-- Trading Sundays --------------------------------------------------------------
select ok((select is_trading_sunday from public.calendar where date = '2025-12-14'),
  '2025-12-14 is a trading Sunday');
select ok(not (select is_trading_sunday from public.calendar where date = '2025-11-23'),
  '2025-11-23 is an ordinary (non-trading) Sunday');
-- Published lists of trading Sundays (computed by the rule in the migration).
select set_eq(
  $$ select date from public.calendar where is_trading_sunday and year between 2023 and 2027 $$,
  $$ values
       ('2023-01-29'::date), ('2023-04-02'), ('2023-04-30'), ('2023-06-25'), ('2023-08-27'),
       ('2023-12-17'), ('2023-12-24'),
       ('2024-01-28'), ('2024-03-24'), ('2024-04-28'), ('2024-06-30'), ('2024-08-25'),
       ('2024-12-15'), ('2024-12-22'),
       ('2025-01-26'), ('2025-04-13'), ('2025-04-27'), ('2025-06-29'), ('2025-08-31'),
       ('2025-12-07'), ('2025-12-14'), ('2025-12-21'),
       ('2026-01-25'), ('2026-03-29'), ('2026-04-26'), ('2026-06-28'), ('2026-08-30'),
       ('2026-12-06'), ('2026-12-13'), ('2026-12-20'),
       ('2027-01-31'), ('2027-03-21'), ('2027-04-25'), ('2027-06-27'), ('2027-08-29'),
       ('2027-12-05'), ('2027-12-12'), ('2027-12-19') $$,
  'trading Sundays 2023-2027 match the published lists');
select results_eq(
  $$ select year, count(*)::int from public.calendar where is_trading_sunday group by year order by year $$,
  $$ select y::smallint, case when y < 2025 then 7 else 8 end from generate_series(2022, 2030) y $$,
  'trading Sundays per year: 7 until 2024, 8 from 2025');
select is_empty(
  $$ select date from public.calendar where is_trading_sunday and (day_of_week <> 7 or is_holiday) $$,
  'trading Sundays are Sundays and never holidays');
-- Holiday shift: 24 Dec 2028 is a Sunday and a holiday, so the third December
-- trading Sunday moves back to 3 Dec.
select results_eq(
  $$ select date from public.calendar where is_trading_sunday and year = 2028 and month = 12 order by date $$,
  $$ values ('2028-12-03'::date), ('2028-12-10'), ('2028-12-17') $$,
  'a trading Sunday on a holiday moves to the previous Sunday (December 2028)');

-- Store trading days -------------------------------------------------------------
select ok(not (select is_store_trading_day from public.calendar where date = '2025-11-23'),
  'stores are closed on a non-trading Sunday');
select ok((select is_store_trading_day from public.calendar where date = '2025-12-14'),
  'stores are open on a trading Sunday');
select ok(not (select is_store_trading_day from public.calendar where date = '2025-11-11'),
  'stores are closed on a holiday');

-- Short trading days ---------------------------------------------------------------
select ok((select is_short_trading_day from public.calendar where date = '2025-04-19'),
  'Holy Saturday 2025-04-19 is a short trading day');
select ok((select is_short_trading_day from public.calendar where date = '2025-12-31'),
  '2025-12-31 is a short trading day');
select ok((select is_short_trading_day from public.calendar where date = '2024-12-24'),
  '2024-12-24 is a short trading day');
select ok(not (select is_short_trading_day from public.calendar where date = '2025-12-24'),
  '2025-12-24 is a holiday, not a short trading day');
select ok(not (select is_short_trading_day from public.calendar where date = '2028-12-31'),
  '2028-12-31 is a non-trading Sunday, so not a short trading day');
select is_empty(
  $$ select date from public.calendar where is_short_trading_day and not is_store_trading_day $$,
  'short trading days are always store trading days');

-- Black Friday / Cyber Monday ------------------------------------------------------
select ok((select is_black_friday from public.calendar where date = '2025-11-28'),
  '2025-11-28 is Black Friday');
select ok((select is_cyber_monday from public.calendar where date = '2025-12-01'),
  '2025-12-01 is Cyber Monday');
select results_eq(
  $$ select year, count(*) filter (where is_black_friday)::int, count(*) filter (where is_cyber_monday)::int
     from public.calendar group by year order by year $$,
  $$ select y::smallint, 1, 1 from generate_series(2022, 2030) y $$,
  'exactly one Black Friday and one Cyber Monday a year');
select is_empty(
  $$ select bf.date from public.calendar bf
     where bf.is_black_friday
       and not exists (select 1 from public.calendar cm where cm.is_cyber_monday and cm.date = bf.date + 3) $$,
  'Cyber Monday is the Monday after Black Friday');

select * from finish();
rollback;
