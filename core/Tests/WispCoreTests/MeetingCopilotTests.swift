import XCTest
@testable import WispCore

private func words(_ count: Int) -> String {
    (0..<count).map { "palavra\($0)" }.joined(separator: " ")
}

private func segment(_ channel: AudioChannel, _ start: Double, _ end: Double, _ text: String, final: Bool = true) -> MeetingSegment {
    MeetingSegment(start: start, end: end, speaker: channel.speaker, text: text, isFinal: final)
}

final class MeetingMetricsTests: XCTestCase {
    func testTalkShareWordsPerMinuteAndSilencePerChannel() {
        let stats = MeetingMetricsCalculator.compute([
            segment(.mic, 0, 30, words(60)), segment(.system, 30, 40, words(20)),
        ], elapsed: 60)
        XCTAssertEqual(stats.metrics.youShare, 0.75, accuracy: 0.0001)
        XCTAssertEqual(stats.metrics.you.wordsPerMinute, 120, accuracy: 0.01)
        XCTAssertEqual(stats.metrics.others.wordsPerMinute, 120, accuracy: 0.01)
        XCTAssertEqual(stats.metrics.silenceSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(stats.metrics.durationSeconds, 60)
    }

    func testOverlappingLinesOfOneChannelCountTheirTimeOnce() {
        let stats = MeetingMetricsCalculator.compute([segment(.mic, 0, 10, words(5)), segment(.mic, 5, 12, words(5))], elapsed: 12)
        XCTAssertEqual(stats.metrics.you.speakingSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(stats.metrics.silenceSeconds, 0, accuracy: 0.001)
    }

    func testWordsPerMinuteIsZeroUntilThereIsEnoughSpeech() {
        let stats = MeetingMetricsCalculator.compute([segment(.mic, 0, 3, words(9))], elapsed: 3)
        XCTAssertEqual(stats.metrics.you.wordsPerMinute, 0)
    }

    func testQuestionsAreCountedPerSideAndRepeatedMarksCountOnce() {
        let stats = MeetingMetricsCalculator.compute([
            segment(.mic, 0, 5, "Quando fica pronto? E o custo??"),
            segment(.system, 6, 9, "Fica pronto na sexta."),
            segment(.system, 10, 12, "Alguma dúvida?"),
        ], elapsed: 12)
        XCTAssertEqual(stats.metrics.you.questions, 2)
        XCTAssertEqual(stats.metrics.others.questions, 1)
        XCTAssertEqual(stats.lastQuestionAt, 10)
    }

    func testLongestMonologueJoinsCloseLinesAndIgnoresShortInterjections() {
        let stats = MeetingMetricsCalculator.compute([
            segment(.mic, 0, 10, words(10)), segment(.mic, 12, 20, words(10)), segment(.system, 15, 16, "aham"),
            segment(.mic, 22, 30, words(10)), segment(.system, 40, 44, words(6)), segment(.mic, 50, 55, words(6)),
        ], elapsed: 60)
        XCTAssertEqual(stats.metrics.you.longestMonologueSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(stats.metrics.others.longestMonologueSeconds, 4, accuracy: 0.001)
    }

    func testALongerInterruptionBreaksTheMonologue() {
        let stats = MeetingMetricsCalculator.compute([
            segment(.mic, 0, 10, words(10)), segment(.system, 11, 14, words(6)), segment(.mic, 15, 25, words(10)),
        ], elapsed: 30)
        XCTAssertEqual(stats.metrics.you.longestMonologueSeconds, 10, accuracy: 0.001)
    }

    func testOngoingMonologueOnlyWhileTheRunIsStillGoing() {
        let segments = [segment(.mic, 0, 30, words(60))]
        XCTAssertEqual(MeetingMetricsCalculator.compute(segments, elapsed: 33).ongoing, Monologue(channel: .mic, seconds: 30))
        XCTAssertNil(MeetingMetricsCalculator.compute(segments, elapsed: 60).ongoing)
    }

    func testPartialLinesAndEmptyTextAreIgnoredAndMetricsRoundTripWithSpecKeys() throws {
        let stats = MeetingMetricsCalculator.compute([
            segment(.mic, 0, 10, words(10), final: false), segment(.system, 0, 5, "  "),
        ], elapsed: 10)
        XCTAssertEqual(stats.metrics.you.words, 0)
        XCTAssertEqual(stats.metrics.silenceSeconds, 10, accuracy: 0.001)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats.metrics)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["duration_s", "you", "others", "silence_s"])
        let you = json?["you"] as? [String: Any]
        XCTAssertEqual(Set(you?.keys.map { $0 } ?? []), ["words", "speaking_s", "wpm", "questions", "longest_monologue_s"])
    }
}

final class MeetingNudgeTests: XCTestCase {
    private func stats(share: Double = 0.5, ongoing: Monologue? = nil, lastQuestion: Double? = 1) -> MeetingStats {
        var metrics = MeetingMetrics()
        metrics.you.speakingSeconds = 1000 * share
        metrics.others.speakingSeconds = 1000 * (1 - share)
        return MeetingStats(metrics: metrics, ongoing: ongoing, lastQuestionAt: lastQuestion)
    }

