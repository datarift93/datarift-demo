"""Polish retail calendar: public holidays, trading Sundays, Black Friday, Cyber Monday."""

from datetime import date, timedelta


def easter_sunday(year: int) -> date:
    """Gregorian Easter (anonymous algorithm, Meeus/Jones/Butcher)."""
    a = year % 19
    b, c = divmod(year, 100)
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    ell = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * ell) // 451
    month, day = divmod(h + ell - 7 * m + 114, 31)
    return date(year, month, day + 1)


def public_holidays(year: int) -> dict[date, str]:
    """Statutory days off work (stores closed). Christmas Eve is a day off from 2025."""
    easter = easter_sunday(year)
    days = {
        date(year, 1, 1): "Nowy Rok",
        date(year, 1, 6): "Trzech Króli",
        easter: "Wielkanoc",
        easter + timedelta(days=1): "Poniedziałek Wielkanocny",
        date(year, 5, 1): "Święto Pracy",
        date(year, 5, 3): "Święto Konstytucji 3 Maja",
        easter + timedelta(days=49): "Zielone Świątki",
        easter + timedelta(days=60): "Boże Ciało",
        date(year, 8, 15): "Wniebowzięcie NMP",
        date(year, 11, 1): "Wszystkich Świętych",
        date(year, 11, 11): "Narodowe Święto Niepodległości",
        date(year, 12, 25): "Boże Narodzenie (1. dzień)",
        date(year, 12, 26): "Boże Narodzenie (2. dzień)",
    }
    if year >= 2025:
        days[date(year, 12, 24)] = "Wigilia"
    return days


def _last_weekday(year: int, month: int, weekday: int) -> date:
    nxt = date(year + (month == 12), month % 12 + 1, 1)
    d = nxt - timedelta(days=1)
    return d - timedelta(days=(d.weekday() - weekday) % 7)


def trading_sundays(year: int) -> list[date]:
    """Sundays with stores open under the 2018 Sunday trading ban (as amended).

    Last Sunday of January, April, June and August, the Sunday before Easter, and the Sundays
    before Christmas: two until 2024, three from 2025 (when Christmas Eve became a holiday).
    """
    sundays = {_last_weekday(year, m, 6) for m in (1, 4, 6, 8)}
    sundays.add(easter_sunday(year) - timedelta(days=7))
    before_christmas = [date(year, 12, d) for d in range(1, 24) if date(year, 12, d).weekday() == 6]
    sundays.update(before_christmas[-(3 if year >= 2025 else 2) :])
    return sorted(sundays)


def short_trading_days(year: int) -> list[date]:
    """Days when stores close early (around 14:00): Holy Saturday, Christmas Eve, New Year's Eve."""
    days = [easter_sunday(year) - timedelta(days=1), date(year, 12, 31)]
    if year < 2025:
        days.append(date(year, 12, 24))
    return sorted(days)


def black_friday(year: int) -> date:
    """Last Friday of November."""
    return _last_weekday(year, 11, 4)


def cyber_monday(year: int) -> date:
    return black_friday(year) + timedelta(days=3)
