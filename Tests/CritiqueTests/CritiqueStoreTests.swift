import Foundation
import Testing
@testable import Critique

struct CritiqueStoreMatchesTests {
    /// Thursday Oct 30, 2025 at 2:06 am, local time.
    static let when: Date = {
        var parts = DateComponents()
        parts.year = 2025; parts.month = 10; parts.day = 30; parts.hour = 2; parts.minute = 6
        return Calendar.current.date(from: parts)!
    }()

    static let record: FeedbackRecord = {
        var record = sampleRecord(createdAt: when)
        record.notes = "The Sign up button is way too big [#1]."
        return record
    }()

    func matches(_ query: String, _ record: FeedbackRecord = record) -> Bool {
        CritiqueStore.matches(record, query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
    }

    @Test func wordsSaid() {
        #expect(matches("sign button"))
        #expect(matches("SIGN"))
        #expect(matches("way too big"))
        #expect(!matches("sign nope"))
        #expect(!matches("tiny"))
        #expect(matches(""))
    }

    @Test func project() {
        #expect(matches("critique"))
        #expect(matches("mmerioles/critique"))
        #expect(matches("mmerioles button"))
        #expect(!matches("/Users"))   // the path is not searched
    }

    @Test func phone() {
        #expect(matches("pixel"))
        #expect(matches("pixel 8"))
        #expect(matches("bordgame"))
        #expect(matches("bordgame.app big"))
    }

    @Test func dateAndTime() {
        #expect(matches("oct 30"))
        #expect(matches("october 30"))
        #expect(matches("10/30"))
        #expect(matches("2025"))
        #expect(matches("thursday"))
        #expect(matches("2:06am"))
        #expect(matches("2:06 am"))
        #expect(matches("2am"))
        #expect(!matches("3am"))
        #expect(!matches("oct 31"))
        #expect(!matches("monday"))
        #expect(!matches("today"))
        #expect(!matches("yesterday"))
    }

    @Test func todayAndYesterday() {
        var record = Self.record
        record.createdAt = Date()
        #expect(matches("today", record))
        #expect(!matches("yesterday", record))
        record.createdAt = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        #expect(matches("yesterday", record))
        #expect(!matches("today", record))
    }

    @Test func withoutAProjectOrPhone() {
        var record = Self.record
        record.project = nil
        record.device = nil
        #expect(matches("sign", record))
        #expect(!matches("critique", record))
        #expect(!matches("pixel", record))
    }
}
