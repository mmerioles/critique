import Testing
@testable import Critique

struct BacktickDetectorTests {
    @Test func doubleTapDuringASessionTriggersRightAway() {
        var d = BacktickDetector()
        #expect(d.keyDown(at: 0) == .none)
        #expect(d.keyUp(at: 0.1, inSession: true) == .none)
        #expect(d.keyDown(at: 0.3) == .none)
        #expect(d.keyUp(at: 0.4, inSession: true) == .trigger)
        // The sequence is spent: a third tap starts over.
        #expect(d.keyDown(at: 0.5) == .none)
        #expect(d.keyUp(at: 0.6, inSession: true) == .none)
        #expect(d.keyDown(at: 0.7) == .none)
        #expect(d.keyUp(at: 0.8, inSession: true) == .trigger)
    }

    @Test func doubleTapOutsideASessionWaitsForACodeFence() {
        var d = BacktickDetector()
        #expect(d.keyDown(at: 0) == .none)
        #expect(d.keyUp(at: 0.1, inSession: false) == .none)
        #expect(d.keyDown(at: 0.3) == .none)
        #expect(d.keyUp(at: 0.4, inSession: false) == .armFence)
        #expect(d.fenceElapsed() == .trigger)
        #expect(d.fenceElapsed() == .none)
    }

    @Test func tripleTapIsACodeFence() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0); _ = d.keyUp(at: 0.1, inSession: false)
        _ = d.keyDown(at: 0.3)
        #expect(d.keyUp(at: 0.4, inSession: false) == .armFence)
        #expect(d.keyDown(at: 0.5) == .cancelFence)
        #expect(d.fenceElapsed() == .none)
        // The third ` counts as a first tap again.
        #expect(d.keyUp(at: 0.6, inSession: false) == .none)
        _ = d.keyDown(at: 0.8)
        #expect(d.keyUp(at: 0.9, inSession: false) == .armFence)
    }

    @Test func holdingIsDrawingNotATap() {
        var d = BacktickDetector()
        #expect(d.keyDown(at: 0) == .none)
        #expect(d.keyUp(at: 0.5, inSession: true) == .hold)
        // A hold does not pair with the tap that follows.
        _ = d.keyDown(at: 0.6)
        #expect(d.keyUp(at: 0.7, inSession: true) == .none)
        // Nor does a tap pair with a hold after it.
        _ = d.keyDown(at: 0.8)
        #expect(d.keyUp(at: 1.2, inSession: true) == .hold)
        _ = d.keyDown(at: 1.3)
        #expect(d.keyUp(at: 1.4, inSession: true) == .none)
    }

    @Test func gapTooLongBetweenTaps() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0)
        #expect(d.keyUp(at: 0.1, inSession: true) == .none)
        _ = d.keyDown(at: 1.0)
        #expect(d.keyUp(at: 1.1, inSession: true) == .none)
        // ...but that second tap starts a new pair.
        _ = d.keyDown(at: 1.3)
        #expect(d.keyUp(at: 1.4, inSession: true) == .trigger)
    }

    @Test func gapIsMeasuredFromTheLastRelease() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0)
        _ = d.keyUp(at: 0.2, inSession: true)
        _ = d.keyDown(at: 0.7)
        // Released 0.64 s after the last release: just inside maxGap + maxHold.
        #expect(d.keyUp(at: 0.84, inSession: true) == .trigger)
    }

    @Test func anotherKeyBreaksTheSequence() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0)
        _ = d.keyUp(at: 0.1, inSession: true)
        #expect(d.reset() == .none)
        _ = d.keyDown(at: 0.2)
        #expect(d.keyUp(at: 0.3, inSession: true) == .none)
    }

    @Test func anotherKeyWhileHoldingDropsTheTap() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0)
        _ = d.reset()
        #expect(d.keyUp(at: 0.1, inSession: true) == .none)
        _ = d.keyDown(at: 0.2)
        #expect(d.keyUp(at: 0.3, inSession: true) == .none)
    }

    @Test func anotherKeyWhileWaitingCancelsTheFence() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0); _ = d.keyUp(at: 0.1, inSession: false)
        _ = d.keyDown(at: 0.3)
        #expect(d.keyUp(at: 0.4, inSession: false) == .armFence)
        #expect(d.reset() == .cancelFence)
        #expect(d.fenceElapsed() == .none)
    }

    @Test func autoRepeatIsIgnored() {
        var d = BacktickDetector()
        _ = d.keyDown(at: 0)
        #expect(d.keyDown(at: 0.1, repeated: true) == .none)
        #expect(d.keyDown(at: 0.2, repeated: true) == .none)
        // Still held since 0: this is a hold, not a tap.
        #expect(d.keyUp(at: 0.3, inSession: true) == .hold)
    }

    @Test func releaseWithoutAPressDoesNothing() {
        var d = BacktickDetector()
        #expect(d.keyUp(at: 0.1, inSession: true) == .none)
        #expect(d.keyUp(at: 0.2, inSession: true) == .none)
        _ = d.keyDown(at: 0.3)
        #expect(d.keyUp(at: 0.4, inSession: true) == .none)
    }

    @Test func thresholdsCanBeTuned() {
        var d = BacktickDetector()
        d.maxHold = 1
        d.maxGap = 2
        _ = d.keyDown(at: 0)
        #expect(d.keyUp(at: 0.9, inSession: true) == .none)
        _ = d.keyDown(at: 2.5)
        #expect(d.keyUp(at: 2.9, inSession: true) == .trigger)
    }
}
