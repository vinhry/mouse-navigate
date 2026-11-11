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
    private let repository = GitHubRepository(owner: "vinhry", name: "mouse-navigate")

    private func release(
        tag: String = "v0.4.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String = "MouseNavigate.zip",
        size: Int = 834_811,
        url: String = "https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
        page: String? = nil
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            htmlURL: URL(string: page ?? "https://github.com/vinhry/mouse-navigate/releases/tag/\(tag)")!,
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
        let candidate = UpdateCandidate.select(from: release(), current: current, repository: repository)
        XCTAssertEqual(candidate?.version, SemanticVersion("0.4.0"))
        XCTAssertEqual(candidate?.size, 834_811)
    }

    func testSameOrOlderIsNot() {
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "v0.3.2"), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "v0.3.1"), current: current, repository: repository))
    }

    func testDraftsAndPreReleasesAreSkipped() {
        XCTAssertNil(UpdateCandidate.select(from: release(draft: true), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(prerelease: true), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "v0.4.0-beta.1"), current: current, repository: repository))
    }

    func testOnlyTheExpectedAssetOverHTTPSAtASaneSize() {
        XCTAssertNil(UpdateCandidate.select(from: release(assetName: "Other.zip"), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(size: 0), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(size: UpdateCandidate.maximumSize + 1), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(url: "http://example.com/MouseNavigate.zip"), current: current, repository: repository))
    }

    func testReleasePageMustBeAWebAddress() {
        XCTAssertNil(UpdateCandidate.select(from: release(page: "file:///Applications/Utilities/Terminal.app"), current: current, repository: repository))
        XCTAssertNil(UpdateCandidate.select(from: release(page: "x-apple.systempreferences:com.apple.preference.security"), current: current, repository: repository))
        XCTAssertNotNil(UpdateCandidate.select(from: release(page: "https://github.com/vinhry/mouse-navigate/releases"), current: current, repository: repository))
    }

    func testUnreadableTagIsSkipped() {
        XCTAssertNil(UpdateCandidate.select(from: release(tag: "latest"), current: current, repository: repository))
    }

    func testTheAssetMustBeThisRepositorysReleaseDownload() {
        func selects(_ url: String) -> Bool {
            UpdateCandidate.select(from: release(url: url), current: current, repository: repository) != nil
        }
        XCTAssertTrue(selects("https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip"))
        XCTAssertTrue(selects("https://GitHub.com/Vinhry/Mouse-Navigate/releases/download/v0.4.0/MouseNavigate.zip"))
        XCTAssertTrue(selects("https://github.com:443/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip"))

        for url in [
            // Somewhere else entirely, or GitHub over plain http.
            "https://example.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            "http://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            "https://github.com.example.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            "https://github.com@example.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            "https://github.com:8443/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            // Another repository's release, or not a release download.
            "https://github.com/someone/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            "https://github.com/vinhry/other/releases/download/v0.4.0/MouseNavigate.zip",
            "https://github.com/vinhry/mouse-navigate/raw/main/MouseNavigate.zip",
            "https://github.com/vinhry/mouse-navigate/releases/download/MouseNavigate.zip",
            // The asset store directly, which a release download only reaches by redirect.
            "https://objects.githubusercontent.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip",
            // Climbing out of the release path, plainly or encoded.
            "https://github.com/vinhry/mouse-navigate/releases/download/../../../someone/x/releases/download/v1/MouseNavigate.zip",
            "https://github.com/vinhry/mouse-navigate/releases/download/%2E%2E/MouseNavigate.zip",
            "https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0%2F..%2F..%2Fx/MouseNavigate.zip",
            "https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip/",
            "https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/Other.zip",
            "https://github.com/vinhry/mouse-navigate/releases/download/v0.4.0/MouseNavigate.zip?x=1",
        ] {
            XCTAssertFalse(selects(url), url)
        }
    }
}

final class GitHubRepositoryTests: XCTestCase {
    func testReadFromTheLatestReleaseAddress() {
        let repository = GitHubRepository(latestReleaseURL: URL(string: "https://api.github.com/repos/vinhry/mouse-navigate/releases/latest")!)
        XCTAssertEqual(repository, GitHubRepository(owner: "vinhry", name: "mouse-navigate"))

        for address in [
            "http://api.github.com/repos/vinhry/mouse-navigate/releases/latest",
            "https://example.com/repos/vinhry/mouse-navigate/releases/latest",
            "https://api.github.com/repos/vinhry/releases/latest",
            "https://api.github.com/repos/vinhry/mouse-navigate/releases",
            "https://api.github.com/repos//mouse-navigate/releases/latest",
        ] {
            XCTAssertNil(GitHubRepository(latestReleaseURL: URL(string: address)!), address)
        }
    }

