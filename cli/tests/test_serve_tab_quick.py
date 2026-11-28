from datetime import datetime, timedelta, timezone

import pytest

from wisp.serve.features.agenda import quick

TZ = timezone(timedelta(hours=-3))
NOW = datetime(2026, 11, 28, 10, 7, tzinfo=TZ)


def parse(text, names=None, now=NOW):
    return quick.parse(text, now, TZ, names or [])


def at(day, hour, minute=0):
    return datetime(2026, 11, 1, hour, minute, tzinfo=TZ) + timedelta(days=day - 1)


def test_blank_text_is_nothing():
    assert parse("   ") is None


def test_tomorrow_with_a_time_calendar_and_place():
    event = parse("Reunião com João amanhã às 14h #trabalho @ Sala 3")
    assert (event.title, event.start, event.end) == ("Reunião com João", at(29, 14), at(29, 15))
    assert (event.calendar_name, event.location, event.all_day) == ("trabalho", "Sala 3", False)


def test_a_known_calendar_name_wins_over_the_words_after_it():
    event = parse("almoço amanhã 12h no calendário pessoal", names=["Pessoal", "Trabalho"])
    assert event.calendar_name == "Pessoal" and event.title == "almoço"


def test_a_date_alone_is_all_day_and_ends_before_midnight():
    event = parse("dentista dia 5 de dezembro")
    assert event.all_day and event.title == "dentista" and event.start == datetime(2026, 12, 5, tzinfo=TZ)
    assert event.end == datetime(2026, 12, 5, 23, 59, 59, tzinfo=TZ) and (event.has_date, event.has_time) == (True, False)


def test_all_day_keyword_and_numeric_dates():
    assert parse("festa 20/12 dia todo").start == datetime(2026, 12, 20, tzinfo=TZ)
    assert parse("viagem 2027-02-03").start == datetime(2027, 2, 3, tzinfo=TZ)
    assert parse("15/03 aniversário").start == datetime(2027, 3, 15, tzinfo=TZ)
    assert parse("12/25 natal").start == datetime(2026, 12, 25, tzinfo=TZ)


@pytest.mark.parametrize("text,start,end", [
    ("almoço sexta 12-13", at(34, 12), at(34, 13)),
    ("call hoje das 15h às 16h30", at(28, 15), at(28, 16, 30)),
    ("standup tomorrow 9am-9:30am", at(29, 9), at(29, 9, 30)),
    ("workshop amanhã das 10 às 11", at(29, 10), at(29, 11)),
])
def test_time_ranges(text, start, end):
    event = parse(text)
    assert (event.start, event.end) == (start, end)


def test_a_time_that_already_passed_means_tomorrow_but_an_explicit_date_stays():
    assert parse("remédio 8h").start == at(29, 8)
    assert parse("remédio 18h").start == at(28, 18)
    assert parse("passado hoje 8h").start == at(28, 8)


def test_relative_starts_and_durations():
    event = parse("ligar pro banco em 2 horas")
    assert (event.title, event.start) == ("ligar pro banco", at(28, 12, 7))
    assert parse("revisar por 90 minutos").end - parse("revisar por 90 minutos").start == timedelta(minutes=90)
    assert parse("foco hoje 14h por 1h30").end == at(28, 15, 30)
    assert parse("foco hoje 14h por meia hora").end == at(28, 14, 30)
    assert parse("daqui a 3 dias viagem").start == datetime(2026, 12, 1, tzinfo=TZ)


def test_with_no_date_or_time_the_event_starts_at_the_next_quarter_hour():
    event = parse("pensar no assunto")
    assert event.start == at(28, 10, 15) and not event.has_date and not event.has_time


def test_next_weekday_is_strictly_after_today_and_day_parts_set_a_time():
    assert parse("entrega próxima segunda").start == datetime(2026, 11, 30, tzinfo=TZ)
    assert parse("treino sábado").start == datetime(2026, 11, 28, tzinfo=TZ)
    assert parse("treino próximo sábado").start == datetime(2026, 12, 5, tzinfo=TZ)
    assert parse("jantar amanhã à noite").start == at(29, 20)
    assert parse("cinema hoje à tarde").start == at(28, 15)


def test_noon_and_a_bare_hour_after_as():
    assert parse("almoço amanhã meio-dia").start == at(29, 12)
    assert parse("lanche amanhã às 4").start == at(29, 16)


def test_an_email_is_not_a_location_and_a_time_after_at_sign_is_not_either():
    event = parse("escrever para ana@exemplo.com amanhã 9h")
    assert event.location is None and "ana@exemplo.com" in event.title
    assert parse("reunião amanhã @ 3pm").start == at(29, 15)


def test_huge_numbers_stay_in_the_title():
    assert "99999999999999999999" in parse("pagar 99999999999999999999 por 99999999999999999999 horas").title