    func testTalkShareNudgeNeedsFiveMinutesOfSpeechAndSeventyFivePercent() {
        var engine = NudgeEngine()
        XCTAssertNil(engine.evaluate(stats(share: 0.7), elapsed: 400))
        var short = stats(share: 0.9)
        short.metrics.you.speakingSeconds = 100
        short.metrics.others.speakingSeconds = 10
        XCTAssertNil(engine.evaluate(short, elapsed: 400))
        XCTAssertEqual(engine.evaluate(stats(share: 0.8), elapsed: 400)?.text, "Você está falando 80% do tempo")
    }

    func testMonologueNudgeIsOnlyForTheUserAndAfterThreeMinutes() {
        var engine = NudgeEngine()
        XCTAssertNil(engine.evaluate(stats(ongoing: Monologue(channel: .system, seconds: 400)), elapsed: 100))
        XCTAssertNil(engine.evaluate(stats(ongoing: Monologue(channel: .mic, seconds: 170)), elapsed: 100))
        XCTAssertEqual(engine.evaluate(stats(ongoing: Monologue(channel: .mic, seconds: 190)), elapsed: 200)?.text, "Monólogo de 3 min")
    }

    func testNoQuestionNudgeAfterTenMinutes() {
        var engine = NudgeEngine()
        XCTAssertNil(engine.evaluate(stats(lastQuestion: 300), elapsed: 800))
        XCTAssertEqual(engine.evaluate(stats(lastQuestion: nil), elapsed: 700)?.text, "Nenhuma pergunta há 11 min")
    }

    func testNudgesAreSpacedByTheMinimumGapAndAKindWaitsTwiceAsLong() {
        var engine = NudgeEngine(minimumGap: 300)
        let busy = stats(share: 0.9)
        XCTAssertNotNil(engine.evaluate(busy, elapsed: 400))
        XCTAssertNil(engine.evaluate(busy, elapsed: 500))
        XCTAssertNil(engine.evaluate(busy, elapsed: 699))
        XCTAssertNil(engine.evaluate(busy, elapsed: 750))
        XCTAssertNotNil(engine.evaluate(busy, elapsed: 1000))
    }

    func testADifferentKindFiresAfterTheGapButNotInsideIt() {
        var engine = NudgeEngine(minimumGap: 300)
        XCTAssertEqual(engine.evaluate(stats(ongoing: Monologue(channel: .mic, seconds: 200)), elapsed: 200)?.kind, .monologue)
        XCTAssertNil(engine.evaluate(stats(share: 0.9), elapsed: 400))
        XCTAssertEqual(engine.evaluate(stats(share: 0.9), elapsed: 500)?.kind, .talkShare)
    }
}

final class MeetingEntityTests: XCTestCase {
    func testNamesKeywordsAndCodesAreDetected() {
        let found = EntityDetector.candidates(in: "Ontem falei com a Mariana Costa sobre o projeto Atlas e o contrato 12345 do cliente Aurora.")
        XCTAssertEqual(found, ["Mariana Costa", "Atlas", "12345", "Aurora"])
    }

    func testOrdinarySentencesAndSentenceStartsAreNotEntities() {
        XCTAssertEqual(EntityDetector.candidates(in: "Vamos fechar o orçamento hoje. Então, sexta eu mando. Você viu o sistema lento?"), [])
        XCTAssertEqual(EntityDetector.candidates(in: "Sim. Na Sexta de Março fechamos."), [])
    }

    func testMidSentenceCapitalisedWordAndCodesWithLettersAreEntities() {
        XCTAssertEqual(EntityDetector.candidates(in: "mandei para o Beto o pedido PO-4821 ontem"), ["Beto", "PO-4821"])
    }

    func testResultsAreUniqueAndCapped() {
        let text = (1...10).map { "falei com Pessoa\($0)x" }.joined(separator: ", ") + ", falei com Pessoa1x"
        let found = EntityDetector.candidates(in: text)
        XCTAssertEqual(found.count, EntityDetector.maximum)
        XCTAssertEqual(Set(found).count, found.count)
    }

    func testOnlyTheUsersOwnChannelFeedsTheLookupUnlessOthersAreTurnedOn() {
        let segments = [
            segment(.mic, 0, 4, "falei com a Mariana Costa ontem"),
            segment(.system, 5, 9, "o projeto Atlas atrasou"),
            segment(.mic, 10, 12, "e o contrato 12345", final: false),
        ]
        XCTAssertEqual(EntityDetector.candidates(in: segments, includeOthers: false), ["Mariana Costa"])
        XCTAssertEqual(EntityDetector.candidates(in: segments, includeOthers: true), ["Mariana Costa", "Atlas"])
    }

    func testGateDeduplicatesCaseAndAccentsAndSpacesSearches() {
        var gate = LookupGate(minimumInterval: 20)
        XCTAssertEqual(gate.pick(from: ["Atlas", "Mariana", "Beto"], at: 0), ["Atlas", "Mariana"])
        XCTAssertEqual(gate.pick(from: ["Beto"], at: 10), [])
        XCTAssertEqual(gate.pick(from: ["ATLAS", "mariana", "Beto"], at: 25), ["Beto"])
        XCTAssertEqual(gate.pick(from: ["José"], at: 50), ["José"])
        XCTAssertEqual(gate.pick(from: ["jose"], at: 90), [])
    }

