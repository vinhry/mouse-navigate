import Foundation

/// Whether to open the Welcome window at launch.
///
/// It is for someone who has just installed the app: it asks for the permissions and the
/// update choice in one place, where earlier versions put up the Accessibility prompt and
/// an update alert one after the other. Someone already using the app has made those
/// choices, so for them it is recorded as done without being shown. A copy run from
/// source never opens it: it is no install, and cannot be granted anything lasting.
public enum OnboardingPolicy {
    public enum Decision: Equatable {
        case show
        case skip
        /// Never shown, but recorded as done, for someone who set the app up before it existed.
        case recordAsDone
    }

    public static func decide(
        isBundled: Bool,
        hasCompleted: Bool,
        isTrusted: Bool,
        hasChosenUpdates: Bool
    ) -> Decision {
        guard isBundled, !hasCompleted else { return .skip }
        if isTrusted || hasChosenUpdates {
            return .recordAsDone
        }
        return .show
    }
}
