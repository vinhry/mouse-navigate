import XCTest
@testable import MouseNavigateCore

final class SemanticVersionTests: XCTestCase {
    private func v(_ text: String) -> SemanticVersion {
        SemanticVersion(text)!
    }

    func testParsesTagsAndPlainVersions() {
        XCTAssertEqual(v("v0.4.0").numbers, [0, 4, 0])
        XCTAssertEqual(v("0.3.2").numbers, [0, 3, 2])
        XCTAssertEqual(v("1.2").numbers, [1, 2])
        XCTAssertEqual(v("v1.0.0-beta.2").preRelease, "beta.2")
        XCTAssertEqual(v("1.0.0+5").description, "1.0.0")
    }

    func testRejectsNonsense() {
        for text in ["", "v", "latest", "1..2", "1.x", "-1.0", "1.0.0-", "1.2.3.4.5"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(v("0.3.2"), v("0.4.0"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertLessThan(v("0.4.0-beta.1"), v("0.4.0"))
        XCTAssertLessThan(v("0.4.0-beta.2"), v("0.4.0-beta.10"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertFalse(v("0.4.0") < v("0.4.0"))
    }
}

final class UpdateCandidateTests: XCTestCase {
    private let current = SemanticVersion("0.3.2")!

    private func release(
        tag: String = "v0.4.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String = "MouseNavigate.zip",
        size: Int = 834_811,
        url: String = "https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip"
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            htmlURL: URL(string: "https://github.com/vinhry/mouse-navigate/releases/tag/\(tag)")!,
            body: "Notes",
            draft: draft,
            prerelease: prerelease,
            assets: [.init(name: assetName, size: size, browserDownloadURL: URL(string: url)!)]
        )
    }

    func testDecodesGitHubsAnswer() throws {
        // Trimmed from the real answer for v0.3.2.
        let json = """
        {"tag_name":"v0.3.2","html_url":"https://github.com/vinhry/mouse-navigate/releases/tag/v0.3.2",
         "draft":false,"prerelease":false,"body":"**Full Changelog**",
         "assets":[{"name":"MouseNavigate.zip","size":834811,"content_type":"application/zip",
           "browser_download_url":"https://github.com/vinhry/mouse-navigate/releases/download/v0.3.2/MouseNavigate.zip"}]}
        """
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tagName, "v0.3.2")
        XCTAssertEqual(decoded.assets.first?.size, 834_811)
    }

    func testNewerReleaseIsSelected() {
        let candidate = UpdateCandidate.select(from: release(), current: current)
        XCTAssertEqual(candidate?.version, SemanticVersion("0.4.0"))
        XCTAssertEqual(candidate?.size, 834_811)
    }

    func testSameOrOlderIsNot() {
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "v0.3.2"), current: current))
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "v0.3.1"), current: current))
    }

    func testDraftsAndPreReleasesAreSkipped() {
        XCTAssertNil(UpdateCandidate.select(from: release(draft: true), current: current))
        XCTAssertNil(UpdateCandidate.select(from: release(prerelease: true), current: current))
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "v0.4.0-beta.1"), current: current))
    }

    func testOnlyTheExpectedAssetOverHTTPSAtASaneSize() {
        XCTAssertNil(UpdateCandidate.select(from: release(assetName: "Other.zip"), current: current))
        XCTAssertNil(UpdateCandidate.select(from: release(size: 0), current: current))
        XCTAssertNil(UpdateCandidate.select(from: release(size: UpdateCandidate.maximumSize + 1), current: current))
        XCTAssertNil(UpdateCandidate.select(from: release(url: "http://example.com/MouseNavigate.zip"), current: current))
    }

    func testUnreadableTagIsSkipped() {
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "latest"), current: current))
    }
}

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDueWhenNeverCheckedOrADayHasPassed() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
    }

    func testClockSetBackCountsAsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3_600), now: now))
    }
}

final class InstallLocationTests: XCTestCase {
    func testWhereTheAppCanReplaceItself() {
        XCTAssertNil(InstallLocationProblem.check(bundlePath: "/Applications/MouseNavigate.app", isWritable: true))
        XCTAssertEqual(
            InstallLocationProblem.check(bundlePath: "/Applications/MouseNavigate.app", isWritable: false),
            .notWritable
        )
        XCTAssertEqual(
            InstallLocationProblem.check(
                bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234/d/MouseNavigate.app",
                isWritable: true
            ),
            .translocated
        )
        XCTAssertEqual(
            InstallLocationProblem.check(bundlePath: "/Users/me/project/.build/debug", isWritable: true),
            .notABundle
        )
    }
}
