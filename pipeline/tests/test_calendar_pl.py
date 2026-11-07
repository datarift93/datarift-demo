from datetime import date

from datarift_pipeline.calendar_pl import (
    black_friday,
    cyber_monday,
    easter_sunday,
    public_holidays,
    trading_sundays,
)


def test_trading_sundays_2024_match_the_db_calendar():
    assert trading_sundays(2024) == [
        date(2024, 1, 28),
        date(2024, 3, 24),
        date(2024, 4, 28),
        date(2024, 6, 30),
        date(2024, 8, 25),
        date(2024, 12, 15),
        date(2024, 12, 22),
    ]


def test_christmas_eve_sunday_is_a_trading_sunday_before_2025():
    december = [d for d in trading_sundays(2023) if d.month == 12]
    assert december == [date(2023, 12, 17), date(2023, 12, 24)]


def test_three_december_trading_sundays_from_2025():
    december = [d for d in trading_sundays(2025) if d.month == 12]
    assert december == [date(2025, 12, 7), date(2025, 12, 14), date(2025, 12, 21)]


def test_christmas_eve_is_a_holiday_from_2025():
    assert date(2024, 12, 24) not in public_holidays(2024)
    assert date(2025, 12, 24) in public_holidays(2025)


def test_easter_and_black_friday():
    assert easter_sunday(2024) == date(2024, 3, 31)
    assert easter_sunday(2025) == date(2025, 4, 20)
    assert black_friday(2024) == date(2024, 11, 29)
    assert cyber_monday(2025) == date(2025, 12, 1)
