import Foundation
import XCTest
@testable import Umma

/// Brief 012 PR 1: what the voice bar shows, asserted on the presentation struct.
@MainActor
final class VoiceBarPresentationTests: XCTestCase {
    private func segment(_ id: Int, _ speaker: VoiceSpeaker, _ text: String, at ms: Int64) -> VoiceSegment {
        VoiceSegment(id: id, speaker: speaker, text: text, startMs: ms, endMs: ms + 500, isFinal: true)
    }

    private func presentation(_ state: VoiceState,
                              user: [VoiceSegment] = [],
                              assistant: [VoiceSegment] = [],
                              partial: VoiceSegment? = nil,
                              notice: String? = nil) -> VoiceBarPresentation {
        VoiceBarPresentation(state: state, userCaptions: user, assistantCaptions: assistant,
                             partial: partial, inputLabel: "iPhone mic", notice: notice)
    }

    func testStatusCopyAndSymbolPerState() {
        let cases: [(VoiceState, VoiceBarPresentation.Mode, String)] = [
            (.starting, .starting, "Starting voice…"),
            (.listening, .listening, "Listening"),
            (.userSpeaking, .hearing, "Hearing you"),
            (.thinking, .thinking, "Thinking…"),
            (.speaking, .speaking, "Umma is speaking"),
            (.paused, .paused, "Paused. Not listening"),
            (.ended(.stopped), .ended, "Voice is off"),
        ]
        for (state, mode, text) in cases {
            let p = presentation(state)
            XCTAssertEqual(p.mode, mode, "\(state)")
            XCTAssertEqual(p.statusText, text, "\(state)")
            XCTAssertFalse(p.symbolName.isEmpty)
        }
    }

    func testInputIsNamedWhileLiveOnly() {
        let live = presentation(.listening).input
        XCTAssertEqual(live?.text, "Mic: iPhone mic")
        XCTAssertEqual(live?.symbolName, "mic.fill")
        XCTAssertEqual(live?.accessibilityLabel, "Listening through iPhone mic")
        XCTAssertEqual(live?.isLive, true)
        for state in [VoiceState.paused, .starting] {
            let off = presentation(state).input
            XCTAssertEqual(off?.isLive, false, "\(state) must not claim a live mic")
            XCTAssertEqual(off?.symbolName, "mic.slash.fill")
            XCTAssertTrue(off?.text.hasPrefix("Mic off") ?? false)
            XCTAssertFalse(off?.accessibilityLabel.contains("Listening") ?? true)
        }
        XCTAssertEqual(presentation(.paused).input?.text, "Mic off (paused)")
        XCTAssertNil(presentation(.ended(.stopped)).input)
    }

    func testCaptionsInterleaveBothSidesByTimeAndKeepTheLastThree() {
        let p = presentation(
            .userSpeaking,
            user: [segment(1, .user, "pork belly first", at: 0), segment(3, .user, "about fifteen", at: 6000)],
            assistant: [segment(2, .assistant, "How long does it simmer?", at: 3000)],
            partial: VoiceSegment(id: -1, speaker: .user, text: "then the", startMs: 9000, endMs: 9200, isFinal: false)
        )
        XCTAssertEqual(p.lines.map(\.text), ["How long does it simmer?", "about fifteen", "then the"])
        XCTAssertEqual(p.lines.map(\.speakerLabel), ["Umma", "You", "You"])
        XCTAssertEqual(p.lines.last?.isPartial, true)
        XCTAssertEqual(p.lines.last?.accessibilityLabel, "You, still talking: then the")
        XCTAssertEqual(Set(p.lines.map(\.id)).count, 3, "ids are unique across sides")
    }

    func testControls() {
        let listening = presentation(.listening)
        XCTAssertTrue(listening.showsPauseToggle)
        XCTAssertEqual(listening.pauseToggleTitle, "Pause")
        XCTAssertTrue(listening.showsStop)
        let paused = presentation(.paused)
        XCTAssertEqual(paused.pauseToggleTitle, "Resume")
        XCTAssertEqual(paused.pauseToggleSymbol, "play.fill")
        XCTAssertFalse(presentation(.starting).showsPauseToggle)
        XCTAssertTrue(presentation(.starting).showsStop, "a start can always be cancelled")
        let ended = presentation(.ended(.silenceTimeout))
        XCTAssertFalse(ended.showsPauseToggle)
        XCTAssertFalse(ended.showsStop)
    }

    func testEndedTextAndAnnouncement() {
        XCTAssertEqual(presentation(.ended(.silenceTimeout)).announcement, "Voice turned off after a long quiet stretch.")
        XCTAssertEqual(presentation(.ended(.stopCommand)).endedText, "Voice is off.")
        XCTAssertEqual(presentation(.ended(.failed("mic busy"))).endedText, "Voice stopped: mic busy")
        XCTAssertEqual(presentation(.speaking).announcement, "Umma is speaking")
        XCTAssertNil(presentation(.listening).endedText)
    }

    func testInterruptedSessionOffersResumeAndClaimsNoMic() async throws {
        let transport = FakeVoiceTransport()
        let session = VoiceSession(transport: transport, clock: FakeVoiceClock())
        try await session.start()
        transport.emit(.interruption(began: true))
        transport.emit(.interruption(began: false))
        let p = VoiceBarPresentation(session: session)
        XCTAssertEqual(p.pauseToggleTitle, "Resume")
        XCTAssertEqual(p.input?.isLive, false)
    }

    func testNoticeIsCarried() {
        XCTAssertEqual(presentation(.listening, notice: PaidVoiceTransport.fallbackNotice).notice,
                       PaidVoiceTransport.fallbackNotice)
    }

    func testBuildsFromALiveSession() async throws {
        let transport = FakeVoiceTransport(inputLabel: "Headset mic")
        let session = VoiceSession(transport: transport, clock: FakeVoiceClock())
        try await session.start()
        transport.emit(.transcript(text: "eggs and rice", isFinal: true))
        await session.say("Got two.")
        let p = VoiceBarPresentation(session: session)
        XCTAssertEqual(p.mode, .listening)
        XCTAssertEqual(p.input?.text, "Mic: Headset mic")
        XCTAssertEqual(p.lines.map(\.text), ["eggs and rice", "Got two."])
    }
}
