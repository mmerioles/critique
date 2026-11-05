import Foundation
import Testing
@testable import Critique

/// The pure parsing behind ClaudeAccount; the keychain and network are not tested.
struct ClaudeAccountTests {
    @Test func readsTheTokenClaudeCodeSaves() {
        let saved = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1}}"#.utf8)
        #expect(ClaudeAccount.token(in: saved) == "sk-ant-oat01-abc")
    }

    @Test func noTokenInAnythingElse() {
        #expect(ClaudeAccount.token(in: Data()) == nil)
        #expect(ClaudeAccount.token(in: Data("not json".utf8)) == nil)
        #expect(ClaudeAccount.token(in: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        #expect(ClaudeAccount.token(in: Data(#"{"claudeAiOauth":{}}"#.utf8)) == nil)
        #expect(ClaudeAccount.token(in: Data(#"{"accessToken":"x"}"#.utf8)) == nil)
    }

    @Test func parsesTheUsageWindows() throws {
        let reply = Data(#"{"five_hour":{"utilization":12.5,"resets_at":"2026-11-04T18:00:00.000000+00:00"},"seven_day":{"utilization":40,"resets_at":"2026-11-08T00:00:00Z"}}"#.utf8)
        let usage = try #require(ClaudeAccount.parseUsage(reply))
        #expect(usage.fiveHour?.percent == 12.5)
        #expect(usage.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-04T18:00:00Z"))
        #expect(usage.weekly?.percent == 40)
        #expect(usage.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-08T00:00:00Z"))
    }

    @Test func oneWindowIsEnoughAndAnUnreadableResetIsNil() throws {
        let usage = try #require(ClaudeAccount.parseUsage(Data(#"{"five_hour":{"utilization":3,"resets_at":"soon"}}"#.utf8)))
        #expect(usage.fiveHour?.percent == 3)
        #expect(usage.fiveHour?.resetsAt == nil)
        #expect(usage.weekly == nil)
    }

    @Test func usageWithoutNumbersIsNothing() {
        #expect(ClaudeAccount.parseUsage(Data()) == nil)
        #expect(ClaudeAccount.parseUsage(Data("{}".utf8)) == nil)
        #expect(ClaudeAccount.parseUsage(Data("[]".utf8)) == nil)
        #expect(ClaudeAccount.parseUsage(Data(#"{"five_hour":{"resets_at":"2026-11-04T18:00:00Z"}}"#.utf8)) == nil)
        #expect(ClaudeAccount.parseUsage(Data(#"{"error":{"type":"not_found_error"}}"#.utf8)) == nil)
    }

    @Test func parsesTheModelListAsListed() throws {
        let reply = Data(#"{"data":[{"id":"claude-opus-4-1","display_name":"Claude Opus 4.1"},{"id":"claude-sonnet-4","display_name":"Claude Sonnet 4"},{"id":"mystery"},{"display_name":"no id"}],"has_more":false}"#.utf8)
        let models = try #require(ClaudeAccount.parseModels(reply))
        #expect(models.map(\.id) == ["claude-opus-4-1", "claude-sonnet-4", "mystery"])
        #expect(models.map(\.name) == ["Opus 4.1", "Sonnet 4", "mystery"])
    }

    @Test func modelsWithoutAListIsNothing() {
        #expect(ClaudeAccount.parseModels(Data()) == nil)
        #expect(ClaudeAccount.parseModels(Data("{}".utf8)) == nil)
        #expect(ClaudeAccount.parseModels(Data(#"{"data":"nope"}"#.utf8)) == nil)
        #expect(ClaudeAccount.parseModels(Data(#"{"data":[]}"#.utf8))?.isEmpty == true)
    }

    @Test func modelFamilies() {
        #expect(ClaudeModels.family("claude-opus-4-1") == "opus")
        #expect(ClaudeModels.family("claude-sonnet-4") == "sonnet")
        #expect(ClaudeModels.family("opus") == "opus")
        #expect(ClaudeModels.family("mystery-model") == "mystery-model")
    }
}
