-- Fill public.calendar for 2023-01-01..2027-12-31.
--
-- Sources for the rules:
--   * public holidays: ustawa o dniach wolnych od pracy (1951, as amended);
--     24 December is a public holiday from 2025;
--   * trading Sundays: ustawa o ograniczeniu handlu w niedziele (2018, as amended).
--     Until 2024: last Sunday of January, April, June and August, the Sunday before
--     Easter and the two Sundays before Christmas. From 2025: three Sundays before
--     Christmas. If a last-Sunday date is a holiday, the previous Sunday trades instead
--     (no such case in 2023-2027). The dates are listed explicitly below and checked
--     in 003_calendar.test.sql.
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
  from generate_series('2023-01-01'::date, '2027-12-31'::date, interval '1 day') as d
),
years as (
  select y, private.easter_sunday(y) as easter
  from generate_series(2023, 2027) as y
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
trading_sundays (date) as (
  values
    -- 2023
    ('2023-01-29'::date), ('2023-04-02'), ('2023-04-30'), ('2023-06-25'), ('2023-08-27'),
    ('2023-12-17'), ('2023-12-24'),
    -- 2024
    ('2024-01-28'), ('2024-03-24'), ('2024-04-28'), ('2024-06-30'), ('2024-08-25'),
    ('2024-12-15'), ('2024-12-22'),
    -- 2025
    ('2025-01-26'), ('2025-04-13'), ('2025-04-27'), ('2025-06-29'), ('2025-08-31'),
    ('2025-12-07'), ('2025-12-14'), ('2025-12-21'),
    -- 2026
    ('2026-01-25'), ('2026-03-29'), ('2026-04-26'), ('2026-06-28'), ('2026-08-30'),
    ('2026-12-06'), ('2026-12-13'), ('2026-12-20'),
    -- 2027
    ('2027-01-31'), ('2027-03-21'), ('2027-04-25'), ('2027-06-27'), ('2027-08-29'),
    ('2027-12-05'), ('2027-12-12'), ('2027-12-19')
),
black_fridays as (
  -- Last Friday of November: step back from 30 November to the nearest Friday (ISO dow 5).
  select make_date(y, 11, 30) - ((extract(isodow from make_date(y, 11, 30))::int + 2) % 7) as date
  from years
)
insert into public.calendar (
  date, year, quarter, month, iso_year, iso_week, day_of_week, is_weekend,
  is_holiday, holiday_name, is_trading_sunday, is_store_trading_day,
  is_black_friday, is_cyber_monday
)
select
  d.date,
  extract(year from d.date),
  extract(quarter from d.date),
  extract(month from d.date),
  extract(isoyear from d.date),
  extract(week from d.date),
  extract(isodow from d.date),
  extract(isodow from d.date) in (6, 7),
  h.date is not null,
  h.name,
  ts.date is not null,
  h.date is null and (extract(isodow from d.date) <> 7 or ts.date is not null),
  bf.date is not null,
  cm.date is not null
from days d
left join holiday_days h on h.date = d.date
left join trading_sundays ts on ts.date = d.date
left join black_fridays bf on bf.date = d.date
left join black_fridays cm on cm.date + 3 = d.date
order by d.date;
