import Foundation
import MouseNavigateCore

/// The shortcuts macOS has for its own features, kept at hand.
///
/// They are read out of `com.apple.symbolichotkeys`, which is a trip to the preferences
/// daemon and a large dictionary to decode: too slow for the event tap, where every click
/// and keystroke waits. So they are read on a background queue, at launch and again after
/// each use, and the event tap only ever looks at the last answer.
///
/// `hotKeys` and `reload()` are main thread only.
@MainActor
final class SymbolicHotKeyCache {
    private(set) var hotKeys: [Int: SymbolicHotKey] = [:]
    private let queue = DispatchQueue(label: "com.vinhry.MouseNavigate.symbolichotkeys", qos: .utility)
    private var isReloading = false

    init() {
        reload()
    }

    func reload() {
        guard !isReloading else { return }
        isReloading = true
        let deliver: @MainActor @Sendable ([Int: SymbolicHotKey]) -> Void = { [weak self] parsed in
            self?.hotKeys = parsed
            self?.isReloading = false
        }
        queue.async {
            let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys") ?? [:]
            let parsed = SymbolicHotKeys.parse(domain)
            DispatchQueue.main.async {
                deliver(parsed)
            }
        }
    }
}
