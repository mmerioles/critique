import Foundation
import Testing
@testable import Critique

struct UpdaterVersionTests {
    @Test func normalizeDropsTheTagPrefix() {
        #expect(Updater.normalize("v0.2.0") == "0.2.0")
        #expect(Updater.normalize("V1.0.0") == "1.0.0")
        #expect(Updater.normalize(" 0.2.0\n") == "0.2.0")
        #expect(Updater.normalize("0.2.0") == "0.2.0")
    }

    @Test func comparesNumbersByPosition() {
        #expect(Updater.compare("0.2.0", "0.1.2") == .orderedDescending)
        #expect(Updater.compare("0.1.2", "0.2.0") == .orderedAscending)
        #expect(Updater.compare("0.2.0", "0.2.0") == .orderedSame)
        #expect(Updater.compare("v0.2.0", "0.2.0") == .orderedSame)
        // Numbers, not strings: 10 > 9.
        #expect(Updater.compare("0.10.0", "0.9.9") == .orderedDescending)
        #expect(Updater.compare("1.0.0", "0.99.99") == .orderedDescending)
    }

    @Test func missingPartsCountAsZero() {
        #expect(Updater.compare("0.2", "0.2.0") == .orderedSame)
        #expect(Updater.compare("1", "1.0.0") == .orderedSame)
        #expect(Updater.compare("0.2.1", "0.2") == .orderedDescending)
    }

    @Test func aReleaseBeatsItsPrereleases() {
        #expect(Updater.compare("0.3.0", "0.3.0-beta.1") == .orderedDescending)
        #expect(Updater.compare("0.3.0-beta.1", "0.3.0") == .orderedAscending)
        // But a pre-release of a newer number still wins.
        #expect(Updater.compare("0.3.0-rc.1", "0.2.9") == .orderedDescending)
    }

    @Test func prereleasesCompareByIdentifier() {
        #expect(Updater.compare("0.3.0-beta.2", "0.3.0-beta.1") == .orderedDescending)
        #expect(Updater.compare("0.3.0-beta.10", "0.3.0-beta.9") == .orderedDescending)
        #expect(Updater.compare("0.3.0-alpha", "0.3.0-beta") == .orderedAscending)
        #expect(Updater.compare("0.3.0-1", "0.3.0-beta") == .orderedAscending)      // numbers before words
        #expect(Updater.compare("0.3.0-beta", "0.3.0-beta.1") == .orderedAscending) // shorter first
        #expect(Updater.compare("0.3.0-beta.1", "0.3.0-beta.1") == .orderedSame)
    }

    @Test func buildMetadataIsIgnored() {
        #expect(Updater.compare("0.2.0+build.5", "0.2.0") == .orderedSame)
        #expect(Updater.compare("0.2.0+1", "0.2.0+2") == .orderedSame)
    }
}