    func testGateStopsAtTheMeetingCap() {
        var gate = LookupGate(minimumInterval: 0)
        var asked = 0
        for round in 0..<60 { asked += gate.pick(from: ["Nome\(round)a", "Nome\(round)b"], at: Double(round)).count }
        XCTAssertEqual(asked, LookupGate.perMeeting)
    }
}

private func output(_ status: Int32, _ text: String = "", timedOut: Bool = false) -> CommandOutput {
    CommandOutput(status: status, stdout: Data(text.utf8), stderr: Data(), timedOut: timedOut)
}

final class BrainLookupTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String]] = []

        func add(_ arguments: [String]) { lock.withLock { list.append(arguments) } }
        var all: [[String]] { lock.withLock { list } }
    }

    func testTheCommandIsAvailableOnlyWhenItsHelpExitsCleanly() {
        XCTAssertTrue(BrainSearchCLI { _ in output(0, "usage: wisp brain search") }.isAvailable())
        XCTAssertFalse(BrainSearchCLI { _ in output(2, "invalid choice: 'search'") }.isAvailable())
        XCTAssertFalse(BrainSearchCLI { _ in output(-1, timedOut: true) }.isAvailable())
        XCTAssertFalse(BrainSearchCLI { _ in nil }.isAvailable())
    }

    func testFeatureDetectionAsksTheHelpOfThePinnedCommand() {
        let calls = Calls()
        _ = BrainSearchCLI { calls.add($0); return output(0) }.isAvailable()
        XCTAssertEqual(calls.all, [["brain", "search", "--help"]])
    }

    func testSearchPassesQueryRootAndLimitAndParsesTheHits() {
        let calls = Calls()
        let json = #"{"results":[{"path":"clientes/atlas.md","title":"Atlas","snippet":"Cliente   desde\n 2024"},{"path":""},{"file":"b.md"}]}"#
        let hits = BrainSearchCLI { calls.add($0); return output(0, json) }.search("Atlas", root: "/tmp/brain", limit: 5)
        XCTAssertEqual(calls.all, [["brain", "search", "Atlas", "--root", "/tmp/brain", "--limit", "5"]])
        XCTAssertEqual(hits, [BrainHit(path: "clientes/atlas.md", title: "Atlas", snippet: "Cliente desde 2024"), BrainHit(path: "b.md", title: "b.md", snippet: "")])
    }

    func testAFailingSearchAndAnOptionLikeQueryGiveNothing() {
        let calls = Calls()
        let cli = BrainSearchCLI { calls.add($0); return output(1, "[]") }
        XCTAssertEqual(cli.search("Atlas", root: "/r", limit: 3), [])
        XCTAssertEqual(cli.search("--root", root: "/r", limit: 3), [])
        XCTAssertEqual(calls.all.count, 1)
    }

    func testParseAcceptsAPlainArrayAndLimitsAndCutsLongSnippets() {
        let long = String(repeating: "a", count: 500)
        let json = "[{\"path\":\"a.md\",\"snippet\":\"\(long)\"},{\"path\":\"b.md\"},{\"path\":\"c.md\"}]"
        let hits = BrainSearchCLI.parse(Data(json.utf8), limit: 2)
        XCTAssertEqual(hits.map(\.path), ["a.md", "b.md"])
        XCTAssertEqual(hits[0].snippet.count, BrainSearchCLI.snippetLimit)
        XCTAssertEqual(BrainSearchCLI.parse(Data("not json".utf8), limit: 2), [])
    }

    func testOpeningAHitNeverLeavesTheBrain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.md"))
        XCTAssertNotNil(BrainHit(path: "a.md", title: "", snippet: "").url(root: root))
        XCTAssertNil(BrainHit(path: "../outside.md", title: "", snippet: "").url(root: root))
        XCTAssertNil(BrainHit(path: "/etc/hosts", title: "", snippet: "").url(root: root))
        XCTAssertNil(BrainHit(path: "missing.md", title: "", snippet: "").url(root: root))
    }
}

final class MeetingBookmarkTests: XCTestCase {
    private let segments = (0..<6).map { segment($0 % 2 == 0 ? .mic : .system, Double($0) * 10, Double($0) * 10 + 5, "linha \($0)") }

    func testABookmarkSitsAfterTheLinesThatStartedBeforeIt() {
        let lines = MeetingBookmarks.lines(segments: segments, bookmarks: [MeetingBookmark(id: "b", time: 25)])
        XCTAssertEqual(lines.map(\.text), ["linha 0", "linha 1", "linha 2", "Momento marcado", "linha 3", "linha 4", "linha 5"])
        XCTAssertEqual(lines.filter(\.isBookmark).count, 1)
    }

    func testBookmarksBeforeEverythingAfterEverythingAndInOrder() {
        let marks = [MeetingBookmark(id: "z", time: 99, label: "fim"), MeetingBookmark(id: "a", time: 0, label: "início")]
        let lines = MeetingBookmarks.lines(segments: segments, bookmarks: marks)
        XCTAssertEqual(lines[1].text, "início")
        XCTAssertEqual(lines.last?.text, "fim")
        XCTAssertEqual(lines.last?.speaker, "Marcador")
        XCTAssertEqual(MeetingBookmarks.lines(segments: [], bookmarks: marks).map(\.text), ["início", "fim"])
    }

    func testSurroundingLinesAreThreeBeforeAndTwoAfterAndSkipPartials() {
        var all = segments
        all.append(segment(.mic, 60, 65, "parcial", final: false))
        XCTAssertEqual(MeetingBookmarks.surrounding(all, at: 25).map(\.text), ["linha 0", "linha 1", "linha 2", "linha 3", "linha 4"])
        XCTAssertEqual(MeetingBookmarks.surrounding(all, at: 0).map(\.text), ["linha 0", "linha 1", "linha 2"])
        XCTAssertEqual(MeetingBookmarks.surrounding(all, at: 100).map(\.text), ["linha 3", "linha 4", "linha 5"])
    }
}

