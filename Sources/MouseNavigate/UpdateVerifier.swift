import Foundation
import MouseNavigateCore
import Security

/// Decides whether a downloaded app may replace this one.
///
/// A download made by the app itself is never quarantined, so Gatekeeper would never look
/// at it. This is what looks instead: the new app has to satisfy this app's own designated
/// requirement, which is the same identity macOS ties the Accessibility permission to, and
/// has to be notarized, and has to be the version the release said it was.
enum UpdateVerifier {
    enum Failure: LocalizedError {
        case unsignedSelf
        case signature(OSStatus)
        case notNotarized(String)
        case version(expected: String, found: String?)

        var errorDescription: String? {
            switch self {
            case .unsignedSelf:
                return "This copy is not signed with a Developer ID, so it cannot check that an update comes from the same developer."
            case .signature(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The update is not signed by MouseNavigate's developer: \(reason)."
            case .notNotarized(let detail):
                return "The update is not notarized by Apple (\(detail))."
            case .version(let expected, let found):
                return "The update says it is version \(found ?? "unknown") instead of \(expected)."
            }
        }
    }

    /// Marks a leaf certificate as Developer ID Application, in its extensions.
    private static let developerIDLeafOID = "1.2.840.113635.100.6.1.13"

    /// This app's designated requirement, when it has one worth holding an update to. An
    /// ad-hoc build has no team, and its requirement names only its own exact code, which
    /// no update could ever meet; a build signed with an Apple Development certificate has
    /// a team, but its requirement names that certificate's chain, which a Developer ID
    /// release can never satisfy either. Neither copy updates itself, rather than
    /// downloading every release only to refuse it.
    static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else {
            return nil
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first, isDeveloperID(leaf)
        else {
            return nil
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func isDeveloperID(_ certificate: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(certificate, [developerIDLeafOID] as CFArray, nil) as? [String: Any] else {
            return false
        }
        return values[developerIDLeafOID] != nil
    }

    /// Throws the first reason `app` may not be installed. Slow — it runs `spctl`, which
    /// may ask Apple — so never on the main thread.
    static func verify(app: URL, expectedVersion: SemanticVersion, requirement: SecRequirement) throws {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else { throw Failure.signature(created) }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let valid = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard valid == errSecSuccess else { throw Failure.signature(valid) }

        try checkNotarized(app)

        let found = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let found, SemanticVersion(found) == expectedVersion else {
            throw Failure.version(expected: expectedVersion.description, found: found)
        }
    }

    /// Gatekeeper's own verdict. Its source line is required as well as its exit status,
    /// because with Gatekeeper switched off `spctl` accepts everything.
    private static func checkNotarized(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", "-vv", app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw Failure.notNotarized("spctl could not run")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0, output.contains("source=Notarized Developer ID") else {
            let source = output.split(separator: "\n").first { $0.hasPrefix("source=") }
            throw Failure.notNotarized(source.map(String.init) ?? "rejected")
        }
    }
}
