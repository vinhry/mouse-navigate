import Foundation

/// A version such as 0.4.0 or v1.2.0-beta.1, compared the way semantic versioning does:
/// numbers first, and a pre-release before the release it leads up to.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public var numbers: [Int]
    public var preRelease: String?

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // Build metadata never affects ordering.
        if let plus = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plus])
        }

        var core = trimmed
        if let dash = trimmed.firstIndex(of: "-") {
            core = String(trimmed[..<dash])
            let tag = String(trimmed[trimmed.index(after: dash)...])
            guard !tag.isEmpty else { return nil }
            preRelease = tag
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (preRelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let left?, let right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The parts of GitHub's "latest release" answer the updater needs.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var size: Int
        public var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }

        public init(name: String, size: Int, browserDownloadURL: URL) {
            self.name = name
            self.size = size
            self.browserDownloadURL = browserDownloadURL
        }
    }

    public var tagName: String
    public var htmlURL: URL
    public var body: String?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease, assets
    }

    public init(tagName: String, htmlURL: URL, body: String?, draft: Bool, prerelease: Bool, assets: [Asset]) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }
}

/// A release worth downloading.
public struct UpdateCandidate: Equatable, Sendable {
    public var version: SemanticVersion
    public var download: URL
    public var size: Int
    public var releasePage: URL
    public var notes: String?

    /// The zip every release carries; anything else attached is ignored.
    public static let assetName = "MouseNavigate.zip"
    /// Far beyond any real release, so a wrong or hostile asset is refused before it is
    /// downloaded rather than after it fills the disk.
    public static let maximumSize = 200 * 1024 * 1024

    public static func select(
        from release: GitHubRelease,
        current: SemanticVersion,
        repository: GitHubRepository
    ) -> UpdateCandidate? {
        guard !release.draft, !release.prerelease,
              let version = SemanticVersion(release.tagName), version.preRelease == nil,
              current < version,
              let asset = release.assets.first(where: { $0.name == assetName }),
              asset.size > 0, asset.size <= maximumSize,
              repository.isReleaseAsset(asset.browserDownloadURL, named: assetName),
              // The release page is handed to whatever opens its scheme, so only a web
              // address will do.
              release.htmlURL.scheme == "https"
        else {
            return nil
        }
        return UpdateCandidate(
            version: version,
            download: asset.browserDownloadURL,
            size: asset.size,
            releasePage: release.htmlURL,
            notes: release.body
        )
    }
}

/// The repository releases come from, and the addresses a download from it may use.
///
/// GitHub's answer is trusted for what it says about a release, not for where the bytes
/// come from: the asset has to be one of this repository's own release downloads, and the
/// redirects GitHub sends a download through have to stay on GitHub's hosts. A download
/// from anywhere else is refused before anything arrives, whatever the signature check
/// would have said about it afterwards.
public struct GitHubRepository: Equatable, Sendable {
    public var owner: String
    public var name: String