    func testRedirectsStayOnGitHubsDownloadHosts() {
        for address in [
            "https://github.com/vinhry/mouse-navigate/releases/download/v0.8.0/MouseNavigate.zip",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/2?X-Amz-Signature=abc",
            "https://release-assets.githubusercontent.com/github-production-release-asset/1203320383/8e6c?sp=r&sig=abc",
            "https://RELEASE-ASSETS.githubusercontent.com/x",
            // Wherever GitHub moves its asset store next, under the same domain.
            "https://assets-2.githubusercontent.com/x",
            "https://githubusercontent.com/x",
        ] {
            XCTAssertTrue(GitHubRepository.mayRedirect(to: URL(string: address)!), address)
        }
        for address in [
            "http://release-assets.githubusercontent.com/x",
            "https://example.com/MouseNavigate.zip",
            "https://githubusercontent.com.evil.example/x",
            "https://evilgithubusercontent.com/x",
            "https://github.com.evil.example/x",
            "https://evilgithub.com/x",
            "https://api.github.com/x",
            "https://user:pass@objects.githubusercontent.com/x",
            "https://objects.githubusercontent.com:8443/x",
            "file:///tmp/MouseNavigate.zip",
        ] {
            XCTAssertFalse(GitHubRepository.mayRedirect(to: URL(string: address)!), address)
        }
    }
}

/// Answers every request itself, so the redirect guard is tried against a real URLSession
/// without anything leaving the machine.
private final class RedirectingProtocol: URLProtocol {
    /// Where a request to github.com is redirected.
    nonisolated(unsafe) static var redirectTarget = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "github.com" {
            let target = URL(string: RedirectingProtocol.redirectTarget)!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // Refused, the redirect itself is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("zip".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class UpdateRedirectGuardTests: XCTestCase {
    /// Downloads the way the updater does: a download task with a completion handler, and
    /// the guard as the task's own delegate.
    private func download(redirectedTo target: String) -> (status: Int?, refused: String?) {
        RedirectingProtocol.redirectTarget = target
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let redirects = UpdateRedirectGuard()
        let done = expectation(description: "download")
        nonisolated(unsafe) var status: Int?
        let task = session.downloadTask(with: URL(string: "https://github.com/vinhry/mouse-navigate/releases/download/v0.8.0/MouseNavigate.zip")!) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.fulfill()
        }
        task.delegate = redirects
        task.resume()
        wait(for: [done], timeout: 10)
        return (status, redirects.refusedPlace)
    }

    func testARedirectToGitHubsAssetStoreIsFollowed() {
        let result = download(redirectedTo: "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=x")
        XCTAssertEqual(result.status, 200)
        XCTAssertNil(result.refused)
    }

    func testARedirectElsewhereIsRefused() {
        let result = download(redirectedTo: "https://example.com:8443/MouseNavigate.zip?token=secret")
        XCTAssertNotEqual(result.status, 200)
        XCTAssertEqual(result.refused, "https://example.com:8443")

        XCTAssertEqual(download(redirectedTo: "http://objects.githubusercontent.com/x").refused, "http://objects.githubusercontent.com")
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

final class UpdateScratchTests: XCTestCase {
    func testOnlyOldScratchFoldersAreLeftovers() {
        let name = UpdateScratch.name(for: UUID())
        XCTAssertTrue(UpdateScratch.isLeftover(name: name, age: 3_600))
        XCTAssertFalse(UpdateScratch.isLeftover(name: name, age: 60), "may be an install under way")
    }

    func testOtherFoldersAreLeftAlone() {
        XCTAssertFalse(UpdateScratch.isLeftover(name: "MouseNavigate.app", age: 3_600))
        XCTAssertFalse(UpdateScratch.isLeftover(name: ".MouseNavigate-update-notauuid", age: 3_600))
        XCTAssertFalse(UpdateScratch.isLeftover(name: ".MouseNavigate-update-", age: 3_600))
        XCTAssertFalse(UpdateScratch.isLeftover(name: "x.MouseNavigate-update-\(UUID().uuidString)", age: 3_600))
    }
}
