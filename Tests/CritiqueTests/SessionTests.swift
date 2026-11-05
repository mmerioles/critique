import Foundation
import Testing
@testable import Critique

@MainActor
struct SessionTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func listening() -> Session {
        let session = Session()
        session.mode = .listening
        return session
    }

    @Test func markerLandsNextToTheWordsSaidThen() {
        let session = listening()
        let text = "the header looks fine but this button is too big"
        // Words 0.5 s apart: "fine" at 1.5, "but" at 2.0, "this" at 2.5.
        session.updateSpeech(text, words: wordTimes(text, from: start))
        let number = session.addShot({ makeShot($0, .pointer, at: start) }, at: start.addingTimeInterval(2.25))
        #expect(number == 1)
        #expect(session.live == "the header looks fine but [#1] this button is too big")
        #expect(session.transcript == session.live)
        #expect(session.shots.count == 1)
        #expect(session.shots[0].time == start.addingTimeInterval(2.25))
    }

    @Test func markerBeforeTheFirstWordAndAfterTheLast() {
        let session = listening()
        let text = "this button is too big"
        session.updateSpeech(text, words: wordTimes(text, from: start))
        session.addShot({ makeShot($0, .click, at: start) }, at: start.addingTimeInterval(-1))
        session.addShot({ makeShot($0, .click, at: start) }, at: start.addingTimeInterval(10))
        // A marker after the last word trails the live text, waiting for more words.
        #expect(session.live == "[#1] this button is too big [#2]")
    }

    @Test func commitSpeechKeepsLeftoverMarkersForTheNextWords() {
        let session = listening()
        let first = "this button is too big"
        session.updateSpeech(first, words: wordTimes(first, from: start))
        session.addShot({ makeShot($0, .pointer, at: start) }, at: start.addingTimeInterval(5))
        session.commitSpeech()
        #expect(session.committed == "this button is too big")
        // The leftover marker still shows at the end of the live text.
        #expect(session.live == "[#1]")
        #expect(session.spoken.map(\.text) == ["this", "button", "is", "too", "big"])

        let second = "and the text is cut off"
        session.updateSpeech(second, words: wordTimes(second, from: start.addingTimeInterval(6)))
        #expect(session.live == "[#1] and the text is cut off")
        #expect(session.transcript == "this button is too big [#1] and the text is cut off")
        session.commitSpeech()
        #expect(session.committed == "this button is too big [#1] and the text is cut off")
        #expect(session.spoken.count == 11)
    }

    @Test func finalizeTextPutsLeftoverMarkersAtTheEnd() {
        let session = listening()
        let text = "this button is too big"
        session.updateSpeech(text, words: wordTimes(text, from: start))
        session.addShot({ makeShot($0, .pointer, at: start) }, at: start.addingTimeInterval(5))
        session.addShot({ makeShot($0, .drawing, at: start) }, at: start.addingTimeInterval(6))
        session.finalizeText()
        #expect(session.committed == "this button is too big [#1] [#2]")
        #expect(session.live == "")
        // Nothing left over: finalizing again changes nothing.
        session.finalizeText()
        #expect(session.committed == "this button is too big [#1] [#2]")
    }

    @Test func finalizeWithNoSpeechAtAll() {
        let session = listening()
        session.addShot({ makeShot($0, .pointer, at: start) }, at: start)
        session.finalizeText()
        #expect(session.committed == "[#1]")
    }

    @Test func markerGoesAtTheEndWhileTyping() {
        let session = Session()
        session.mode = .typing
        session.committed = "the button is too big"
        session.addShot({ makeShot($0, .pointer, at: start) }, at: start)
        #expect(session.committed == "the button is too big [#1]")
        #expect(session.live == "")
    }

    @Test func markerGoesAtTheEndWithoutAMicrophone() {
        let session = listening()
        session.micAvailable = false
        session.addShot({ makeShot($0, .click, at: start) }, at: start)
        #expect(session.committed == "[#1]")
    }

    @Test func shotWithoutATimeGetsNoMarker() {
        let session = listening()
        let text = "hello there"
        session.updateSpeech(text, words: wordTimes(text, from: start))
        session.addShot({ makeShot($0, .screen, at: start) })
        #expect(session.live == "hello there")
        #expect(session.shots[0].time == session.startedAt)
    }

    @Test func shotsAreNumberedInOrder() {
        let session = listening()
        let a = session.addShot({ makeShot($0, .pointer, at: start) }, at: start)
        let b = session.addShot({ makeShot($0, .click, at: start) }, at: start)
        #expect(a == 1 && b == 2)
        #expect(session.shots.map(\.number) == [1, 2])
    }

    @Test func replaceTranscriptRePlacesMarkersByTime() {
        let session = listening()
        let text = "the header looks fine but this button is too big"
        session.updateSpeech(text, words: wordTimes(text, from: start))
        session.addShot({ makeShot($0, .screen, at: start) })                                      // #1 never marked
        session.addShot({ makeShot($0, .pointer, at: start) }, at: start.addingTimeInterval(2.25)) // before "this"
        session.addShot({ makeShot($0, .click, at: start) }, at: start.addingTimeInterval(0.2))    // before "header"
        session.addShot({ makeShot($0, .drawing, at: start) }, at: start.addingTimeInterval(99))   // after everything
        session.finalizeText()
        #expect(session.committed == "the [#3] header looks fine but [#2] this button is too big [#4]")

        // A better transcript from the recording, out of order to make sure it's sorted.
        let better = spokenWords("The header looks fine, but this button is way too big.", from: start, step: 0.5)
        session.replaceTranscript(with: better.reversed())
        #expect(session.committed == "The [#3] header looks fine, but [#2] this button is way too big. [#4]")
        #expect(session.transcript == session.committed)
        #expect(session.spoken.map(\.text) == better.map(\.text))
    }

    @Test func logSkipsRepeatedHovers() {
        let session = listening()
        session.log(.hover, "button “Sign up”", at: start)
        session.log(.hover, "button “Sign up”", at: start.addingTimeInterval(1))
        session.log(.click, "button “Sign up”", at: start.addingTimeInterval(2))
        session.log(.hover, "link “Cancel”", at: start.addingTimeInterval(3))
        session.log(.hover, "button “Sign up”", at: start.addingTimeInterval(4))
        #expect(session.interactions.map(\.kind) == [.hover, .click, .hover, .hover])
    }

    @Test func resetClearsEverything() {
        let session = listening()
        let text = "hello there"
        session.updateSpeech(text, words: wordTimes(text, from: start))
        session.addShot({ makeShot($0, .pointer, at: start) }, at: start)
        session.log(.click, "x")
        session.finalizeText()
        session.reset()
        #expect(session.committed == "")
        #expect(session.transcript == "")
        #expect(session.shots.isEmpty)
        #expect(session.spoken.isEmpty)
        #expect(session.interactions.isEmpty)
        #expect(session.micAvailable)
    }
}