final class MeetingAssistTests: XCTestCase {
    func testReportKeepsThreeItemsAndDropsEmptyOnes() {
        let json = #"{"itens":[{"tipo":"pergunte","texto":"Qual o prazo?"},{"tipo":"lembre","texto":""},{"tipo":"responda","texto":"Aprovado."},{"tipo":"lembre","texto":"Planilha"},{"tipo":"lembre","texto":"Outro"}],"motor":"claude"}"#
        let items = AssistReport.parse(Data(json.utf8))
        XCTAssertEqual(items.map(\.kind), [.ask, .answer, .remember])
        XCTAssertEqual(AssistReport.parse(Data("x".utf8)), [])
        XCTAssertEqual(AssistReport.parse(Data(#"{"itens":[{"tipo":"conselho","texto":"x"}]}"#.utf8)), [])
    }

    func testMergeKeepsNewestFirstDropsRepeatsAndCapsTheList() {
        let first = AssistItem(kind: .ask, text: "Qual o prazo?")
        var shown = AssistReport.merge([first], into: [])
        shown = AssistReport.merge([AssistItem(kind: .ask, text: "qual o PRAZO?"), AssistItem(kind: .remember, text: "Planilha")], into: shown)
        XCTAssertEqual(shown.map(\.text), ["Planilha", "Qual o prazo?"])
        for number in 0..<10 { shown = AssistReport.merge([AssistItem(kind: .remember, text: "item \(number)")], into: shown) }
        XCTAssertEqual(shown.count, AssistReport.shownLimit)
    }

    func testGateRateLimitsNeedsNewSpeechAndNeverOverlaps() {
        var gate = AssistGate(minimumInterval: 40)
        XCTAssertFalse(gate.shouldRun(at: 0, finalCount: 0))
        XCTAssertTrue(gate.shouldRun(at: 5, finalCount: 3))
        gate.started(at: 5, finalCount: 3)
        XCTAssertFalse(gate.shouldRun(at: 100, finalCount: 9))
        gate.finished()
        XCTAssertFalse(gate.shouldRun(at: 100, finalCount: 3))
        XCTAssertFalse(gate.shouldRun(at: 44, finalCount: 9))
        XCTAssertTrue(gate.shouldRun(at: 45, finalCount: 9))
    }

    func testTranscriptWindowHoldsOnlyTheLastMinutesOfFinalLines() {
        let segments = [
            segment(.mic, 10, 15, "antigo"), segment(.system, 400, 405, "recente"), segment(.mic, 410, 415, "parcial", final: false),
        ]
        XCTAssertEqual(AssistTranscript.window(segments, elapsed: 420), "[6:40] Outros: recente")
        let huge = [segment(.mic, 0, 1, String(repeating: "x", count: 9000))]
        XCTAssertEqual(AssistTranscript.window(huge, elapsed: 10).count, AssistTranscript.characterLimit)
    }

    func testPrepReportBecomesCheckableItemsWithQuestionsPrefixed() {
        let report = PrepReport.parse(Data(#"{"checklist":["Levar a planilha"],"perguntas":["Quem decide?"],"motor":"claude"}"#.utf8))
        XCTAssertEqual(report.items.map(\.text), ["Levar a planilha", "Perguntar: Quem decide?"])
        XCTAssertTrue(report.items.allSatisfy { !$0.done })
        XCTAssertEqual(PrepReport.parse(Data("x".utf8)).items, [])
    }

    func testCalendarEventsComeFromTheAgendaJSONWithoutAllDayOnes() {
        let json = #"{"events":[{"id":"e1","title":"Alinhamento","allDay":false,"start":"2027-01-15T09:00","notes":"Ver escopo","attendees":["Ana","Beto"]},{"id":"e2","title":"Feriado","allDay":true}],"truncado":false}"#
        let events = MeetingEvent.parse(Data(json.utf8))
        XCTAssertEqual(events, [MeetingEvent(id: "e1", title: "Alinhamento", start: "2027-01-15T09:00", notes: "Ver escopo", attendees: ["Ana", "Beto"])])
    }

    func testContextJoinsEventChecklistAndBrainNotesAndIsBounded() {
        let event = MeetingEvent(id: "e", title: "Alinhamento", start: "09:00", notes: "Ver escopo", attendees: ["Ana"])
        let context = MeetingContext.build(
            event: event, description: "", checklist: [ChecklistItem(text: "Levar planilha"), ChecklistItem(text: "Feito", done: true)],
            hits: [BrainHit(path: "a.md", title: "Atlas", snippet: "Cliente antigo")]
        )
        XCTAssertTrue(context.contains("Evento: Alinhamento (09:00)") && context.contains("Participantes: Ana"))
        XCTAssertTrue(context.contains("- Levar planilha") && !context.contains("Feito"))
        XCTAssertTrue(context.contains("- Atlas: Cliente antigo"))
        let huge = MeetingContext.build(event: nil, description: String(repeating: "x", count: 20_000), checklist: [], hits: [])
        XCTAssertEqual(huge.count, MeetingContext.characterLimit)
    }
}

final class RecordingLimitTests: XCTestCase {
    private func run(_ clock: inout RecordingLimitClock, from: Double, to: Double) -> [RecordingLimitEvent] {
        var events: [RecordingLimitEvent] = []
        var now = from
        while now < to {
            now += 1
            if let event = clock.tick(at: now) { events.append(event) }
        }
        return events
    }

    func testWarnsFiveMinutesBeforeThenStopsAtTheLimit() {
        var clock = RecordingLimitClock(limit: 7200)
        clock.start(at: 0)
        XCTAssertEqual(run(&clock, from: 0, to: 7300), [.warning(remaining: 300), .reached])
        XCTAssertEqual(clock.remaining(at: 7300), 0)
    }

    func testExplicitPausesDoNotCountTowardTheLimit() {
        var clock = RecordingLimitClock(limit: 600)
        clock.start(at: 0)
        XCTAssertEqual(run(&clock, from: 0, to: 100), [])
        clock.pause(at: 100)
        XCTAssertEqual(run(&clock, from: 100, to: 5000), [])
        XCTAssertEqual(clock.active(at: 5000), 100, accuracy: 0.001)
        clock.resume(at: 5000)
        XCTAssertEqual(run(&clock, from: 5000, to: 5500), [.warning(remaining: 300), .reached])
    }

    func testSleepAndStallsCountBecauseTheLimitIsRealElapsedTime() {
        var clock = RecordingLimitClock(limit: 7200)
        clock.start(at: 0)
        _ = run(&clock, from: 0, to: 60)
        XCTAssertNil(clock.tick(at: 60 + 3600))
        XCTAssertEqual(clock.active(at: 3660), 3660, accuracy: 0.001)
        XCTAssertEqual(clock.tick(at: 7000), .warning(remaining: 200))
        XCTAssertEqual(clock.tick(at: 7300), .reached)
    }

    func testAWakeAfterTheLimitStopsAtOnceWithoutAWarning() {
        var clock = RecordingLimitClock(limit: 7200)
        clock.start(at: 0)
        XCTAssertEqual(clock.tick(at: 9000), .reached)
        XCTAssertNil(clock.tick(at: 9001))
    }

    func testPausingTwiceOrResumingWithoutAPauseChangesNothing() {
        var clock = RecordingLimitClock(limit: 7200)
        clock.start(at: 0)
        clock.resume(at: 10)
        clock.pause(at: 20)
        clock.pause(at: 50)
        clock.resume(at: 60)
        XCTAssertEqual(clock.active(at: 100), 60, accuracy: 0.001)
    }

    func testEachEventFiresOnceAndAShortLimitHasNoWarning() {
        var clock = RecordingLimitClock(limit: 200)
        clock.start(at: 0)
        XCTAssertEqual(run(&clock, from: 0, to: 400), [.reached])
        var none = RecordingLimitClock(limit: 0)
        none.start(at: 0)
        XCTAssertEqual(run(&none, from: 0, to: 400), [])
    }
}

final class MeetingWebhookTests: XCTestCase {
    func testOnlyPublicHttpsUrlsPass() throws {
        XCTAssertEqual(try MeetingWebhook.validate(" https://hooks.example.com/in/abc?x=1 ").host, "hooks.example.com")
        XCTAssertEqual(try MeetingWebhook.validate("HTTPS://OK.Example.COM/x").host, "ok.example.com")
        XCTAssertEqual(try MeetingWebhook.validate("HTTPS://8.8.8.8/hook").host, "8.8.8.8")
        XCTAssertEqual(try MeetingWebhook.validate("https://[2606:4700::1111]/hook").host, "2606:4700::1111")
        XCTAssertThrowsError(try MeetingWebhook.validate("")) { XCTAssertEqual($0 as? WebhookError, .invalid) }
        XCTAssertThrowsError(try MeetingWebhook.validate("not a url")) { XCTAssertEqual($0 as? WebhookError, .invalid) }
        XCTAssertThrowsError(try MeetingWebhook.validate("http://hooks.example.com/x")) { XCTAssertEqual($0 as? WebhookError, .notHTTPS) }
        XCTAssertThrowsError(try MeetingWebhook.validate("ftp://hooks.example.com/x")) { XCTAssertEqual($0 as? WebhookError, .notHTTPS) }
        XCTAssertThrowsError(try MeetingWebhook.validate("https://user:pw@hooks.example.com/x")) { XCTAssertEqual($0 as? WebhookError, .credentials) }
    }

    func testLoopbackPrivateAndLocalHostsAreRefused() {
        let refused = [
            "https://localhost/x", "https://foo.localhost/x", "https://127.0.0.1/x", "https://127.1/x", "https://10.0.0.5/x",
            "https://172.16.4.4/x", "https://172.31.255.255/x", "https://192.168.1.10/x", "https://169.254.169.254/x",
            "https://" + ["100", "64", "0", "1"].joined(separator: ".") + "/x", "https://0.0.0.0/x", "https://224.0.0.1/x", "https://2130706433/x", "https://0x7f000001/x",
            "https://[::1]/x", "https://[::]/x", "https://[fe80::1]/x", "https://[fd00::1]/x", "https://[::ffff:127.0.0.1]/x",
            "https://[::ffff:10.1.2.3]/x", "https://printer.local/x", "https://wiki.internal/x", "https://nas/x", "https://router.lan/x",
        ]
        for text in refused {
            XCTAssertThrowsError(try MeetingWebhook.validate(text), text) {
                guard case .privateHost = $0 as? WebhookError else { return XCTFail("\(text): \($0)") }
            }
        }
        XCTAssertNoThrow(try MeetingWebhook.validate("https://172.32.0.1/x"))
        XCTAssertNoThrow(try MeetingWebhook.validate("https://[::ffff:8.8.8.8]/x"))
    }

    func testActionItemsAreReadFromTheActionsSectionOnly() {
        let note = """
        # T

        ## Resumo
        - [ ] não é ação

        ## Ações
        - [ ] Enviar planilha — responsável: Outros — prazo: sexta
        - [x] Revisar texto — responsável: Você — prazo: não definido
        - [ ] Sem detalhes

        ## Transcrição
        - [ ] nem isto
        """
        XCTAssertEqual(MeetingWebhook.actionItems(in: note), [
            ActionItem(text: "Enviar planilha", owner: "Outros", due: "sexta"),
            ActionItem(text: "Revisar texto", owner: "Você", due: nil),
            ActionItem(text: "Sem detalhes", owner: nil, due: nil),
        ])
    }

    private static let noteWithExtras = """
    ---
    tipo: reuniao
    ---
    # T

    ## Resumo
    Alinhamento do orçamento.
    > Seção não gerada: x

    ## Pontos principais
    ### Orçamento
    - Você: propôs fechar.
    - Outros: envia a planilha.

    ## Ações
    - [ ] Enviar — responsável: Você — prazo: sexta

    ## Métricas

    - Tempo de fala: Você 25% · Outros 75%

    ## Marcadores

    ### 1:06
    > [0:00] Você: segredo da conversa
    > [1:05] Outros: outra frase privada

    ## Checklist

    - [x] item privado da checklist

    ## Transcrição

    [0:00] Você: segredo da conversa
    """

    func testContentIsAWhitelistOfOverviewKeyPointsActionsAndMetrics() throws {
        let content = try MeetingWebhook.content(
            title: "T", startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 60, note: Self.noteWithExtras,
            metrics: MeetingMetrics(durationSeconds: 60)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: content.body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["event", "title", "started_at", "duration_s", "overview", "key_points", "action_items", "metrics"])
        XCTAssertEqual(object["overview"] as? String, "Alinhamento do orçamento.")
        XCTAssertEqual(object["key_points"] as? String, "### Orçamento\n- Você: propôs fechar.\n- Outros: envia a planilha.")
        XCTAssertEqual((object["metrics"] as? [String: Any])?["duration_s"] as? Double, 60)
        XCTAssertEqual((object["action_items"] as? [[String: Any]])?.first?["owner"] as? String, "Você")
    }

    func testNoQuotedLineBookmarkChecklistMetricsTextOrTranscriptReachesTheBody() throws {
        let content = try MeetingWebhook.content(
            title: "T", startedAt: Date(), durationSeconds: 60, note: Self.noteWithExtras, metrics: nil
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: content.body) as? [String: Any])
        for case let text as String in object.values {
            for line in text.split(separator: "\n") { XCTAssertFalse(line.hasPrefix("> "), String(line)) }
        }
        let raw = String(decoding: content.body, as: UTF8.self)
        for forbidden in ["segredo da conversa", "outra frase privada", "item privado", "Tempo de fala", "Marcadores", "Checklist", "Transcrição", "Seção não gerada"] {
            XCTAssertFalse(raw.contains(forbidden), forbidden)
        }
    }

    func testSectionStopsAtTheNextHeadingAndOnlyTheFirstOneCounts() {
        let note = "## Resumo\nUm.\n\n## Ações\n- [ ] A\n\n## Resumo\nDois.\n"
        XCTAssertEqual(MeetingWebhook.section("## Resumo", in: note), "Um.")
        XCTAssertEqual(MeetingWebhook.section("## Pontos principais", in: note), "")
    }

    func testPreviewShowsTheOverviewAndTheCounts() throws {
        let content = try MeetingWebhook.content(title: "T", startedAt: Date(), durationSeconds: 1, note: Self.noteWithExtras, metrics: nil)
        XCTAssertEqual(content.preview, "Alinhamento do orçamento.\n1 tópico(s) · 1 ação(ões)")
        let long = "## Resumo\n" + String(repeating: "a", count: 500) + "\n"
        let cut = try MeetingWebhook.content(title: "T", startedAt: Date(), durationSeconds: 1, note: long, metrics: nil)
        XCTAssertTrue(cut.preview.hasPrefix(String(repeating: "a", count: MeetingWebhook.previewLimit) + "…"))
    }

    private func target(_ text: String) throws -> WebhookTarget { try MeetingWebhook.validate(text) }

    func testSignatureCoversTheTimestampAndTheBody() {
        let body = Data(#"{"a":1}"#.utf8)
        let value = MeetingWebhook.signature(body: body, secret: "segredo-de-teste", timestamp: 1_800_000_000)
        XCTAssertEqual(value, "sha256=2b80e72efea87356c6d92f310ced91f2512b2c974c9695a76e50fe5ba1e2abdb")
        XCTAssertNotEqual(value, MeetingWebhook.signature(body: body, secret: "segredo-de-teste", timestamp: 1_800_000_001))
        XCTAssertNotEqual(value, MeetingWebhook.signature(body: Data(#"{"a":2}"#.utf8), secret: "segredo-de-teste", timestamp: 1_800_000_000))
    }

    func testRequestCarriesTimestampAndSignatureAndNeverInjectsHeaders() throws {
        let pending = PendingWebhook(target: try target("https://hooks.example.com:8443/in/abc?x=1"), body: Data("{}".utf8), signed: true)
        let text = String(decoding: try XCTUnwrap(MeetingWebhook.request(for: pending, secret: "s", timestamp: 1_800_000_000)), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("POST /in/abc?x=1 HTTP/1.1\r\nHost: hooks.example.com:8443\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n") && text.contains("X-Wisp-Timestamp: 1800000000\r\n"))
        XCTAssertTrue(text.contains("X-Wisp-Signature: " + MeetingWebhook.signature(body: Data("{}".utf8), secret: "s", timestamp: 1_800_000_000) + "\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
        XCTAssertNil(MeetingWebhook.request(for: pending, secret: nil, timestamp: 1))
        let plain = PendingWebhook(target: pending.target, body: Data("{}".utf8))
        let unsigned = String(decoding: try XCTUnwrap(MeetingWebhook.request(for: plain, secret: nil, timestamp: 1)), as: UTF8.self)
        XCTAssertFalse(unsigned.contains("X-Wisp-"))
        let bare = PendingWebhook(target: try target("https://hooks.example.com"), body: Data())
        XCTAssertTrue(String(decoding: try XCTUnwrap(MeetingWebhook.request(for: bare, secret: nil, timestamp: 1)), as: UTF8.self).hasPrefix("POST / HTTP/1.1\r\nHost: hooks.example.com\r\n"))
    }

    func testTheHostHeaderUsesTheValidatedHostEvenForIPv6() throws {
        let pending = PendingWebhook(target: try target("https://[2606:4700::1111]:8443/x"), body: Data())
        let text = String(decoding: try XCTUnwrap(MeetingWebhook.request(for: pending, secret: nil, timestamp: 1)), as: UTF8.self)
        XCTAssertTrue(text.contains("Host: [2606:4700::1111]:8443\r\n"))
    }

    func testAmbiguousHostsAreRefusedBecauseParsersCouldDisagree() {
        let refused = [
            "https://ok.example.com\\@evil.example.net/x", "https://ok.example.com\\evil.example.net/x", "https://ok%2Eexample.com/x",
            "https://ok.example.com%2Fevil.example.net/x", "https://exämple.com/x", "https://ok.example.com./x",
            "https://ok.example.com@evil.example.net/x", "https://ok.example.com:evil@evil.example.net/x", "https://ok.example.com /x",
            "https://ok.example.com\t/x", "https://ok.example.com/x\u{7F}",
        ]
        for text in refused { XCTAssertThrowsError(try MeetingWebhook.validate(text), text) }
    }

    func testFailoverStopsOnceTheRequestWasHandedOver() async throws {
        struct Boom: Error {}
        final class Tried: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [String] = []
            func add(_ value: String) { lock.withLock { list.append(value) } }
            var all: [String] { lock.withLock { list } }
        }
        let before = Tried()
        try await WebhookFailover.run(addresses: ["a", "b", "c"]) { address in
            before.add(address)
            return address == "b" ? .delivered : .failedBeforeSend(Boom())
        }
        XCTAssertEqual(before.all, ["a", "b"])
        let after = Tried()
        do {
            try await WebhookFailover.run(addresses: ["a", "b"]) { address in
                after.add(address)
                return .failedAfterSend(Boom())
            }
            XCTFail("should throw")
        } catch is Boom {}
        XCTAssertEqual(after.all, ["a"])
        do {
            try await WebhookFailover.run(addresses: ["a", "b"]) { _ in .failedBeforeSend(Boom()) }
            XCTFail("should throw")
        } catch is Boom {}
        do {
            try await WebhookFailover.run(addresses: []) { _ in .delivered }
            XCTFail("should throw")
        } catch {}
    }

    func testTheCardCanShowTheExactJSONThatWillBeSent() throws {
        let content = try MeetingWebhook.content(title: "T", startedAt: Date(), durationSeconds: 60, note: Self.noteWithExtras, metrics: nil)
        let pending = PendingWebhook(target: try target("https://hooks.example.com/in"), body: content.body, preview: content.preview)
        XCTAssertTrue(pending.bodyText.contains("Você: propôs fechar."))
        XCTAssertTrue(pending.bodyText.contains("Enviar"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(pending.bodyText.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: content.body) as? NSDictionary)
        XCTAssertTrue(pending.bodyText.contains("\n"))
    }

    func testStatusCodeComesFromTheFirstLineOnly() {
        XCTAssertEqual(MeetingWebhook.statusCode(of: Data("HTTP/1.1 204 No Content\r\nX: y".utf8)), 204)
        XCTAssertEqual(MeetingWebhook.statusCode(of: Data("HTTP/1.0 302 Found\r\n".utf8)), 302)
        XCTAssertNil(MeetingWebhook.statusCode(of: Data("garbage".utf8)))
        XCTAssertNil(MeetingWebhook.statusCode(of: Data("HTTP/1.1 20".utf8)))
    }

    func testIPv6TransitionRangesAreJudgedByTheirEmbeddedAddressOrRefused() {
        XCTAssertFalse(MeetingWebhook.isPublic(host: "2002:7f00:1::1"))
        XCTAssertFalse(MeetingWebhook.isPublic(host: "2002:0a00:0001::1"))
        XCTAssertTrue(MeetingWebhook.isPublic(host: "2002:0808:0808::1"))
        XCTAssertFalse(MeetingWebhook.isPublic(host: "2001:0:4136:e378:8000:63bf:3fff:fdd2"))
        XCTAssertFalse(MeetingWebhook.isPublic(host: "2001:db8::1"))
        XCTAssertTrue(MeetingWebhook.isPublic(host: "2606:4700::1111"))
    }

    func testPendingCardShowsHostAndSize() {
        let pending = PendingWebhook(target: try! MeetingWebhook.validate("https://hooks.example.com/in/secret-token?k=v"), body: Data(count: 2048))
        XCTAssertEqual(pending.host, "hooks.example.com")
        XCTAssertEqual(pending.maskedURL, "https://hooks.example.com/•••")
        XCTAssertEqual(PendingWebhook(target: try! MeetingWebhook.validate("https://hooks.example.com:8443/"), body: Data()).maskedURL, "https://hooks.example.com:8443")
        XCTAssertEqual(pending.sizeText, "2.0 KB")
        XCTAssertEqual(PendingWebhook(target: pending.target, body: Data(count: 90)).sizeText, "90 B")
    }

    private actor Sent {
        var bodies: [Data] = []

        func add(_ pending: PendingWebhook) { bodies.append(pending.body) }
    }

    func testNothingIsSentUntilTheUserApprovesAndThenExactlyOnce() async throws {
        let sent = Sent()
        var approval = WebhookApproval()
        let pending = PendingWebhook(target: try! MeetingWebhook.validate("https://hooks.example.com/in"), body: Data("{}".utf8))
        approval.offer(pending, for: "m1")
        let before = await sent.bodies.count
        XCTAssertEqual(before, 0)
        let unknown = try await WebhookDelivery.deliver(approval.approve("other")) { await sent.add($0) }
        XCTAssertFalse(unknown)
        var dismissed = approval
        dismissed.dismiss("m1")
        let none = try await WebhookDelivery.deliver(dismissed.approve("m1")) { await sent.add($0) }
        XCTAssertFalse(none)
        let first = try await WebhookDelivery.deliver(approval.approve("m1")) { await sent.add($0) }
        let second = try await WebhookDelivery.deliver(approval.approve("m1")) { await sent.add($0) }
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let count = await sent.bodies.count
        XCTAssertEqual(count, 1)
    }
}

final class MeetingSettingsAndPipelineTests: XCTestCase {
    func testMeetingSettingsDefaultOffWithATwoHourLimitAndOldFilesStillLoad() throws {
        let old = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime","dashboardOrder":[]}"#.utf8))
        XCTAssertEqual(old.meetings, MeetingSettings())
        XCTAssertFalse(old.meetings.webhookEnabled)
        XCTAssertFalse(old.meetings.webhookSigns)
        XCTAssertEqual(old.meetings.limitSeconds, 7200)
        var changed = old
        changed.meetings.webhookEnabled = true
        changed.meetings.webhookSigns = true
        changed.meetings.limitMinutes = 60
        let back = try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(back.meetings, changed.meetings)
        let broken = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime","meetings":{"limitMinutes":"x"}}"#.utf8))
        XCTAssertEqual(broken.meetings.limitMinutes, 120)
        XCTAssertEqual({ var s = MeetingSettings(); s.limitMinutes = 1; return s.limitSeconds }(), 900)
        let encoded = String(decoding: try JSONEncoder().encode(changed), as: UTF8.self)
        XCTAssertFalse(encoded.contains("webhookURL"))
    }

    private final class Capture: MeetingNoteWriter, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seen: RecordingMeta?

        func writeNote(folder: URL) async throws -> NoteOutcome {
            let meta = try RecordingFolder.read(in: folder)
            lock.withLock { seen = meta }
            try Data("# T\n".utf8).write(to: RecordingFolder.noteURL(in: folder))
            return NoteOutcome(generated: true, title: "T")
        }
    }

    func testMetricsAreInTheMetaBeforeTheNoteEngineRunsAndBookmarksSurvive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try RecordingFolder.create(root: root, date: started)
        var meta = RecordingMeta(startedAt: started, durationSeconds: 60, devices: .init(mic: nil, system: nil), status: .transcribed)
        meta.bookmarks = [MeetingBookmark(id: "b", time: 12, label: "ponto")]
        meta.checklist = [ChecklistItem(id: "c", text: "Levar planilha", done: true)]
        try RecordingFolder.write(meta, in: folder)
        try MeetingTranscriptFile.write(MeetingTranscriptDocument(
            startedAt: started, durationSeconds: 60, engine: "fake", segments: [segment(.mic, 0, 30, words(60)), segment(.system, 30, 40, words(20))]
        ), in: folder)
        let notes = Capture()
        let pipeline = MeetingPipeline(transcriber: MeetingTranscriber(recognizer: NoRecognizer()), notes: notes)
        try await pipeline.regenerateNote(folder: folder)
        let seen = try XCTUnwrap(notes.seen)
        XCTAssertEqual(try XCTUnwrap(seen.metrics).youShare, 0.75, accuracy: 0.0001)
        XCTAssertEqual(seen.bookmarks, [MeetingBookmark(id: "b", time: 12, label: "ponto")])
        XCTAssertEqual(seen.checklist?.first?.done, true)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: RecordingFolder.metaURL(in: folder))) as? [String: Any]
        XCTAssertNotNil(json?["metrics"])
        XCTAssertNotNil(json?["bookmarks"])
    }

    private struct NoRecognizer: SpeechRecognizer {
        let engineName = "none"

        func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] { [] }
    }
}
