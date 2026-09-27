import Foundation

/// A version such as 0.4.0 or v1.2.0-beta.1, compared the way semantic versioning does:
/// numbers first, and a pre-release before the release it leads up to.
public struct SemanticVersion: Comparable, CustomStringConvertible {
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
public struct GitHubRelease: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
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
public struct UpdateCandidate: Equatable {
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

    public static func select(from release: GitHubRelease, current: SemanticVersion) -> UpdateCandidate? {
        guard !release.draft, !release.prerelease,
              let version = SemanticVersion(release.tagName), version.preRelease == nil,
              current < version,
              let asset = release.assets.first(where: { $0.name == assetName }),
              asset.size > 0, asset.size <= maximumSize,
              asset.browserDownloadURL.scheme == "https"
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
