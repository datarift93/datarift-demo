-- Fill public.calendar for 2022-01-01..2030-12-31.
--
-- Sources for the rules:
--   * public holidays: ustawa o dniach wolnych od pracy (1951, as amended);
--     24 December is a public holiday from 2025;
--   * trading Sundays: ustawa o ograniczeniu handlu w niedziele (2018, rules in force
--     from 2020, amended for 2025): the last Sunday of January, April, June and August,
--     the Sunday before Easter, and the Sundays before Christmas (2 until 2024, 3 from
--     2025). A trading Sunday that falls on a holiday moves to the previous Sunday
--     (e.g. 24 December 2028 is a holiday, so December trades on 3, 10 and 17).
--     The 2023-2027 dates are checked against the published lists in 003_calendar.test.sql;
--   * short trading days (stores close around 14:00): Holy Saturday, 31 December,
--     and 24 December before it became a holiday in 2025;
--   * Black Friday: last Friday of November; Cyber Monday: the Monday after it.

-- Easter Sunday (Gregorian calendar, anonymous algorithm / Meeus-Jones-Butcher).
create function private.easter_sunday(y integer)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare
  a int := y % 19;
  b int := y / 100;
  c int := y % 100;
  d int := b / 4;
  e int := b % 4;
  f int := (b + 8) / 25;
  g int := (b - f + 1) / 3;
  h int := (19 * a + b - d - g + 15) % 30;
  i int := c / 4;
  k int := c % 4;
  l int := (32 + 2 * e + 2 * i - h - k) % 7;
  m int := (a + 11 * h + 22 * l) / 451;
  mon int := (h + l - 7 * m + 114) / 31;
  dy int := ((h + l - 7 * m + 114) % 31) + 1;
begin
  return make_date(y, mon, dy);
end $$;

revoke all on function private.easter_sunday(integer) from public;

with
days as (
  select d::date as date
  from generate_series('2022-01-01'::date, '2030-12-31'::date, interval '1 day') as d
),
years as (
  select y, private.easter_sunday(y) as easter
  from generate_series(2022, 2030) as y
),
holidays (date, name) as (
  select make_date(y, 1, 1),   'Nowy Rok' from years
  union all select make_date(y, 1, 6),   'Święto Trzech Króli' from years
  union all select easter,               'Wielkanoc' from years
  union all select easter + 1,           'Poniedziałek Wielkanocny' from years
  union all select make_date(y, 5, 1),   'Święto Pracy' from years
  union all select make_date(y, 5, 3),   'Święto Konstytucji 3 Maja' from years
  union all select easter + 49,          'Zielone Świątki' from years
  union all select easter + 60,          'Boże Ciało' from years
  union all select make_date(y, 8, 15),  'Wniebowzięcie Najświętszej Maryi Panny' from years
  union all select make_date(y, 11, 1),  'Wszystkich Świętych' from years
  union all select make_date(y, 11, 11), 'Narodowe Święto Niepodległości' from years
  union all select make_date(y, 12, 24), 'Wigilia Bożego Narodzenia' from years where y >= 2025
  union all select make_date(y, 12, 25), 'Boże Narodzenie (pierwszy dzień)' from years
  union all select make_date(y, 12, 26), 'Boże Narodzenie (drugi dzień)' from years
),
holiday_days as (
  select date, string_agg(name, ', ' order by name) as name
  from holidays
  group by date
),
-- Sundays that are not holidays: the only ones that can trade.
open_sundays as (
  select d.date, extract(year from d.date)::int as y, extract(month from d.date)::int as m
  from days d
  where extract(isodow from d.date) = 7
    and not exists (select 1 from holiday_days h where h.date = d.date)
),
trading_sundays as (
  -- Last Sunday of January, April, June, August (previous Sunday if it is a holiday).
  select max(date) as date from open_sundays where m in (1, 4, 6, 8) group by y, m
  union
  -- Sunday before Easter.
  select easter - 7 from years
  union
  -- Sundays before Christmas: 2 until 2024, 3 from 2025.
  select date from (
    select s.date, s.y,
           row_number() over (partition by s.y order by s.date desc) as n
    from open_sundays s
    where s.date < make_date(s.y, 12, 25) and s.m = 12
  ) dec
  where n <= case when y >= 2025 then 3 else 2 end
),
short_days as (
  select easter - 1 as date from years
  union select make_date(y, 12, 31) from years
  union select make_date(y, 12, 24) from years where y < 2025
),
black_fridays as (
  -- Last Friday of November: step back from 30 November to the nearest Friday (ISO dow 5).
  select make_date(y, 11, 30) - ((extract(isodow from make_date(y, 11, 30))::int + 2) % 7) as date
  from years
),
flags as (
  select
    d.date,
    h.name as holiday_name,
    ts.date is not null as is_trading_sunday,
    h.date is null and (extract(isodow from d.date) <> 7 or ts.date is not null) as is_store_trading_day,
    sd.date is not null as is_short_day
  from days d
  left join holiday_days h on h.date = d.date
  left join trading_sundays ts on ts.date = d.date
  left join short_days sd on sd.date = d.date
)
insert into public.calendar (
  date, year, quarter, month, iso_year, iso_week, day_of_week, is_weekend,
  is_holiday, holiday_name, is_trading_sunday, is_store_trading_day, is_short_trading_day,
  is_black_friday, is_cyber_monday
)
select
  f.date,
  extract(year from f.date),
  extract(quarter from f.date),
  extract(month from f.date),
  extract(isoyear from f.date),
  extract(week from f.date),
  extract(isodow from f.date),
  extract(isodow from f.date) in (6, 7),
  f.holiday_name is not null,
  f.holiday_name,
  f.is_trading_sunday,
  f.is_store_trading_day,
  f.is_short_day and f.is_store_trading_day, -- e.g. 31 Dec on a non-trading Sunday stays closed
  bf.date is not null,
  cm.date is not null
from flags f
left join black_fridays bf on bf.date = f.date
left join black_fridays cm on cm.date + 3 = f.date
order by f.date;