    /// The domain GitHub serves stored files from. Its asset store has been
    /// objects.githubusercontent.com and is now release-assets.githubusercontent.com; a
    /// third name under it must not leave every installed copy refusing every update,
    /// which none of them could fix for itself.
    ///
    /// The whole domain is GitHub's, though anyone's files can be served from it. That is
    /// no way in: what it serves is still only installed if it is signed by this app's
    /// developer, notarized, and the version the release names.
    public static let assetDomain = "githubusercontent.com"

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Read from the API address the latest release is asked for,
    /// `https://api.github.com/repos/<owner>/<name>/releases/latest`, so the repository is
    /// named in one place.
    public init?(latestReleaseURL url: URL) {
        let parts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: false)
        guard url.scheme == "https", url.host?.lowercased() == "api.github.com",
              parts.count == 6, parts[0].isEmpty, parts[1] == "repos",
              !parts[2].isEmpty, !parts[3].isEmpty,
              parts[4] == "releases", parts[5] == "latest"
        else {
            return nil
        }
        self.init(owner: String(parts[2]), name: String(parts[3]))
    }

    /// Whether `url` is this repository's release download of an asset called `asset`,
    /// as in `https://github.com/<owner>/<name>/releases/download/<tag>/<asset>`.
    public func isReleaseAsset(_ url: URL, named asset: String) -> Bool {
        guard GitHubRepository.isOnGitHub(url), url.host?.lowercased() == "github.com",
              url.query == nil, url.fragment == nil
        else {
            return false
        }
        // The decoded path, so an encoded slash or dot cannot pass for something else.
        let parts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0].isEmpty else { return false }
        let tag = parts[5]
        // GitHub's own names are not case-sensitive, and its answer may spell them as the
        // repository's page does.
        return parts[1].lowercased() == owner.lowercased()
            && parts[2].lowercased() == name.lowercased()
            && parts[3] == "releases" && parts[4] == "download"
            && !tag.isEmpty && tag != "." && tag != ".."
            && parts[6] == Substring(asset)
    }

    /// Whether a download may be redirected to `url`.
    public static func mayRedirect(to url: URL) -> Bool {
        isOnGitHub(url)
    }

    /// Over https, on github.com itself or the asset domain, at the usual port, and with
    /// no credentials in the address that could make it mean another host. The domain is
    /// matched whole or after a dot, so a host that merely ends in its letters is not it.
    private static func isOnGitHub(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "github.com" || host == assetDomain || host.hasSuffix("." + assetDomain),
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil
        else {
            return false
        }
        return true
    }
}

/// Stops a download that GitHub, or anything posing as it, redirects off GitHub's hosts.
/// Set as the download task's own delegate; the task then finishes with the redirect it
/// refused, and `refusedPlace` says where it led.
public final class UpdateRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// URLSession calls the delegate on its own queue and the completion on another.
    private let lock = NSLock()
    private var refused: String?

    /// Where a refused redirect pointed, such as `https://example.com`, once one has been
    /// refused.
    public var refusedPlace: String? {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    override public init() {}

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url, GitHubRepository.mayRedirect(to: url) {
            completionHandler(request)
            return
        }
        // Scheme, host and port only: enough to say where, without the rest of an address
        // someone else chose.
        var place = URLComponents()
        place.scheme = request.url?.scheme
        place.host = request.url?.host
        place.port = request.url?.port
        lock.lock()
        refused = place.host == nil ? "an address with no host" : (place.string ?? "an unreadable address")
        lock.unlock()
        completionHandler(nil)
    }
}

public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = UpdateSchedule.interval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back since the last check counts as due, not as years away.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }
}

/// Why the app cannot replace itself where it is, if it cannot.
public enum InstallLocationProblem: Equatable {
    /// Run straight from Downloads: macOS runs a read-only copy from a hidden folder.
    case translocated
    /// The folder or the app is not writable by this user.
    case notWritable
    /// Not running from an app bundle at all, as with `swift run`.
    case notABundle

    public static func check(bundlePath: String, isWritable: Bool) -> InstallLocationProblem? {
        guard bundlePath.hasSuffix(".app") else { return .notABundle }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        return isWritable ? nil : .notWritable
    }
}

/// The hidden folder an update is copied into beside the app, so the swap itself is a
/// rename on one volume. It is removed once the swap is done; one left behind by a crash
/// or a forced quit is found by its name and removed at the next launch.
public enum UpdateScratch {
    public static let prefix = ".MouseNavigate-update-"
    /// How old a leftover must be before it is taken away, so a launch can never remove
    /// one that another account's copy is installing from at that moment.
    public static let minimumAge: TimeInterval = 10 * 60

    public static func name(for id: UUID) -> String {
        prefix + id.uuidString
    }

    public static func isLeftover(name: String, age: TimeInterval) -> Bool {
        guard name.hasPrefix(prefix), age >= minimumAge else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}
