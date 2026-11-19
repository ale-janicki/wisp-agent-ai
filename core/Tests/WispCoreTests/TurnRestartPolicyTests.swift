import Foundation
import Testing
@testable import WispCore

@Suite struct TurnRestartPolicyTests {
    private let now = Date()

    private func decide(
        hasProcess: Bool = true, inFlight: Int = 0, telegram: Bool = false, contended: Bool = false,
        ended: Date? = nil, modified: Date? = nil, contextChanged: Bool = false
    ) -> Bool {
        TurnRestartPolicy.shouldRestart(
            hasProcess: hasProcess, turnsInFlight: inFlight, inTelegram: telegram, contended: contended,
            lastTurnEnded: ended, sessionModified: modified, contextChanged: contextChanged
        )
    }

    @Test func aProcessStartedForAnotherTopicRestarts() {
        #expect(decide(contextChanged: true))
        #expect(!decide(inFlight: 1, contextChanged: true))
        #expect(!decide(hasProcess: false, contextChanged: true))
    }

    @Test func aTurnInFlightIsNeverRestarted() {
        #expect(!decide(inFlight: 1, telegram: true, contended: true, ended: now.addingTimeInterval(-60), modified: now))
    }

    @Test func aFreshConversationWithoutStampDoesNotRestart() {
        #expect(!decide(ended: nil, modified: now))
    }

    @Test func contendedSharedOrChangedAfterIdleRestarts() {
        #expect(decide(contended: true))
        #expect(decide(telegram: true))
        #expect(decide(ended: now.addingTimeInterval(-60), modified: now))
    }

    @Test func aWriteInsideTheGraceOrNoProcessDoesNotRestart() {
        #expect(!decide(ended: now, modified: now.addingTimeInterval(1)))
        #expect(!decide(hasProcess: false, contended: true))
    }
}
