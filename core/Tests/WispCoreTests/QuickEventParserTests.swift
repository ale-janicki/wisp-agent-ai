import XCTest
@testable import WispCore

final class QuickEventParserTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Sao_Paulo")!
    private lazy var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()
    private lazy var now = date(2026, 11, 21, 10, 0)
    private let names = ["Pessoal", "Moonxi", "Trabalho Extra"]

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func parse(_ text: String) -> QuickEvent {
        QuickEventParser.parse(text, now: now, calendar: calendar, calendarNames: names)!
    }

    private func assertTimed(_ text: String, _ title: String, _ start: Date, _ end: Date, line: UInt = #line) {
        let r = parse(text)
        XCTAssertEqual(r.title, title, text, line: line)
        XCTAssertEqual(r.start, start, "\(text) start \(r.start)", line: line)
        XCTAssertEqual(r.end, end, "\(text) end \(r.end)", line: line)
        XCTAssertFalse(r.allDay, text, line: line)
    }

    private func assertAllDay(_ text: String, _ title: String, _ day: Date, line: UInt = #line) {
        let r = parse(text)
        XCTAssertEqual(r.title, title, text, line: line)
        XCTAssertTrue(r.allDay, text, line: line)
        XCTAssertEqual(r.start, day, text, line: line)
    }

    func testPortugueseTomorrowWithDuration() {
        assertTimed("almoço amanhã 13h por 1h", "almoço", date(2026, 11, 22, 13), date(2026, 11, 22, 14))
    }

    func testWeekdayRangeAndCalendarName() {
        let r = parse("reunião sexta 10-11 no calendário Moonxi")
        XCTAssertEqual(r.title, "reunião")
        XCTAssertEqual(r.start, date(2026, 11, 27, 10))
        XCTAssertEqual(r.end, date(2026, 11, 27, 11))
        XCTAssertEqual(r.calendarName, "Moonxi")
    }

    func testTomorrowAtBareHour() {
        assertTimed("reunião amanhã às 9", "reunião", date(2026, 11, 22, 9), date(2026, 11, 22, 10))
    }

    func testFridayRangeWithMinutes() {
        assertTimed("sprint review sexta 14h-15h30", "sprint review", date(2026, 11, 27, 14), date(2026, 11, 27, 15, 30))
    }

    func testDayNumberAtHourRollsToNextMonth() {
        assertTimed("dentista dia 3 às 10", "dentista", date(2026, 12, 3, 10), date(2026, 12, 3, 11))
    }

    func testDayNumberLaterThisMonthIsAllDay() {
        assertAllDay("prova dia 25", "prova", date(2026, 11, 25))
    }

    func testProximaSegundaIsAllDay() {
        assertAllDay("dentista próxima segunda", "dentista", date(2026, 11, 23))
    }

    func testNextWeekdayOnSameWeekdayJumpsAWeek() {
        assertAllDay("folga próximo sábado", "folga", date(2026, 11, 28))
        assertAllDay("day off saturday", "day off", date(2026, 11, 21))
    }

    func testTodayAtNight() {
        assertTimed("jantar hoje à noite", "jantar", date(2026, 11, 21, 20), date(2026, 11, 21, 21))
        assertTimed("dinner tonight", "dinner", date(2026, 11, 21, 20), date(2026, 11, 21, 21))
    }

    func testDayParts() {
        assertTimed("treino amanhã de manhã", "treino", date(2026, 11, 22, 9), date(2026, 11, 22, 10))
        assertTimed("café amanhã à tarde", "café", date(2026, 11, 22, 15), date(2026, 11, 22, 16))
        assertTimed("gym tomorrow morning", "gym", date(2026, 11, 22, 9), date(2026, 11, 22, 10))
    }

    func testRelativeTimes() {
        assertTimed("standup em 2 horas", "standup", date(2026, 11, 21, 12), date(2026, 11, 21, 13))
        assertTimed("call in 30 minutes", "call", date(2026, 11, 21, 10, 30), date(2026, 11, 21, 11, 30))
        assertTimed("reunião daqui a 45 min", "reunião", date(2026, 11, 21, 10, 45), date(2026, 11, 21, 11, 45))
        assertTimed("café em meia hora", "café", date(2026, 11, 21, 10, 30), date(2026, 11, 21, 11, 30))
        assertAllDay("entrega em 3 dias", "entrega", date(2026, 11, 24))
        assertAllDay("deadline in 2 weeks", "deadline", date(2026, 12, 5))
    }

    func testEnglishCases() {
        assertTimed("lunch tomorrow at 1pm for 1 hour", "lunch", date(2026, 11, 22, 13), date(2026, 11, 22, 14))
        assertTimed("meeting monday 3pm-4pm", "meeting", date(2026, 11, 23, 15), date(2026, 11, 23, 16))
        assertTimed("conference next friday 9am-5pm", "conference", date(2026, 11, 27, 9), date(2026, 11, 27, 17))
        assertTimed("sync this friday at 11:30", "sync", date(2026, 11, 27, 11, 30), date(2026, 11, 27, 12, 30))
        assertTimed("party dec 31 9pm", "party", date(2026, 12, 31, 21), date(2026, 12, 31, 22))
        assertTimed("call the day after tomorrow at 4pm", "call", date(2026, 11, 23, 16), date(2026, 11, 23, 17))
        assertTimed("lunch noon tomorrow", "lunch", date(2026, 11, 22, 12), date(2026, 11, 22, 13))
    }

    func testMeridiemInheritedByRangeStart() {
        assertTimed("review tomorrow 10-11pm", "review", date(2026, 11, 22, 22), date(2026, 11, 22, 23))
        assertTimed("review tomorrow 11-1pm", "review", date(2026, 11, 22, 11), date(2026, 11, 22, 13))
    }

    func testRangeThatWrapsPastTwelve() {
        assertTimed("aula amanhã 11-1", "aula", date(2026, 11, 22, 11), date(2026, 11, 22, 13))
        assertTimed("plantão amanhã 22h-2h", "plantão", date(2026, 11, 22, 22), date(2026, 11, 23, 2))
    }

    func testNumericDates() {
        assertTimed("dentista 25/12 14:30", "dentista", date(2026, 12, 25, 14, 30), date(2026, 12, 25, 15, 30))
        assertTimed("dentist 12/25 10am", "dentist", date(2026, 12, 25, 10), date(2026, 12, 25, 11))
        assertAllDay("viagem 12/12 dia todo", "viagem", date(2026, 12, 12))
        assertAllDay("evento 2027-02-03", "evento", date(2027, 2, 3))
        assertAllDay("aniversário 5/3", "aniversário", date(2027, 3, 5))
        assertAllDay("formatura 10/06/2027", "formatura", date(2027, 6, 10))
    }

    func testMonthNames() {
        assertAllDay("aniversário 5 de março", "aniversário", date(2027, 3, 5))
        assertAllDay("natal 25 de dezembro", "natal", date(2026, 12, 25))
        assertAllDay("launch on march 3rd", "launch", date(2027, 3, 3))
        assertTimed("reunião 10 de dezembro 14h-15h30", "reunião", date(2026, 12, 10, 14), date(2026, 12, 10, 15, 30))
    }

    func testAllDayKeywords() {
        let r = parse("conferência amanhã dia todo")
        XCTAssertTrue(r.allDay)
        XCTAssertEqual(r.title, "conferência")
        XCTAssertTrue(parse("offsite friday all day").allDay)
        XCTAssertEqual(parse("offsite friday all day").end, date(2026, 11, 27, 23, 59).addingTimeInterval(59))
    }

    func testDurationForms() {
        assertTimed("call hoje 11h30 por 45min", "call", date(2026, 11, 21, 11, 30), date(2026, 11, 21, 12, 15))
        assertTimed("aula amanhã 14h por 1h30", "aula", date(2026, 11, 22, 14), date(2026, 11, 22, 15, 30))
        assertTimed("workshop tomorrow 2pm for 90 minutes", "workshop", date(2026, 11, 22, 14), date(2026, 11, 22, 15, 30))
        assertTimed("chat tomorrow 2pm for half an hour", "chat", date(2026, 11, 22, 14), date(2026, 11, 22, 14, 30))
        assertTimed("papo amanhã 14h por meia hora", "papo", date(2026, 11, 22, 14), date(2026, 11, 22, 14, 30))
        assertTimed("curso amanhã 8h por 2 horas e 15 minutos", "curso", date(2026, 11, 22, 8), date(2026, 11, 22, 10, 15))
        assertTimed("curso amanhã 8h por 1.5h", "curso", date(2026, 11, 22, 8), date(2026, 11, 22, 9, 30))
    }

    func testTimeWithoutDateGoesToNextOccurrence() {
        assertTimed("reunião 9h", "reunião", date(2026, 11, 22, 9), date(2026, 11, 22, 10))
        assertTimed("reunião 15h", "reunião", date(2026, 11, 21, 15), date(2026, 11, 21, 16))
        assertTimed("yoga 7am", "yoga", date(2026, 11, 22, 7), date(2026, 11, 22, 8))
        assertTimed("sync at 3", "sync", date(2026, 11, 21, 15), date(2026, 11, 21, 16))
        assertTimed("almoço meio-dia", "almoço", date(2026, 11, 21, 12), date(2026, 11, 21, 13))
    }

    func testSameWeekdayTodayStillAhead() {
        assertTimed("sábado 20h jantar com a Ana", "jantar com a Ana", date(2026, 11, 21, 20), date(2026, 11, 21, 21))
    }

    func testCalendarNameForms() {
        XCTAssertEqual(parse("call tomorrow 3pm on calendar Work Stuff").calendarName, "Work Stuff")
        XCTAssertEqual(parse("reunião amanhã 10h #Moonxi").calendarName, "Moonxi")
        let known = parse("reunião amanhã 10h no calendário trabalho extra")
        XCTAssertEqual(known.calendarName, "Trabalho Extra")
        XCTAssertEqual(known.title, "reunião")
        let accent = parse("almoço amanhã 12h no calendario pessoal")
        XCTAssertEqual(accent.calendarName, "Pessoal")
        XCTAssertEqual(accent.start, date(2026, 11, 22, 12))
        XCTAssertEqual(parse("review sexta 10h no calendário Desconhecido").calendarName, "Desconhecido")
    }

    func testCalendarNameFollowedByMoreText() {
        let r = parse("reunião no calendário Moonxi sexta 10h")
        XCTAssertEqual(r.calendarName, "Moonxi")
        XCTAssertEqual(r.start, date(2026, 11, 27, 10))
    }

    func testLocation() {
        let r = parse("reunião amanhã 15h @ Sala 3")
        XCTAssertEqual(r.location, "Sala 3")
        XCTAssertEqual(r.title, "reunião")
        XCTAssertEqual(parse("workshop friday 2pm @ Office").location, "Office")
        XCTAssertEqual(parse("almoço amanhã local: Restaurante X").location, "Restaurante X")
        let both = parse("reunião amanhã 15h @ Sala 3 no calendário Moonxi")
        XCTAssertEqual(both.location, "Sala 3")
        XCTAssertEqual(both.calendarName, "Moonxi")
    }

    func testEmailAndTimeAtSignAreNotLocations() {
        let mail = parse("falar com ana@x.com amanhã")
        XCTAssertNil(mail.location)
        XCTAssertEqual(mail.title, "falar com ana@x.com")
        let atTime = parse("meeting @ 3pm tomorrow")
        XCTAssertNil(atTime.location)
        XCTAssertEqual(atTime.start, date(2026, 11, 22, 15))
    }

    func testAmbiguousInputStaysPlainTitle() {
        for text in ["Comprar pão", "Dentista", "Prova 2", "Comprar 3 pães", "Projeto v2.0", "Reunião de alinhamento",
                     "Almoço com a Maria", "Ligar out", "Reunião mar", "Café 15 min", "Reunião com 2-3 pessoas", "Estudar 1 hora por dia"] {
            let r = parse(text)
            XCTAssertFalse(r.hasDate, text)
            XCTAssertFalse(r.hasTime, text)
        }
        XCTAssertEqual(parse("Comprar pão").title, "Comprar pão")
        XCTAssertEqual(parse("Reunião com 2-3 pessoas").title, "Reunião com 2-3 pessoas")
        XCTAssertEqual(parse("Prova 2").title, "Prova 2")
        XCTAssertEqual(parse("Café 15 min").title, "Café 15 min")
    }

    func testPlainTitleStartsAtNextQuarterHour() {
        let r = parse("Comprar pão")
        XCTAssertEqual(r.start, date(2026, 11, 21, 10, 15))
        XCTAssertEqual(r.end, date(2026, 11, 21, 11, 15))
    }

    func testDefaultDurationIsConfigurable() {
        let r = QuickEventParser.parse("foco amanhã 9h", now: now, calendar: calendar, defaultMinutes: 25)!
        XCTAssertEqual(r.end, date(2026, 11, 22, 9, 25))
    }

    func testTrailingConnectorsAreDropped() {
        XCTAssertEqual(parse("Estudar inglês amanhã às 9").title, "Estudar inglês")
        XCTAssertEqual(parse("Study english tomorrow at 9").title, "Study english")
        XCTAssertEqual(parse("reunião sexta das 10 às 11").title, "reunião")
    }

    func testDasAsRange() {
        assertTimed("reunião sexta das 10 às 11", "reunião", date(2026, 11, 27, 10), date(2026, 11, 27, 11))
        assertTimed("reunião sexta de 9h até 10h30", "reunião", date(2026, 11, 27, 9), date(2026, 11, 27, 10, 30))
        assertTimed("meeting friday from 9 to 10", "meeting", date(2026, 11, 27, 9), date(2026, 11, 27, 10))
    }

    func testDayNumberDoesNotBecomeATimeRange() {
        assertTimed("dentista dia 20 às 14h", "dentista", date(2026, 12, 20, 14), date(2026, 12, 20, 15))
    }

    func testEmptyInput() {
        XCTAssertNil(QuickEventParser.parse("   ", now: now, calendar: calendar))
        XCTAssertEqual(parse("amanhã").title, "")
    }

    func testAccentsAndCaseInsensitive() {
        assertTimed("ALMOÇO AMANHÃ ÀS 13H", "ALMOÇO", date(2026, 11, 22, 13), date(2026, 11, 22, 14))
        assertTimed("Reunião Terça-Feira 10h", "Reunião", date(2026, 11, 24, 10), date(2026, 11, 24, 11))
        assertTimed("Aula quarta feira 8h", "Aula", date(2026, 11, 25, 8), date(2026, 11, 25, 9))
    }
}
